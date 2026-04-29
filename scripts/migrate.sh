#!/usr/bin/env bash
#
# Discourse 分类重构 — 一站式迁移脚本
#
# 假设前置条件（运行前你必须满足）：
#   1. 已 ./launcher enter app 进入 Discourse 容器
#   2. 当前用户是 root
#   3. bundle 解压在 $BUNDLE_DIR (default /shared/discourse-category-migration)
#   4. 已 export ANTHROPIC_API_KEY='sk-ant-...'
#
# 用法：
#   export ANTHROPIC_API_KEY='sk-ant-api03-...'
#   bash /shared/discourse-category-migration/scripts/migrate.sh
#
# 失败处理：脚本会在第一个错误处停下，print 失败信息和 log 文件路径。
# 修了之后从同一条命令重跑：dry-run/extract/classify/migrate 都是幂等或可 resume 的。
# 如果 apply 后想完全回滚：bash rollback.sh <backup_file>

set -euo pipefail

# ============================================================================
# 配置
# ============================================================================
BUNDLE_DIR="${BUNDLE_DIR:-/shared/discourse-category-migration}"
DISCOURSE_DIR="/var/www/discourse"
BACKUP_DIR="/shared/backups"
DB_NAME="${DB_NAME:-discourse}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/migration-${TIMESTAMP}"
MAX_CLASSIFY_RETRIES=3

# ============================================================================
# Helpers
# ============================================================================
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

step() { echo; bold "===== $* ====="; }
fail() { red "FAIL: $*"; echo "Logs: $LOG_DIR"; exit 1; }

# Run a command as discourse user with RAILS_ENV + API_KEY propagated.
# stdout/stderr go wherever the caller redirects.
#
# We pass env vars explicitly via `env VAR=value` rather than relying on
# sudo's --preserve-env, which depends on /etc/sudoers configuration that
# varies across Discourse container builds.
run_as_discourse() {
  sudo -u discourse \
    env RAILS_ENV=production "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
    bash -c "cd $DISCOURSE_DIR && $*"
}

# ============================================================================
# Pre-flight
# ============================================================================
step "Pre-flight checks"

[[ "$(id -u)" -eq 0 ]] || fail "must run as root inside the container (current: $(whoami))"
[[ -d "$BUNDLE_DIR/scripts" ]] || fail "bundle scripts not found at $BUNDLE_DIR/scripts"
[[ -d "$DISCOURSE_DIR" ]] || fail "discourse not found at $DISCOURSE_DIR (not in container?)"
id discourse >/dev/null 2>&1 || fail "discourse user does not exist"
id postgres >/dev/null 2>&1 || fail "postgres user does not exist"
command -v curl >/dev/null 2>&1 || fail "curl not found in container"

# API key resolution — env var preferred, fallback to file at $DISCOURSE_DIR/ckb/.anthropic_key.
# Same precedence as classify_run.rb itself, so admin can pick either:
#   - env var: export ANTHROPIC_API_KEY='sk-ant-...'  (not persistent across shell sessions)
#   - file:    write key to /var/www/discourse/ckb/.anthropic_key  (persists, but on-disk)
KEY_FILE="$DISCOURSE_DIR/ckb/.anthropic_key"
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  if [[ -f "$KEY_FILE" && -s "$KEY_FILE" ]]; then
    ANTHROPIC_API_KEY=$(tr -d '[:space:]' < "$KEY_FILE")
    export ANTHROPIC_API_KEY
    yellow "NOTE  ANTHROPIC_API_KEY loaded from $KEY_FILE (env var was unset)"
  else
    fail "no API key — set ANTHROPIC_API_KEY env var, or write key to $KEY_FILE"
  fi
fi
[[ -n "$ANTHROPIC_API_KEY" ]] || fail "API key is empty after resolution"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
# LOG_DIR is created by root, but rails commands run as discourse will write
# log files into it. chown so discourse can write.
chown discourse:discourse "$LOG_DIR"

# Same story for ckb/ — classify_extract.rb / classify_run.rb / classify_migrate.rb
# all write CSV/JSONL files under $DISCOURSE_DIR/ckb. If admin created the dir as
# root (per README step 3b), discourse can't write. Self-heal here.
mkdir -p "$DISCOURSE_DIR/ckb"
chown discourse:discourse "$DISCOURSE_DIR/ckb"

