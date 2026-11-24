#!/bin/bash
# BARVEA — VM 101 barvea-data /usr/local/sbin/barvea-data-backup.sh (instalator v2, 2026-11-24).
# Nocny backup węzła danych: pg_dump całej bazy (format custom) + /mnt/minio-data (obiekty:
# IFC, podglądy, zdjęcia, raporty) + konfiguracja Postgres/Redis/MinIO → restic (wspólne repo).
# Prod ma własny zrzut z 2026-05 (restic barvea-data 03:09); ten plik = wzorzec dla nowych instancji.
# Wymaga: /root/.config/restic/password, /root/.ssh/config alias `storagebox` (albo RESTIC_REPOSITORY w
# /etc/barvea/restic.env), restic, jq. Retencja per --host jak README.
set -euo pipefail

[ -f /etc/barvea/restic.env ] && . /etc/barvea/restic.env
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-sftp:storagebox:barvea-restic}"
export RESTIC_PASSWORD_FILE=/root/.config/restic/password

HOST=$(hostname)
LOG=/var/log/barvea-backup.log
LOCK=/var/lock/barvea-backup.lock
DUMP_DIR=/var/backups/barvea
PGDB="${PGDB:-barvea}"

exec 9>"$LOCK"
flock -n 9 || { echo "Another backup running, exit"; exit 1; }
log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "===================="
log "Backup start (host=$HOST)"

mkdir -p "$DUMP_DIR"; chmod 700 "$DUMP_DIR"
log "pg_dump $PGDB (custom)..."
DUMP="$DUMP_DIR/$PGDB-$(date +%Y%m%d_%H%M%S).pgcustom"
sudo -u postgres pg_dump "$PGDB" --format=custom --no-owner > "$DUMP"
[ -s "$DUMP" ] || { log "ERROR: pusty dump $DUMP"; exit 1; }
ls -1t "$DUMP_DIR"/*.pgcustom 2>/dev/null | tail -n +8 | xargs -r rm -f   # lokalnie 7 ostatnich

log "restic: dumpy Postgres..."
restic backup "$DUMP_DIR" --host "$HOST" --tag postgres --tag daily 2>&1 | tee -a "$LOG"

if [ -d /mnt/minio-data ]; then
  log "restic: MinIO data..."
  restic backup /mnt/minio-data --host "$HOST" --tag minio --tag daily 2>&1 | tee -a "$LOG"
fi

log "restic: configs..."
restic backup /etc/postgresql /etc/redis/redis.conf /etc/minio /etc/barvea \
  --host "$HOST" --tag configs --tag daily 2>&1 | tee -a "$LOG" || log "Configs warn"

log "Forget/prune (host-scoped)..."
restic forget --host "$HOST" --tag daily \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 5 \
  --prune 2>&1 | tee -a "$LOG" || log "Forget warn"

log "Backup done (host=$HOST)"
