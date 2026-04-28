#!/usr/bin/env bash
#
# Rollback Discourse 分类重构迁移
#
# 在 ./launcher enter app 进入容器后、以 root 身份运行：
#   bash /shared/discourse-category-migration/scripts/rollback.sh <backup_file>
#
# 完成后退出容器（exit），在 host 上跑 `cd /var/discourse && ./launcher restart app`。

set -euo pipefail

BACKUP_FILE="${1:-}"
DB_NAME="${DB_NAME:-discourse}"
DB_OWNER="${DB_OWNER:-discourse}"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

# ============================================================================
# Pre-flight
# ============================================================================
[[ -n "$BACKUP_FILE" ]] || { red "Usage: $0 <backup_file.dump>"; exit 1; }
[[ -f "$BACKUP_FILE" ]] || { red "Backup file not found: $BACKUP_FILE"; exit 1; }
[[ "$(id -u)" -eq 0 ]] || { red "Must run as root inside the container"; exit 1; }

SIZE_BYTES=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE")
[[ $SIZE_BYTES -gt 0 ]] || { red "Backup file is 0 bytes — won't restore garbage"; exit 1; }

# ============================================================================
# Confirm
# ============================================================================
echo
bold "================================================================"
yellow " ROLLBACK: drop and restore database '$DB_NAME'"
yellow ""
yellow "  Backup file: $BACKUP_FILE ($((SIZE_BYTES/1024/1024)) MB)"
yellow ""
yellow "  ALL CURRENT DATA in $DB_NAME WILL BE LOST."
yellow "  All topic categories, posts, users will revert to backup state."
bold "================================================================"
echo
read -p "Type 'rollback' to proceed, anything else to abort: " CONFIRM
[[ "$CONFIRM" == "rollback" ]] || { red "Aborted."; exit 0; }

# ============================================================================
# Execute
# ============================================================================
echo
bold "Terminating active connections to $DB_NAME..."
sudo -u postgres psql -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME' AND pid <> pg_backend_pid();" \
  >/dev/null

bold "Dropping database $DB_NAME..."
sudo -u postgres psql -d postgres -c "DROP DATABASE $DB_NAME;"

bold "Recreating database $DB_NAME owned by $DB_OWNER..."
sudo -u postgres psql -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_OWNER;"

bold "Restoring from $BACKUP_FILE..."
sudo -u postgres pg_restore -d "$DB_NAME" -j 4 "$BACKUP_FILE"

echo
green "================================================================"
green " ROLLBACK COMPLETE"
green "================================================================"
echo
yellow "Next steps:"
echo "  1. exit                              # leave the container"
echo "  2. cd /var/discourse && ./launcher restart app"
echo "  3. Verify staging in browser is back to pre-migration state"
echo
