#!/usr/bin/env bash
# FieldTrack — daily Postgres backup to Backblaze B2.
#
# Cron (set up by this script's instructions, or manually):
#   0 2 * * * /opt/fieldtrack/app/scripts/backup.sh
#
# Requires the `b2` CLI authorized once:
#   pip install b2
#   b2 account authorize <keyID> <applicationKey>
#
# Env overrides (set in /opt/fieldtrack/app/.env.prod and sourced below):
#   B2_BUCKET            - target Backblaze B2 bucket name

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────
ENV_FILE="/opt/fieldtrack/app/.env.prod"
BACKUP_DIR="/opt/fieldtrack/backups"
LOG_FILE="/var/log/fieldtrack/backup.log"
CONTAINER="fieldtrack-postgres"
B2_BUCKET="${B2_BUCKET:-fieldtrack-backups}"

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source <(grep -E '^(POSTGRES_USER|POSTGRES_DB)=' "$ENV_FILE")

TIMESTAMP="$(date +%Y-%m-%d_%H-%M)"
DATE_ONLY="$(date +%Y-%m-%d)"
FILENAME="fieldtrack_${TIMESTAMP}.sql.gz"
LOCAL_PATH="${BACKUP_DIR}/${FILENAME}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $*"
    exit 1
}

mkdir -p "$BACKUP_DIR"
log "==> Starting backup ($FILENAME)"

# ── 1. Dump ──────────────────────────────────────────────────────────
docker exec "$CONTAINER" pg_dump -U "${POSTGRES_USER:-fieldtrack}" "${POSTGRES_DB:-fieldtrack}" \
    | gzip > "$LOCAL_PATH" \
    || fail "pg_dump failed"

[ -s "$LOCAL_PATH" ] || fail "backup file is empty: $LOCAL_PATH"
log "    dump written: $LOCAL_PATH ($(du -h "$LOCAL_PATH" | cut -f1))"

# ── 2. Upload to Backblaze B2 ────────────────────────────────────────
log "==> Uploading to b2://${B2_BUCKET}/daily/fieldtrack_${DATE_ONLY}.sql.gz"
b2 file upload "$B2_BUCKET" "$LOCAL_PATH" "daily/fieldtrack_${DATE_ONLY}.sql.gz" \
    || fail "b2 upload failed"

# ── 3. Retention: prune B2 ───────────────────────────────────────────
# - Delete daily/ files older than 7 days.
# - Keep one weekly snapshot (Sunday's) for the last 4 weeks under weekly/.
log "==> Applying retention policy"

# Promote Sunday's backup to weekly/ (idempotent — b2 copy overwrites).
if [ "$(date +%u)" -eq 7 ]; then
    b2 file copy-by-id \
        "$(b2 file list "$B2_BUCKET" --prefix "daily/fieldtrack_${DATE_ONLY}.sql.gz" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["fileId"])')" \
        "$B2_BUCKET" "weekly/fieldtrack_${DATE_ONLY}.sql.gz" \
        || log "    WARNING: weekly promotion failed (non-fatal)"
fi

# Delete daily/ files older than 7 days.
b2 ls "$B2_BUCKET" daily/ --long 2>/dev/null | while read -r line; do
    fname=$(echo "$line" | awk '{print $NF}')
    fdate=$(echo "$fname" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    [ -z "$fdate" ] && continue
    age_days=$(( ( $(date +%s) - $(date -d "$fdate" +%s) ) / 86400 ))
    if [ "$age_days" -gt 7 ]; then
        log "    deleting old daily backup: daily/$fname (${age_days}d old)"
        b2 file delete --name "daily/$fname" || log "    WARNING: failed to delete daily/$fname"
    fi
done

# Delete weekly/ files older than 28 days.
b2 ls "$B2_BUCKET" weekly/ --long 2>/dev/null | while read -r line; do
    fname=$(echo "$line" | awk '{print $NF}')
    fdate=$(echo "$fname" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    [ -z "$fdate" ] && continue
    age_days=$(( ( $(date +%s) - $(date -d "$fdate" +%s) ) / 86400 ))
    if [ "$age_days" -gt 28 ]; then
        log "    deleting old weekly backup: weekly/$fname (${age_days}d old)"
        b2 file delete --name "weekly/$fname" || log "    WARNING: failed to delete weekly/$fname"
    fi
done

# ── 4. Local cleanup: keep only the last 2 local dumps ───────────────
log "==> Cleaning up local dumps (keeping last 2)"
ls -1t "${BACKUP_DIR}"/fieldtrack_*.sql.gz 2>/dev/null | tail -n +3 | xargs -r rm -v

log "==> Backup complete: $FILENAME"
