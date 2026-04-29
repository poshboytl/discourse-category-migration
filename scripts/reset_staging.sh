#!/usr/bin/env bash
#
# Reset staging completely — bring it back to "before any migration script ever ran".
#
# Use ONLY for staging dry-runs. Do NOT run on production after a real migration:
# this script blows away the DB and migration artifacts unconditionally.
#
# Run from the staging HOST as a user with sudo (NOT inside the container):
#   bash /path/to/reset_staging.sh
#
# What it does:
#   1. Find the earliest pre_recategorize_*.dump backup (the truly-pre-migration one)
#   2. Rollback the DB to that backup (drops + recreates + pg_restore inside container)
#   3. Restart Discourse to clear caches
#   4. Delete all migration-deployed scripts and artifacts inside the container
#   5. Delete all backups, deployed bundle, and your local clone on the host
#   6. Clear root + host bash history (in case API key was ever pasted)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
CONTAINER_NAME="${CONTAINER_NAME:-app}"
DB_NAME="${DB_NAME:-discourse}"
DB_OWNER="${DB_OWNER:-discourse}"
SHARED_DIR="/var/discourse/shared/standalone"
BACKUP_DIR_HOST="$SHARED_DIR/backups"
BUNDLE_DIR_HOST="$SHARED_DIR/discourse-category-migration"
LAUNCHER="/var/discourse/launcher"

# ============================================================================
# Helpers
# ============================================================================
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
step()   { echo; bold "===== $* ====="; }
fail()   { red "FAIL: $*"; exit 1; }

# ============================================================================
# Pre-flight
# ============================================================================
step "Pre-flight"

[[ -x "$LAUNCHER" ]] || fail "Discourse launcher not found at $LAUNCHER (not on the staging host?)"
command -v sudo >/dev/null || fail "sudo not found"
sudo docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" \
  || fail "container '$CONTAINER_NAME' not running. Set CONTAINER_NAME env var if non-default."

# Find earliest pre_recategorize backup (the actual pre-migration one, sorted by mtime)
EARLIEST_BACKUP=$(sudo ls -1tr "$BACKUP_DIR_HOST"/pre_recategorize_*.dump 2>/dev/null | head -1 || true)
[[ -n "$EARLIEST_BACKUP" ]] || fail "no pre_recategorize_*.dump found in $BACKUP_DIR_HOST"

CONTAINER_BACKUP="/shared/backups/$(basename "$EARLIEST_BACKUP")"
SIZE=$(sudo stat -c%s "$EARLIEST_BACKUP" 2>/dev/null || sudo stat -f%z "$EARLIEST_BACKUP")
[[ "$SIZE" -gt 1048576 ]] || fail "earliest backup is suspiciously small (${SIZE}B)"

green "OK  earliest backup: $EARLIEST_BACKUP ($((SIZE/1024/1024)) MB)"
green "OK  container path:  $CONTAINER_BACKUP"

# ============================================================================
# Confirmation
# ============================================================================
echo
yellow "================================================================"
yellow " STAGING RESET — destructive"
yellow ""
yellow " DB '$DB_NAME' will be dropped and restored from:"
yellow "   $EARLIEST_BACKUP"
yellow ""
yellow " ALL of the following will be DELETED:"
yellow "   - $BACKUP_DIR_HOST/pre_recategorize_*.dump  (every backup)"
yellow "   - $BUNDLE_DIR_HOST                          (deployed bundle)"
yellow "   - ~/discourse-category-migration             (your clone)"
yellow "   - /var/www/discourse/script/{recategorize,classify_*}.rb"
yellow "   - /var/www/discourse/ckb/                   (API key + classify CSVs)"
yellow "   - /tmp/migration-* and /tmp/migration-logs-*.tar.gz"
yellow "   - root + host bash history"
yellow "================================================================"
echo
read -p "Type 'reset' to proceed, anything else to abort: " CONFIRM
[[ "$CONFIRM" == "reset" ]] || { red "Aborted by user."; exit 0; }

# ============================================================================
# Phase 1: Inside container — rollback DB + clean container artifacts
# ============================================================================
step "1. Rolling back DB inside container"

