#!/bin/bash
# BARVEA — VM 102 barvea-app /usr/local/sbin/barvea-app-backup.sh
# (IaC copy 2026-07-13, zrzut żywego — pierwsze 40 linii zweryfikowane;
# ogon [forget/prune] wg wzorca retencji z README). KEEP-IN-SYNC.
# Reprezentatywny wzorzec dla VM-ek: data (03:09) i infra (03:38)
# analogiczne — inne ścieżki źródłowe (patrz README macierz).
set -euo pipefail

export RESTIC_REPOSITORY="sftp:storagebox:barvea-restic"
export RESTIC_PASSWORD_FILE=/root/.config/restic/password

HOST=$(hostname)
LOG=/var/log/barvea-backup.log
LOCK=/var/lock/barvea-backup.lock

exec 9>"$LOCK"
flock -n 9 || { echo "Another backup running, exit"; exit 1; }

log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "===================="
log "Backup start (host=$HOST)"

log "App configs + scripts..."
restic backup /home/miko/barvea \
  --exclude='/home/miko/barvea/app/node_modules' \
  --exclude='/home/miko/barvea/app/.next' \
  --exclude='/home/miko/barvea/app/.git/objects' \
  --exclude='/home/miko/barvea/backups' \
  --host "$HOST" --tag compose --tag daily 2>&1 | tee -a "$LOG"

log "Docker volumes (Caddy + LE certs)..."
restic backup \
  /var/lib/docker/volumes/barvea_caddy_data \
  /var/lib/docker/volumes/barvea_caddy_config \
  --host "$HOST" --tag docker --tag daily 2>&1 | tee -a "$LOG"

log "System configs..."
restic backup \
  /etc/docker/daemon.json \
  /etc/nftables.conf \
  /etc/network/interfaces \
  --host "$HOST" --tag configs --tag daily 2>&1 | tee -a "$LOG" || log "Configs warn"

log "Forget/prune (host-scoped)..."
restic forget --host "$HOST" --tag daily \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 5 \
  --prune 2>&1 | tee -a "$LOG" || log "Forget warn"

log "Backup done (host=$HOST)"