green "OK  container detected, root user, bundle present"
green "OK  ANTHROPIC_API_KEY set (len=${#ANTHROPIC_API_KEY}, prefix=${ANTHROPIC_API_KEY:0:12}...)"
green "OK  log dir: $LOG_DIR"

# ============================================================================
# 0. Validate API key (avoid burning 30+ min before discovering bad key)
# ============================================================================
step "0. Validate Anthropic API key (single GET /v1/models)"

HTTP_CODE=$(curl -sS -o /tmp/anthropic_ping.json -w "%{http_code}" \
  --max-time 15 \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  https://api.anthropic.com/v1/models 2>/tmp/anthropic_ping.err || echo "000")

case "$HTTP_CODE" in
  200)
    green "OK  API key valid (HTTP 200 from /v1/models)"
    rm -f /tmp/anthropic_ping.json /tmp/anthropic_ping.err
    ;;
  401|403)
    red "FAIL: API key rejected (HTTP $HTTP_CODE) — key is invalid or revoked"
    red "      Response: $(cat /tmp/anthropic_ping.json 2>/dev/null | head -c 300)"
    red "      Get a fresh key from https://console.anthropic.com/settings/keys"
    red "      Then: read -rs ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY"
    rm -f /tmp/anthropic_ping.json /tmp/anthropic_ping.err
    exit 1
    ;;
  000)
    red "FAIL: could not reach api.anthropic.com (network error or curl missing)"
    red "      stderr: $(cat /tmp/anthropic_ping.err 2>/dev/null | head -c 300)"
    rm -f /tmp/anthropic_ping.json /tmp/anthropic_ping.err
    exit 1
    ;;
  *)
    yellow "WARN: unexpected HTTP $HTTP_CODE from /v1/models"
    yellow "      Response: $(cat /tmp/anthropic_ping.json 2>/dev/null | head -c 300)"
    yellow "      Continuing anyway — if this is a transient issue classify_run will retry."
    rm -f /tmp/anthropic_ping.json /tmp/anthropic_ping.err
    ;;
esac

# ============================================================================
# 1. Deploy scripts
# ============================================================================
step "1. Deploy migration scripts to $DISCOURSE_DIR/script/"

for f in recategorize.rb classify_extract.rb classify_run.rb classify_migrate.rb; do
  cp "$BUNDLE_DIR/scripts/$f" "$DISCOURSE_DIR/script/$f"
  chown discourse:discourse "$DISCOURSE_DIR/script/$f"
  chmod 644 "$DISCOURSE_DIR/script/$f"
done

green "OK  4 scripts deployed and owned by discourse"

# ============================================================================
# 2. Backup DB
# ============================================================================
step "2. Backup DB ($DB_NAME)"

BACKUP_FILE="$BACKUP_DIR/pre_recategorize_${TIMESTAMP}.dump"
sudo -u postgres pg_dump -Fc "$DB_NAME" > "$BACKUP_FILE"

SIZE_BYTES=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE")
[[ $SIZE_BYTES -gt 0 ]] || fail "backup is 0 bytes — pg_dump failed silently"
[[ $SIZE_BYTES -gt 1048576 ]] || fail "backup is suspiciously small (${SIZE_BYTES}B) — verify manually"

green "OK  backup at $BACKUP_FILE ($((SIZE_BYTES/1024/1024)) MB)"

# ============================================================================
# 3. Dry-run recategorize
# ============================================================================
step "3. Dry-run recategorize (no DB changes)"

DRYRUN_LOG="$LOG_DIR/recat_dryrun.log"
run_as_discourse "bin/rails runner script/recategorize.rb --dry-run > $DRYRUN_LOG 2>&1" \
  || fail "dry-run failed — see $DRYRUN_LOG"

ABORT_COUNT=$(grep -cE "^Aborting|MISS " "$DRYRUN_LOG" || true)
[[ $ABORT_COUNT -eq 0 ]] || fail "dry-run has $ABORT_COUNT aborting/missing lines — see $DRYRUN_LOG"

green "OK  dry-run clean ($ABORT_COUNT abort/miss)"
echo
yellow "MOVE plan summary:"
grep "^  MOVE " "$DRYRUN_LOG" || true