# `docker exec -i` is REQUIRED for the heredoc to be passed as stdin to bash inside
# the container. Without -i, stdin is not connected and the heredoc is discarded —
# bash starts with no input, exits immediately, returns 0, and the outer script
# falsely thinks all the commands inside ran. This caused a real disaster on staging
# where the rollback silently no-op'd while host-side cleanup deleted all backups.
#
# `set -o pipefail` is also REQUIRED so that pg_restore failures inside a pipeline
# (e.g. `pg_restore | tail`) are caught. Without it, set -e only sees tail's exit
# code, missing actual restore errors.
sudo docker exec -i "$CONTAINER_NAME" bash <<EOF
set -euo pipefail
echo "  - terminating active connections..."
sudo -u postgres psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null
echo "  - dropping database..."
sudo -u postgres psql -d postgres -c "DROP DATABASE $DB_NAME;"
echo "  - recreating database..."
sudo -u postgres psql -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_OWNER;"
echo "  - restoring from $CONTAINER_BACKUP (this takes ~1 min, full output below)..."
# --exit-on-error is REQUIRED. Without it, pg_restore prints "warning: errors ignored
# on restore: N" and exits 0 even when unique indexes / constraints failed to create.
# That looks like success to set -e, the heredoc proceeds, and the outer script then
# deletes all backups in Phase 3 — leaving a corrupted DB with no recovery option.
sudo -u postgres pg_restore --exit-on-error -d $DB_NAME -j 4 "$CONTAINER_BACKUP"

echo "  - cleaning deployed scripts..."
rm -f /var/www/discourse/script/recategorize.rb \
      /var/www/discourse/script/classify_extract.rb \
      /var/www/discourse/script/classify_run.rb \
      /var/www/discourse/script/classify_migrate.rb

echo "  - cleaning ckb/ (API key + classify CSVs)..."
rm -rf /var/www/discourse/ckb/

echo "  - cleaning /tmp migration artifacts..."
rm -rf /tmp/migration-*/
rm -f /tmp/migration-logs-*.tar.gz /tmp/anthropic_ping.* 2>/dev/null || true
rm -f /tmp/recat_*.log /tmp/extract.log /tmp/classify_*.log /tmp/migrate_*.log 2>/dev/null || true

echo "  - clearing root bash history..."
> /root/.bash_history

echo "  done inside container"
EOF

# Sanity check: did the heredoc actually run? Verify the deployed scripts are gone.
# This catches the docker-exec-without-stdin failure mode we hit earlier.
if sudo docker exec "$CONTAINER_NAME" test -f /var/www/discourse/script/recategorize.rb; then
  fail "rollback heredoc did NOT run — deployed scripts still present. Aborting before host cleanup destroys backups."
fi

green "OK  DB rolled back, container artifacts cleaned"

# ============================================================================
# Phase 2: Restart Discourse to clear caches
# ============================================================================
step "2. Restarting Discourse (1-2 min)"

cd /var/discourse && sudo "$LAUNCHER" restart "$CONTAINER_NAME"

green "OK  Discourse restarted"

# ============================================================================
# Phase 3: Host cleanup
# ============================================================================
step "3. Cleaning host artifacts"

sudo rm -f "$BACKUP_DIR_HOST"/pre_recategorize_*.dump
sudo rm -rf "$BUNDLE_DIR_HOST"
rm -rf "$HOME/discourse-category-migration"
rm -f "$HOME"/discourse-category-migration*.tar.gz "$HOME"/migration_logs_*.tar.gz "$HOME"/migration-logs-*.tar.gz

# Best-effort: clear current shell history. Note: this resets ckb's history file
# which matters because earlier shell sessions may have echoed API keys.
> "$HOME/.bash_history" 2>/dev/null || true
history -c 2>/dev/null || true

green "OK  host artifacts cleaned"

# ============================================================================
# Done
# ============================================================================
echo
bold "================================================================"
green " STAGING RESET COMPLETE"
bold "================================================================"
echo
echo "Staging is now at the pre-migration state. Admin can start fresh:"
echo
echo "  cd ~"
echo "  git clone https://github.com/poshboytl/discourse-category-migration.git"
echo "  # then follow README.md"
echo
yellow "Reminder:"
echo "  - Revoke any API key that was pasted during testing"
echo "  - Generate a fresh key for admin (different from any previously-leaked one)"
