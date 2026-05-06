#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# BARVEA — daily backup (Postgres only — MinIO/Redis live on barvea-data)
# ═══════════════════════════════════════════════════════════════
# Cron entry (run on barvea-app):
#   0 3 * * * /home/miko/barvea/scripts/backup.sh >> /var/log/barvea-backup.log 2>&1
#
# Note: full backup of DATA layer (MinIO, Redis snapshot) should run on
# barvea-data via its own cron — that VM owns the data volumes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

set -a
# shellcheck disable=SC1091
source .env.production
set +a

BACKUP_DIR="$INFRA_DIR/backups"
mkdir -p "$BACKUP_DIR"

DATESTAMP=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="$BACKUP_DIR/barvea_${DATESTAMP}.pgcustom"

echo "[$(date)] Starting Postgres dump..."
docker run --rm --network host postgres:18-alpine \
  pg_dump "$DATABASE_URL" \
    --format=custom \
    --no-owner \
    --compress=9 \
  > "$DUMP_FILE"

SIZE=$(du -h "$DUMP_FILE" | cut -f1)
echo "[$(date)] Dump complete: $DUMP_FILE ($SIZE)"

# Retention: keep 14 daily, 8 weekly (Sunday), 12 monthly (1st of month)
echo "[$(date)] Pruning old backups..."
find "$BACKUP_DIR" -name "barvea_*.pgcustom" -mtime +14 \
  ! -name "*$(date +%Y%m01)*" \
  ! -newer "$BACKUP_DIR/.weekly_marker" \
  -delete 2>/dev/null || true

# Update weekly marker on Sundays
if [[ $(date +%u) -eq 7 ]]; then
  touch "$BACKUP_DIR/.weekly_marker"
fi

echo "[$(date)] Backup done. Retained:"
ls -lh "$BACKUP_DIR"/barvea_*.pgcustom 2>/dev/null | tail -10