# ============================================================================
# Confirmation gate (the only one)
# ============================================================================
echo
yellow "================================================================"
yellow " ABOUT TO APPLY CHANGES TO $DB_NAME DATABASE"
yellow " Backup at: $BACKUP_FILE"
yellow ""
yellow " The pipeline will run end-to-end (~30-60 min):"
yellow "   - apply recategorize"
yellow "   - extract General topics for classification"
yellow "   - classify via Claude API (~ \$0.50)"
yellow "   - apply classify_migrate"
yellow ""
yellow " You can ctrl+c during dry-run/extract/classify/dry-migrate."
yellow " You should NOT ctrl+c during APPLY steps (recategorize and migrate apply)."
yellow ""
yellow " Rollback: bash $BUNDLE_DIR/scripts/rollback.sh $BACKUP_FILE"
yellow "================================================================"
echo
read -p "Type 'yes' to proceed, anything else to abort: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { red "Aborted by user."; exit 0; }

# ============================================================================
# 4. Apply recategorize
# ============================================================================
step "4. Apply recategorize (10-30 min, do NOT ctrl+c)"

APPLY_LOG="$LOG_DIR/recat_apply.log"
echo "Tail in another shell: sudo tail -f $APPLY_LOG"
START=$(date +%s)

run_as_discourse "bin/rails runner script/recategorize.rb --apply > $APPLY_LOG 2>&1" \
  || fail "recategorize apply exited non-zero — see $APPLY_LOG"

ELAPSED=$(($(date +%s) - START))
ERROR_COUNT=$(grep -cE "^ERROR|Aborting" "$APPLY_LOG" || true)
[[ $ERROR_COUNT -eq 0 ]] || fail "apply has $ERROR_COUNT error lines — see $APPLY_LOG"

green "OK  recategorize applied in ${ELAPSED}s"

# ============================================================================
# 5. Verify Community Space lock + count categories
# ============================================================================
step "5. Verify post-apply state"

SANITY_LOG="$LOG_DIR/sanity.log"
run_as_discourse "bin/rails runner '
cs = Category.find_by(name: %q(Community Space), parent_category_id: nil)
abort %q(Community Space missing) unless cs
cg = CategoryGroup.find_by(category_id: cs.id, group_id: 0)
abort %q(Community Space not locked) unless cg && cg.permission_type == 2
puts %q(OK: Community Space locked)
puts %q(Top-level categories: ) + Category.where(parent_category_id: nil).count.to_s
' > $SANITY_LOG 2>&1" || fail "sanity check failed — see $SANITY_LOG"

cat "$SANITY_LOG"
green "OK  Community Space locked, structure verified"

# ============================================================================
# 6. Extract
# ============================================================================
step "6. Extract live General topics for classification"

EXTRACT_LOG="$LOG_DIR/extract.log"
run_as_discourse "rm -f ckb/general_classify_in.jsonl ckb/general_classify_out.csv ckb/classify_migrate_audit.csv ckb/classify_migrate_review_needed.csv && bin/rails runner script/classify_extract.rb > $EXTRACT_LOG 2>&1" \
  || fail "extract failed — see $EXTRACT_LOG"

EXTRACT_FILE="$DISCOURSE_DIR/ckb/general_classify_in.jsonl"
[[ -f "$EXTRACT_FILE" ]] || fail "extract output missing: $EXTRACT_FILE"
EXTRACT_COUNT=$(wc -l < "$EXTRACT_FILE")
[[ $EXTRACT_COUNT -gt 0 ]] || fail "extract output is empty"

green "OK  $EXTRACT_COUNT topics extracted"

# ============================================================================
# 7. Classify (with retry up to N times)
# ============================================================================
step "7. Classify via Claude API (10-20 min, ~\$0.50)"

CLASSIFY_LOG="$LOG_DIR/classify_run.log"
# Don't pre-truncate as root — that creates the file with root ownership, then
# the discourse-side `>>` append below fails with permission denied. LOG_DIR is
# already timestamped per-run, so the file won't exist yet; the first iteration's
# `>>` creates it fresh, owned by discourse.

