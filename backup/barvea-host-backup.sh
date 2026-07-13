#!/bin/bash
# BARVEA — barvea-HOST nightly backup → Hetzner Storage Box (restic).
# NOWY (2026-07-13): domyka lukę off-site dla /hddpool/orgs (dane CDE/Drive),
# Vault data (LXC 200) i host-configów. Wzorzec 1:1 jak VM-ki
# (barvea-app-backup.sh). Instalacja: backup/README.md.
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

# ── GUARD: org-datasety muszą być ODBLOKOWANE. Zamknięty dataset =
# pusty mountpoint = restic zbackupowałby PUSTKĘ (a retencja z czasem
# wypchnęłaby dobre snapshoty). Locked → twardy abort sekcji orgs. ──
LOCKED=0
while read -r ds keystatus; do
    if [ "$keystatus" != "available" ] && [ "$keystatus" != "-" ]; then
        log "ERROR: $ds keystatus=$keystatus (locked) — pomijam orgs!"
        LOCKED=1
    fi
done < <(zfs list -H -o name,keystatus -r hddpool/orgs | tail -n +2)

if [ "$LOCKED" = 0 ]; then
    log "Org data (/hddpool/orgs — CDE/Drive)..."
    restic backup /hddpool/orgs \
      --host "$HOST" --tag orgs --tag daily 2>&1 | tee -a "$LOG"
else
    log "orgs SKIPPED (locked) — uruchom /usr/local/sbin/zfs-load-org.sh!"
fi

# ── Vault data z NAJNOWSZEGO sanoid-snapshotu subvola LXC 200 =
# crash-consistent kopia file-backendu (nie kopiujemy żywych plików). ──
VSNAP=$(ls -d /hddpool/subvol-200-disk-0/.zfs/snapshot/autosnap_* 2>/dev/null | sort | tail -1 || true)
if [ -n "$VSNAP" ] && [ -d "$VSNAP/opt/vault/data" ]; then
    log "Vault data (snapshot $(basename "$VSNAP"))..."
    restic backup "$VSNAP/opt/vault/data" \
      --host "$HOST" --tag vault --tag daily 2>&1 | tee -a "$LOG"
else
    log "WARN: brak sanoid-snapshotu subvol-200 — Vault pominięty"
fi

log "Host configs (zfs keys .ct, vault approle, pve defs, net, skrypty)..."
restic backup \
  /etc/zfs/keys \
  /etc/vault \
  /etc/pve/lxc /etc/pve/qemu-server \
  /etc/nftables.conf \
  /etc/sanoid \
  /etc/fail2ban/jail.local \
  /usr/local/sbin \
  --host "$HOST" --tag configs --tag daily 2>&1 | tee -a "$LOG" || log "Configs warn"

# ── Configi WEWNĄTRZ LXC (rootfs-y na subvolach hosta — restic VM-ek ich
# NIE widzi, a bez nich odtworzenie 200/201 = ręczna rekonstrukcja):
# 201: tokeny daemonów (/etc/barvea), smb.conf+per-org share'y, uid-counter;
# 200: vault.hcl. (ACL-state /var/lib/barvea-acl celowo NIE — cache,
# odbuduje się z manifestu APP przy pierwszym pullu.) ──
log "LXC configs (201: barvea+samba+uid-counter, 200: vault.d)..."
restic backup \
  /hddpool/subvol-201-disk-0/etc/barvea \
  /hddpool/subvol-201-disk-0/etc/samba \
  /hddpool/subvol-201-disk-0/var/lib/barvea-smb \
  /hddpool/subvol-200-disk-0/etc/vault.d \
  --host "$HOST" --tag lxc-configs --tag daily 2>&1 | tee -a "$LOG" || log "LXC configs warn"

log "Forget/prune (host-scoped)..."
restic forget --host "$HOST" --tag daily \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 5 \
  --prune 2>&1 | tee -a "$LOG" || log "Forget warn"

log "Backup done (host=$HOST)"
