#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — backup-enable.sh (instalator v2, 2026-11-24): włącza nocny backup off-site
# (restic → SFTP) na hoście i gościach instancji. Wołany przez bootstrap.sh (verify),
# gdy BACKUP_TARGET != skip, albo PÓŹNIEJ ręcznie (decyzja Miko 2026-11-19: wizard
# może pominąć backup, backup-enable.sh dodaje go bez reinstalacji).
#
# Uruchamiać na HOŚCIE jako root, z katalogu barvea-infra. Czyta ./bootstrap.conf
# (BACKUP_TARGET, BACKUP_SFTP, LAN, CI_USER) i /root/barvea-bootstrap-creds.txt.
# Argumenty: [user@host:/sciezka] (nadpisuje BACKUP_SFTP) ; env RESTIC_PASSWORD (inaczej generuje).
#
# Co robi (idempotentnie):
#  1. hasło repo restic → creds + /root/.config/restic/password na hoście i VM 101/102 (to samo);
#  2. klucz ssh ed25519 PER WĘZEŁ (/root/.ssh/storagebox) + alias `storagebox` w /root/.ssh/config;
#     wypisuje klucze publiczne — operator dodaje je do authorized_keys celu SFTP (Storage Box:
#     Robot/panel; SFTP klienta: ich admin) i potwierdza;
#  3. restic init (host) + test `restic snapshots` z każdego węzła;
#  4. instaluje skrypty z backup/ + unity barvea-backup.{service,timer}: host 04:15 (orgs, Vault,
#     configi), VM 101 03:09 (pg_dump + MinIO), VM 102 03:45 (~/barvea, wolumeny Caddy);
#  5. pierwszy run na hoście.
# Wyłączenie: systemctl disable --now barvea-backup.timer na węźle.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR=$(pwd)
[ -f ./bootstrap.conf ] && . ./bootstrap.conf
LAN="${LAN:-10.10.0}"; CI_USER="${CI_USER:-miko}"; KEY=/root/.ssh/barvea-bootstrap
CREDS=/root/barvea-bootstrap-creds.txt
TARGET="${1:-${BACKUP_SFTP:-}}"
[ -n "$TARGET" ] || { echo "Podaj cel SFTP: ./backup-enable.sh user@host:/sciezka"; exit 1; }
SFTP_USERHOST="${TARGET%%:*}"; SFTP_PATH="${TARGET#*:}"
SFTP_USER="${SFTP_USERHOST%@*}"; SFTP_HOST="${SFTP_USERHOST#*@}"
SFTP_PORT="${BACKUP_SFTP_PORT:-$([ "$SFTP_HOST" != "${SFTP_HOST%your-storagebox.de}" ] && echo 23 || echo 22)}"
REPO_PATH="${SFTP_PATH#/}"; REPO_PATH="${REPO_PATH:-barvea-restic}"

log(){ printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
vm_ssh(){ local ip="$1"; shift; ssh -o StrictHostKeyChecking=accept-new -i "$KEY" "$CI_USER@$ip" "sudo bash -c '$*'"; }
vm_put(){ local ip="$1" src="$2" dst="$3"; scp -q -o StrictHostKeyChecking=accept-new -i "$KEY" "$src" "$CI_USER@$ip:/tmp/.be.$$"; vm_ssh "$ip" "mv /tmp/.be.$$ $dst"; }

NODES=("host" "${LAN}.20" "${LAN}.30")   # host, VM 101 data, VM 102 app (VM 100 = tylko klucze WG → w backupie hosta? NIE: /etc/wireguard VM100 → TODO)

log "1. hasło repo restic"
PW="${RESTIC_PASSWORD:-}"
if [ -f /root/.config/restic/password ]; then PW=$(cat /root/.config/restic/password); fi
[ -n "$PW" ] || { PW=$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 48); echo "RESTIC_REPO_PASSWORD=$PW" >> "$CREDS"; chmod 600 "$CREDS"; }
mkdir -p /root/.config/restic && printf '%s' "$PW" > /root/.config/restic/password && chmod 600 /root/.config/restic/password
command -v restic >/dev/null || apt-get install -y restic jq >/dev/null
for ip in "${NODES[@]:1}"; do
  vm_ssh "$ip" "command -v restic >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y restic jq >/dev/null; mkdir -p /root/.config/restic; printf %s \"$PW\" > /root/.config/restic/password; chmod 600 /root/.config/restic/password"
done

log "2. klucze ssh per węzeł + alias storagebox"
SSHCFG="Host storagebox
    HostName $SFTP_HOST
    User $SFTP_USER
    Port $SFTP_PORT
    IdentityFile /root/.ssh/storagebox
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new"
[ -f /root/.ssh/storagebox ] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/storagebox -C "barvea-host-backup" >/dev/null
grep -q '^Host storagebox' /root/.ssh/config 2>/dev/null || printf '%s\n' "$SSHCFG" >> /root/.ssh/config
chmod 600 /root/.ssh/config
PUBS="host: $(cat /root/.ssh/storagebox.pub)"
for ip in "${NODES[@]:1}"; do
  vm_ssh "$ip" "[ -f /root/.ssh/storagebox ] || ssh-keygen -t ed25519 -N \"\" -f /root/.ssh/storagebox -C barvea-$ip-backup >/dev/null; grep -q \"^Host storagebox\" /root/.ssh/config 2>/dev/null || printf \"%s\\n\" \"$SSHCFG\" >> /root/.ssh/config; chmod 600 /root/.ssh/config"
  PUBS+=$'\n'"$ip: $(vm_ssh "$ip" 'cat /root/.ssh/storagebox.pub')"