for i in $(seq 1 $MAX_CLASSIFY_RETRIES); do
  echo "Classification attempt $i of $MAX_CLASSIFY_RETRIES (resume mode auto-skips already classified)..."
  if run_as_discourse "bin/rails runner script/classify_run.rb >> $CLASSIFY_LOG 2>&1"; then
    green "OK  classification clean on attempt $i"
    break
  fi
  if [[ $i -eq $MAX_CLASSIFY_RETRIES ]]; then
    fail "classification still has failures after $MAX_CLASSIFY_RETRIES attempts — see $CLASSIFY_LOG"
  fi
  yellow "  attempt $i had failures, retrying after 5s..."
  sleep 5
done

# ============================================================================
# 8. Dry-run migrate
# ============================================================================
step "8. Dry-run migrate (validate classifier output, no DB changes)"

MIGDRY_LOG="$LOG_DIR/migrate_dryrun.log"
run_as_discourse "bin/rails runner script/classify_migrate.rb > $MIGDRY_LOG 2>&1" \
  || fail "migrate dry-run failed — see $MIGDRY_LOG"

INVALID=$(grep -E "invalid category:" "$MIGDRY_LOG" | grep -oE "[0-9]+" | tail -1 || echo "?")
MISSING=$(grep -E "topic missing:" "$MIGDRY_LOG" | grep -oE "[0-9]+" | tail -1 || echo "?")
MOVED_PLAN=$(grep -E "^  moved:" "$MIGDRY_LOG" | grep -oE "[0-9]+" | tail -1 || echo "?")

[[ "$INVALID" == "0" ]] || fail "migrate dry-run shows $INVALID invalid_category — see $MIGDRY_LOG"
[[ "$MISSING" == "0" ]] || fail "migrate dry-run shows $MISSING topic_missing — see $MIGDRY_LOG"

green "OK  migrate dry-run clean ($MOVED_PLAN topics planned to move)"

# ============================================================================
# 9. Apply migrate
# ============================================================================
step "9. Apply migrate (1-3 min)"

MIGAPPLY_LOG="$LOG_DIR/migrate_apply.log"
run_as_discourse "bin/rails runner script/classify_migrate.rb --apply > $MIGAPPLY_LOG 2>&1" \
  || fail "migrate apply exited non-zero — see $MIGAPPLY_LOG"

ERROR_COUNT=$(grep -cE "^ERROR" "$MIGAPPLY_LOG" || true)
[[ $ERROR_COUNT -eq 0 ]] || fail "migrate apply has $ERROR_COUNT error lines — see $MIGAPPLY_LOG"

AUDIT_FILE="$DISCOURSE_DIR/ckb/classify_migrate_audit.csv"
AUDIT_LINES=$(wc -l < "$AUDIT_FILE" 2>/dev/null || echo 0)
# Header-only audit (1 line) is legitimate when classifier put everything in
# stay_in_general — unusual but not a bug. Just check file exists with header.
[[ $AUDIT_LINES -ge 1 ]] || fail "audit CSV missing or empty"

green "OK  migrate applied (audit: $AUDIT_LINES rows incl header, $((AUDIT_LINES - 1)) topics moved)"

# ============================================================================
# 10. Bundle logs
# ============================================================================
step "10. Bundle logs for review"

cp "$AUDIT_FILE" "$LOG_DIR/" 2>/dev/null || true
[[ -f "$DISCOURSE_DIR/ckb/classify_migrate_review_needed.csv" ]] && \
  cp "$DISCOURSE_DIR/ckb/classify_migrate_review_needed.csv" "$LOG_DIR/" || true

LOG_TAR="/tmp/migration-logs-${TIMESTAMP}.tar.gz"
tar -czf "$LOG_TAR" -C "$(dirname "$LOG_DIR")" "$(basename "$LOG_DIR")"

green "OK  log bundle: $LOG_TAR"

# ============================================================================
# Done
# ============================================================================
echo
bold "================================================================"
green " MIGRATION COMPLETE"
bold "================================================================"
echo "  Backup:     $BACKUP_FILE"
echo "  Log bundle: $LOG_TAR"
echo "  Audit CSV:  $AUDIT_FILE"
echo
yellow "Browser smoke test:"
echo "  - /categories shows new structure (7 topical + Archived + Staff)"
echo "  - Community Space (top-level): NO '+ New Topic' button"
echo "  - Community Space > Spark Program: HAS '+ New Topic' button"
echo "  - Old Q&A topic: in Archived category, read-only"
echo
yellow "If anything looks off, rollback:"
echo "  bash $BUNDLE_DIR/scripts/rollback.sh $BACKUP_FILE"
echo