done
cat <<EOF

  ┌─ Dodaj te klucze publiczne do authorized_keys celu SFTP ($SFTP_USER@$SFTP_HOST:$SFTP_PORT) ─┐
$PUBS
  └───────────────────────────────────────────────────────────────────────────────┘
EOF
read -r -p "Klucze dodane? [Enter = kontynuuj, Ctrl-C = przerwij] " _

log "3. restic init + test z każdego węzła"
export RESTIC_REPOSITORY="sftp:storagebox:$REPO_PATH" RESTIC_PASSWORD_FILE=/root/.config/restic/password
restic snapshots >/dev/null 2>&1 || restic init
for ip in "${NODES[@]:1}"; do
  vm_ssh "$ip" "printf 'RESTIC_REPOSITORY=sftp:storagebox:$REPO_PATH\n' > /etc/barvea/restic.env 2>/dev/null || { mkdir -p /etc/barvea; printf 'RESTIC_REPOSITORY=sftp:storagebox:$REPO_PATH\n' > /etc/barvea/restic.env; }; RESTIC_REPOSITORY=sftp:storagebox:$REPO_PATH RESTIC_PASSWORD_FILE=/root/.config/restic/password restic snapshots >/dev/null && echo \"  ✓ $ip widzi repo\""
done
printf 'RESTIC_REPOSITORY=sftp:storagebox:%s\n' "$REPO_PATH" > /etc/barvea/restic.env 2>/dev/null || { mkdir -p /etc/barvea; printf 'RESTIC_REPOSITORY=sftp:storagebox:%s\n' "$REPO_PATH" > /etc/barvea/restic.env; }

log "4. skrypty + timery"
# host: orgs + Vault + configi (04:15)
sed "s|^export RESTIC_REPOSITORY=.*|export RESTIC_REPOSITORY=\"sftp:storagebox:$REPO_PATH\"|" backup/barvea-host-backup.sh > /usr/local/sbin/barvea-host-backup.sh
chmod 755 /usr/local/sbin/barvea-host-backup.sh
cp backup/barvea-backup.host.service /etc/systemd/system/barvea-backup.service
cp backup/barvea-backup.host.timer   /etc/systemd/system/barvea-backup.timer
systemctl daemon-reload && systemctl enable --now barvea-backup.timer
# VM 101: pg_dump + MinIO (03:09)
sed "s|^export RESTIC_REPOSITORY=.*|export RESTIC_REPOSITORY=\"\${RESTIC_REPOSITORY:-sftp:storagebox:$REPO_PATH}\"|" backup/barvea-data-backup.sh > /tmp/.bd.$$
vm_put "${LAN}.20" /tmp/.bd.$$ /usr/local/sbin/barvea-data-backup.sh; rm -f /tmp/.bd.$$
vm_ssh "${LAN}.20" "chmod 755 /usr/local/sbin/barvea-data-backup.sh
  printf '[Unit]\nDescription=Barvea DATA nightly backup (pg_dump+minio) to SFTP\nAfter=network-online.target postgresql.service\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/barvea-data-backup.sh\nTimeoutStartSec=4h\n' > /etc/systemd/system/barvea-backup.service
  printf '[Unit]\nDescription=Run Barvea DATA backup nightly 03:09\n[Timer]\nOnCalendar=*-*-* 03:09:00\nRandomizedDelaySec=15min\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/barvea-backup.timer
  systemctl daemon-reload && systemctl enable --now barvea-backup.timer"
# VM 102: ~/barvea (+ .env.production = sekrety instancji!) + wolumeny Caddy (03:45)
sed -e "s|^export RESTIC_REPOSITORY=.*|export RESTIC_REPOSITORY=\"sftp:storagebox:$REPO_PATH\"|" -e "s|/home/miko/barvea|/home/$CI_USER/barvea|g" backup/barvea-app-backup.sh > /tmp/.ba.$$
vm_put "${LAN}.30" /tmp/.ba.$$ /usr/local/sbin/barvea-app-backup.sh; rm -f /tmp/.ba.$$
vm_ssh "${LAN}.30" "chmod 755 /usr/local/sbin/barvea-app-backup.sh
  printf '[Unit]\nDescription=Barvea APP nightly backup to SFTP\nAfter=network-online.target docker.service\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/barvea-app-backup.sh\nTimeoutStartSec=2h\n' > /etc/systemd/system/barvea-backup.service
  printf '[Unit]\nDescription=Run Barvea APP backup nightly 03:45\n[Timer]\nOnCalendar=*-*-* 03:45:00\nRandomizedDelaySec=15min\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/barvea-backup.timer
  systemctl daemon-reload && systemctl enable --now barvea-backup.timer"

log "5. pierwszy run na hoście (orgs/Vault/configi)"
/usr/local/sbin/barvea-host-backup.sh | tail -5 || echo "⚠️ pierwszy run hosta z błędem — sprawdź /var/log/barvea-backup.log"
restic snapshots --compact | tail -8
echo
echo "  ✓ Backup włączony: host 04:15, VM 101 03:09, VM 102 03:45 → sftp:storagebox:$REPO_PATH"
echo "    Hasło repo: /root/.config/restic/password (kopia w $CREDS) — bez niego backup jest BEZUŻYTECZNY. Zabierz poza serwer."
