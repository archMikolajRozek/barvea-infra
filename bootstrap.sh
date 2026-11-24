#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — bootstrap.sh v1: stawia CAŁY stack na świeżym Proxmox-hoście.
# Szkielet installera dedyk (fazy 1-3; kreator/licencja/superadmin = fazy
# 0/4/5 installera, dojdą). Źródło prawdy per komponent: katalogi repo
# (network/ proxmox/ vault/ backup/ storage/ wg-control/) — zrzuty 1:1
# z proda 2026-07-13. ⚠️ v1 NIETESTOWANY na żywo — pierwszy run wyłącznie
# na maszynie testowej (nested Proxmox / zapasowy serwer), NIE na prodzie.
#
# Użycie:  ./bootstrap.sh [faza]         # bez arg = wszystkie po kolei
#   fazy:  preflight host guests services verify
# Config:  ./bootstrap.conf (opcjonalny; defaulty niżej = layout proda)
# Stan:    /var/lib/barvea-bootstrap/  (checkpointy — re-run pomija zrobione)
# Creds:   /root/barvea-bootstrap-creds.txt (0600 — hasła/tokeny wygenerowane)
#
# OFFLINE (dedyk air-gap): ustaw ASSETS_DIR na katalog z pobranymi
# artefaktami (template LXC, cloud-image, *.deb/mirror, bundle app) —
# fetch() bierze lokalne zamiast internetu. Online (nasz serwer): puste.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── CONFIG (defaulty = prod; nadpisz w ./bootstrap.conf) ────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$REPO_DIR/bootstrap.conf" ] && . "$REPO_DIR/bootstrap.conf"

POOL_NAME="${POOL_NAME:-hddpool}"
POOL_RAID="${POOL_RAID:-raidz2}"          # raidz2|mirror
POOL_DISKS="${POOL_DISKS:-}"              # "/dev/disk/by-id/... ..." — WYMAGANE gdy pool nie istnieje
PVE_STORAGE="${PVE_STORAGE:-hdd-pool}"    # id storage Proxmoxa nad poolem
LAN="${LAN:-10.10.0}"                     # /24 prefix
BR_PUB="${BR_PUB:-vmbr0}"; BR_LAN="${BR_LAN:-vmbr1}"
SSH_PORT="${SSH_PORT:-2277}"
PRESET="${PRESET:-prod}"                  # prod|staging (staging = małe goście)
# WG — PARAMETRYZOWANE (kolizje z siecią klienta/prodem! kreator pyta,
# preflight sprawdza). Defaulty = prod. Staging przykład: 10.68/16, 10.19/24,
# porty 51920/51921.
WG_USERS_CIDR="${WG_USERS_CIDR:-10.67.0.0/16}"
WG_USERS_ADDR="${WG_USERS_ADDR:-10.67.0.1/16}"
WG_USERS_PORT="${WG_USERS_PORT:-51821}"
WG0_CIDR="${WG0_CIDR:-10.9.0.0/24}"
WG0_ADDR="${WG0_ADDR:-10.9.0.1/24}"
WG0_PORT="${WG0_PORT:-51820}"
ASSETS_DIR="${ASSETS_DIR:-}"              # air-gap: katalog artefaktów
# ── wizard v2 (2026-11-24, INSTALATOR-PLAN §D2/D3): pule, hosty, moduły, rozmiary ──
BULK_DISKS="${BULK_DISKS:-}"              # druga pula (HDD) na dane org; pusta = orgs na POOL_NAME
BULK_RAID="${BULK_RAID:-mirror}"
BULK_POOL_NAME="${BULK_POOL_NAME:-bulk}"
ORGS_POOL="$POOL_NAME"; [ -n "$BULK_DISKS" ] && ORGS_POOL="$BULK_POOL_NAME"   # gdzie żyje <pool>/orgs
INTERNAL_DOMAIN="${INTERNAL_DOMAIN:-barvea.internal}"
APP_HOST="${APP_HOST:-app.$INTERNAL_DOMAIN}"; DRIVE_HOST="${DRIVE_HOST:-drive.$INTERNAL_DOMAIN}"; ADMIN_HOST="${ADMIN_HOST:-admin.$INTERNAL_DOMAIN}"
PUBLIC_FQDN="${PUBLIC_FQDN:-}"
MOD_DRIVE="${MOD_DRIVE:-1}"; MOD_AV="${MOD_AV:-1}"; MOD_COLLAB="${MOD_COLLAB:-1}"; MOD_POINTCLOUD="${MOD_POINTCLOUD:-0}"; MOD_IFC="${MOD_IFC:-1}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
VM102_CORES="${VM102_CORES:-8}"; VM102_MEM_MB="${VM102_MEM_MB:-32768}"; LXC201_MEM_MB="${LXC201_MEM_MB:-16384}"
VAULT_KEYS="${VAULT_KEYS:-file}"          # file = auto init → /root/barvea-vault-keys.json; split = ceremonia ręczna
BACKUP_TARGET="${BACKUP_TARGET:-skip}"; BACKUP_SFTP="${BACKUP_SFTP:-}"
LXC_TEMPLATE="${LXC_TEMPLATE:-debian-13-standard}"   # pveam nazwa-prefix
CLOUD_IMG_URL="${CLOUD_IMG_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
CI_USER="${CI_USER:-miko}"
STATE=/var/lib/barvea-bootstrap
CREDS=/root/barvea-bootstrap-creds.txt
KEY=/root/.ssh/barvea-bootstrap           # klucz do VM-ek (cloud-init)

# guest defs: id name ip cores mem(MB) balloon disk rola
if [ "$PRESET" = compact ]; then    # 1-VM all-in-one (dedyk mały klient):
  # DB/redis/minio = KONTENERY w bundlu dedyk (compose), NIE osobne goście.
  # Vault/Samba/WG pomijane — bez modułu drive + licencja weryfikowana
  # in-app (pubkey hardcode, nie potrzebuje Vaulta). ⚠️ NIETESTOWANE.
  GUESTS_LXC=( )
  GUESTS_VM=(  "102 barvea-app ${LAN}.30 4 8192 - 120 app 1" )
  UPLOAD_TMP_GB=100
elif [ "$PRESET" = staging ]; then  # małe goście — test/staging (VM-w-VM,
  # suma RAM ~10G → mieści się w 12G nested-hoście z zapasem na PVE)
  GUESTS_LXC=( "200 vault    ${LAN}.50 1 1024 - 6  vault"
               "201 storage  ${LAN}.40 2 2048 - 10 storage" )
  GUESTS_VM=(  "100 barvea-infra ${LAN}.10 1 1024 -    20 infra 1"
               "101 barvea-data  ${LAN}.20 2 3072 -    40 data  2"
               "102 barvea-app   ${LAN}.30 2 3072 -    30 app   3" )
  UPLOAD_TMP_GB=20
else
  # rozmiary VM 102 / LXC 201 z kreatora (moduły → RAM); defaulty = prod 2026-11 (8c/32G, 16G)
  GUESTS_LXC=( "200 vault    ${LAN}.50 2 2048 - 8  vault"
               "201 storage  ${LAN}.40 4 $LXC201_MEM_MB - 16 storage" )   # 16G z clamd (sygnatury ~1.5G), 8G bez AV
  GUESTS_VM=(  "100 barvea-infra ${LAN}.10 2 4096  -    50  infra 1"
               "101 barvea-data  ${LAN}.20 4 24576 8192 200 data  2"
               "102 barvea-app   ${LAN}.30 $VM102_CORES $VM102_MEM_MB -    80  app   3" )   # bez balloona (OOM 2026-09-05)
  UPLOAD_TMP_GB=1000
fi

# ── helpers ─────────────────────────────────────────────────────────
log()  { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
done_f(){ [ -f "$STATE/$1.done" ]; }
mark() { mkdir -p "$STATE"; touch "$STATE/$1.done"; }
# UWAGA pipefail: `tr </dev/urandom | head` = SIGPIPE tr (rc141) = set -e
# ubija skrypt (run2 staging, zdechł na WGTOK=$(gen)). dd ogranicza wejście.
gen()  { dd if=/dev/urandom bs=256 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${1:-48}"; }
cred() { printf '%s\n' "$*" >> "$CREDS"; chmod 600 "$CREDS"; }
fetch(){ # fetch <url> <dst> — ASSETS_DIR first (air-gap), inaczej download
  local url="$1" dst="$2" base; base=$(basename "$url")
  if [ -n "$ASSETS_DIR" ] && [ -f "$ASSETS_DIR/$base" ]; then
      cp "$ASSETS_DIR/$base" "$dst"; return; fi
  [ -n "$ASSETS_DIR" ] && die "air-gap: brak $base w $ASSETS_DIR"
  curl -fsSL -o "$dst" "$url"
}
vm_ssh(){ local ip="$1"; shift; ssh -o StrictHostKeyChecking=accept-new -i "$KEY" "$CI_USER@$ip" "sudo bash -c '$*'"; }
# vm_put: plik przez stdin → `install` jako root (bez etapu w /tmp gościa — przegląd 2026-11-24); $4 = mode (domyślnie 644)
vm_put(){ local ip="$1" src="$2" dst="$3" mode="${4:-644}"; ssh -o StrictHostKeyChecking=accept-new -i "$KEY" "$CI_USER@$ip" "sudo install -m $mode -o root -g root -D /dev/stdin $dst" < "$src"; }
wait_ssh(){ local ip="$1" n=0; until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 -i "$KEY" "$CI_USER@$ip" true 2>/dev/null; do n=$((n+1)); [ $n -gt 60 ] && die "ssh $ip timeout"; sleep 5; done; }

# ═══ FAZA: preflight ════════════════════════════════════════════════
phase_preflight() {
  log "PREFLIGHT"
  [ "$(id -u)" = 0 ] || die "uruchom jako root"
  command -v pveversion >/dev/null || die "to nie Proxmox (brak pveversion)"
  for f in network/host-nftables.conf network/host-fail2ban-jail.local \
           proxmox/sanoid.conf proxmox/zfs-load-org.sh vault/vault.hcl.template \
           vault/bootstrap-vault.sh network/wg-users.conf.template \
           network/wg0.conf.template storage/samba/smb.conf.global.template \
           storage/samba/per-org.conf.template storage/barvea-datad.py \
           storage/smb-provisiond.py storage/barvea-acl-sync.py \
           wg-control/wg-provisiond.py backup/barvea-host-backup.sh \
           Caddyfile.dedicated.template network/dnsmasq-wg-users.conf storage/systemd/smb-reconcile.timer; do
      [ -f "$REPO_DIR/$f" ] || die "brak $f w repo ($REPO_DIR)"
  done
  if ! zpool list "$POOL_NAME" >/dev/null 2>&1; then
      [ -n "$POOL_DISKS" ] || die "pool $POOL_NAME nie istnieje — ustaw POOL_DISKS w bootstrap.conf"
  fi
  # kolizje podsieci (LAN klienta/prod vs nasze) — FORCE_NETS=1 wymusza
  for net in "${LAN}.0/24" "$WG_USERS_CIDR" "$WG0_CIDR"; do
      if ip route | grep -qw "$net" && [ "${FORCE_NETS:-0}" != 1 ]; then
          die "podsieć $net JUŻ w tablicy routingu (kolizja!) — zmień w bootstrap.conf albo FORCE_NETS=1"
      fi
  done
  touch "$CREDS"; chmod 600 "$CREDS"
  mark preflight
}

# ═══ FAZA: host (pool, firewall, sanoid, mostek, ssh) ═══════════════
phase_host() {
  log "HOST: ZFS pool"
  if ! zpool list "$POOL_NAME" >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      zpool create -o ashift=12 "$POOL_NAME" "$POOL_RAID" $POOL_DISKS
  fi
  zfs set compression=lz4 atime=off xattr=sa acltype=posix "$POOL_NAME"
  # Druga pula BULK (HDD) na dane organizacji — decyzja Miko 2026-11-19: fast/bulk;
  # jeden nośnik = jedna pula (ORGS_POOL = POOL_NAME).
  if [ -n "$BULK_DISKS" ] && ! zpool list "$BULK_POOL_NAME" >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      zpool create -o ashift=12 "$BULK_POOL_NAME" "$BULK_RAID" $BULK_DISKS
      zfs set compression=lz4 atime=off xattr=sa acltype=posix "$BULK_POOL_NAME"
  fi
  zfs list "$ORGS_POOL/orgs" >/dev/null 2>&1 || zfs create "$ORGS_POOL/orgs"
  zfs set compression=zstd "$ORGS_POOL/orgs"
  # sparse=1 (thin): zvole bez refreservation — inaczej suma dysków gości
  # musi zmieścić się w poolu Z GÓRY (run1 staging: resize 101 padł na
  # mirror 60G). Trade: pilnować zapełnienia poola (zfs list).
  pvesm status 2>/dev/null | grep -q "^$PVE_STORAGE " || \
      pvesm add zfspool "$PVE_STORAGE" --pool "$POOL_NAME" --sparse 1

  log "HOST: mostek LAN $BR_LAN"
  if ! grep -q "iface $BR_LAN" /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null; then
      cat > "/etc/network/interfaces.d/$BR_LAN" <<EOF
auto $BR_LAN
iface $BR_LAN inet static
    address ${LAN}.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
      ifreload -a || echo "⚠️  ifreload padł — sprawdź sieć zanim polecisz dalej"
  fi

  log "HOST: repo apt (świeży PVE: enterprise bez subskrypcji psuje apt)"
  for f in /etc/apt/sources.list.d/pve-enterprise.sources \
           /etc/apt/sources.list.d/pve-enterprise.list \
           /etc/apt/sources.list.d/ceph.sources; do
      [ -f "$f" ] && mv "$f" "$f.disabled"
  done
  if ! grep -rq pve-no-subscription /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
      echo "deb http://download.proxmox.com/debian/pve $(. /etc/os-release; echo "$VERSION_CODENAME") pve-no-subscription" \
          > /etc/apt/sources.list.d/pve-no-sub.list
  fi
  apt-get update -qq || true

  log "HOST: nftables + fail2ban + sanoid + zfs-load-org"
  # template ma literały proda (10.10.0.*, 51820/51821) → podstaw parametry
  sed -e "s|10\.10\.0\.|${LAN}.|g" -e "s|51821|$WG_USERS_PORT|g" \
      -e "s|51820|$WG0_PORT|g" \
      "$REPO_DIR/network/host-nftables.conf" > /etc/nftables.conf
  systemctl enable --now nftables
  DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban sanoid jq >/dev/null
  install -m 644 "$REPO_DIR/network/host-fail2ban-jail.local" /etc/fail2ban/jail.local
  systemctl enable --now fail2ban
  mkdir -p /etc/sanoid   # pakiet Debiana NIE tworzy katalogu (quirk, run1 staging)
  install -m 644 "$REPO_DIR/proxmox/sanoid.conf" /etc/sanoid/sanoid.conf
  systemctl enable --now sanoid.timer
  install -m 755 "$REPO_DIR/proxmox/zfs-load-org.sh" /usr/local/sbin/zfs-load-org.sh
  mkdir -p /etc/zfs/keys /etc/vault

  if [ "$SSH_PORT" != 22 ] && ! grep -qE "^Port $SSH_PORT" /etc/ssh/sshd_config; then
      sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
      systemctl reload sshd
      echo "⚠️  SSH hosta przełączony na $SSH_PORT — NIE zamykaj tej sesji bez testu nowego portu!"
  fi
  mark host
}

# ═══ FAZA: goście (LXC z template, VM z cloud-init) ═════════════════
phase_guests() {
  log "GOŚCIE: klucz ssh + obrazy"
  [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -f "$KEY" -C barvea-bootstrap >/dev/null

  local tmpl
  tmpl=$(pveam list local 2>/dev/null | awk "/$LXC_TEMPLATE/ {print \$1; exit}")
  if [ -z "$tmpl" ]; then
      if [ -n "$ASSETS_DIR" ]; then
          cp "$ASSETS_DIR/${LXC_TEMPLATE}"*.tar.* /var/lib/vz/template/cache/
      else
          pveam update >/dev/null
          pveam download local "$(pveam available --section system | awk "/$LXC_TEMPLATE/ {print \$2; exit}")"
      fi
      tmpl=$(pveam list local | awk "/$LXC_TEMPLATE/ {print \$1; exit}")
  fi
  [ -n "$tmpl" ] || die "brak template LXC $LXC_TEMPLATE"

  local IMG=/var/lib/vz/template/debian-cloud.qcow2
  [ -f "$IMG" ] || fetch "$CLOUD_IMG_URL" "$IMG"

  log "GOŚCIE: LXC"
  for def in "${GUESTS_LXC[@]}"; do
      # shellcheck disable=SC2086
      set -- $def; local id=$1 name=$2 ip=$3 cores=$4 mem=$5 disk=$7
      pct status "$id" >/dev/null 2>&1 && continue
      pct create "$id" "$tmpl" -hostname "$name" -cores "$cores" -memory "$mem" \
          -swap 512 -rootfs "$PVE_STORAGE:$disk" -unprivileged 1 -features nesting=1 \
          -net0 "name=eth0,bridge=$BR_LAN,gw=${LAN}.1,ip=$ip/24,type=veth" -onboot 1
      pct start "$id"; sleep 3
      # unattended-upgrades: obraz cloud Debiana (VM) ma to z pudelka, szablon LXC NIE.
      # Prod 2026-10-23: LXC 200 (Vault) 5 miesiecy bez apt update, zero latek security.
      # Domyslny config = tylko origin Debian-Security (nie rusza Vaulta z repo HashiCorp).
      pct exec "$id" -- bash -c "echo '$ip $name' >> /etc/hosts; apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades >/dev/null
        printf 'APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
' > /etc/apt/apt.conf.d/20auto-upgrades
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
  done

  log "GOŚCIE: VM (cloud-init)"
  for def in "${GUESTS_VM[@]}"; do
      # shellcheck disable=SC2086
      set -- $def; local id=$1 name=$2 ip=$3 cores=$4 mem=$5 balloon=$6 disk=$7 order=$9
      qm status "$id" >/dev/null 2>&1 && continue
      qm create "$id" -name "$name" -machine q35 -cpu host -cores "$cores" -sockets 1 \
          -memory "$mem" -net0 "virtio,bridge=$BR_LAN" -scsihw virtio-scsi-single \
          -agent 1 -onboot 1 -startup "order=$order"
      [ "$balloon" != "-" ] && qm set "$id" -balloon "$balloon"
      qm importdisk "$id" "$IMG" "$PVE_STORAGE" >/dev/null
      qm set "$id" -scsi0 "$PVE_STORAGE:vm-$id-disk-0,cache=writeback,discard=on,iothread=1"
      qm resize "$id" scsi0 "${disk}G"
      # qm resize potrafi zwrócić 0 mimo "zfs error: size greater than
      # available space" (run1 staging) — twarda weryfikacja volsize:
      local vs; vs=$(zfs get -H -o value volsize "$POOL_NAME/vm-$id-disk-0" 2>/dev/null || echo 0)
      [ "$vs" = "${disk}G" ] || die "VM $id: dysk $vs zamiast ${disk}G (pool pełny? sparse?)"
      qm set "$id" -ide2 "$PVE_STORAGE:cloudinit" -boot order=scsi0 \
          -ciuser "$CI_USER" -sshkeys "$KEY.pub" \
          -ipconfig0 "ip=$ip/24,gw=${LAN}.1" -nameserver "1.1.1.1 1.0.0.1"
      qm start "$id"
  done
  # data VM: drugi dysk 10T (jak prod) — tylko gdy jest miejsce; opcjonalne
  # qm set 101 -scsi1 "$PVE_STORAGE:vm-101-disk-1,...,size=10T"  # TODO wg potrzeb

  # VM 102: OSOBNY dysk pod śluzę uploadu (/srv/upload-tmp, montowany do
  # kontenera app jako /upload-tmp). Aplikacja skleja tam CAŁY plik zanim
  # wyśle go do datad (POST /files nie zna offsetu ani wznowień), więc bez
  # osobnego dysku jeden upload kilkudziesięciu GB zapełnia root i kładzie
  # Next + Caddy — dokładnie to zdarzyło się na prodzie 2026-08-31.
  # volblocksize=64k, NIE domyślne 8k: pula to raidz2, przy 8k blok zajmuje
  # na dyskach 24 KiB (efektywność ~33%), przy 64k ~48%. `qm set` tworzy zvol
  # z domyślnym 8k ze storage, więc tworzymy go ręcznie i dopiero podpinamy.
  if qm status 102 >/dev/null 2>&1 && ! qm config 102 | grep -q '^scsi1:'; then
      zfs list "$POOL_NAME/vm-102-disk-1" >/dev/null 2>&1 ||           zfs create -V "${UPLOAD_TMP_GB}G" -b 64k "$POOL_NAME/vm-102-disk-1"
      qm set 102 -scsi1 "$PVE_STORAGE:vm-102-disk-1,cache=writeback,discard=on,iothread=1"
  fi
  for def in "${GUESTS_VM[@]}"; do set -- $def; wait_ssh "$3"; done
  mark guests
}

# ═══ FAZA: usługi per węzeł ═════════════════════════════════════════
svc_infra() {  # VM 100 — WG hub + wg-provisiond
  local ip="${LAN}.10"
  # nftables: PostUp wg0 (tabela wg_nat) — cloud-image go NIE ma (run3 staging)
  vm_ssh "$ip" "DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables nftables python3 dnsmasq >/dev/null
    sysctl -w net.ipv4.ip_forward=1; echo net.ipv4.ip_forward=1 > /etc/sysctl.d/99-wg.conf
    umask 077; cd /etc/wireguard
    [ -f server_private.key ] || { wg genkey | tee server_private.key | wg pubkey > server_public.key; }
    [ -f wg0_private.key ]    || { wg genkey | tee wg0_private.key    | wg pubkey > wg0_public.key; }"
  local T=/tmp/.wg.$$
  # template'y = literały proda → podstaw parametry sieci (kolizje!)
  sed -e "s|__WG_USERS_SERVER_PRIVATE_KEY__|$(vm_ssh "$ip" 'cat /etc/wireguard/server_private.key')|" \
      -e "s|10\.67\.0\.0/16|$WG_USERS_CIDR|g" -e "s|10\.67\.0\.1/16|$WG_USERS_ADDR|" \
      -e "s|51821|$WG_USERS_PORT|" -e "s|10\.10\.0\.|${LAN}.|g" \
      "$REPO_DIR/network/wg-users.conf.template" > "$T"; vm_put "$ip" "$T" /etc/wireguard/wg-users.conf
  sed -e "s|__WG0_SERVER_PRIVATE_KEY__|$(vm_ssh "$ip" 'cat /etc/wireguard/wg0_private.key')|" \
      -e "s|10\.9\.0\.0/24|$WG0_CIDR|g" -e "s|10\.9\.0\.1/24|$WG0_ADDR|" \
      -e "s|51820|$WG0_PORT|" \
      "$REPO_DIR/network/wg0.conf.template" > "$T"; vm_put "$ip" "$T" /etc/wireguard/wg0.conf; rm -f "$T"
  # DNS tunelu wg-users: *.barvea.internal → app/storage (macOS Drive nie ma hosts). Tylko na wg-users.
  vm_put "$ip" "$REPO_DIR/network/dnsmasq-wg-users.conf" /etc/dnsmasq.d/wg-users.conf
  vm_ssh "$ip" "systemctl enable --now dnsmasq; systemctl restart dnsmasq"
  vm_put "$ip" "$REPO_DIR/wg-control/wg-provisiond.py" /usr/local/sbin/wg-provisiond.py 755
  vm_put "$ip" "$REPO_DIR/wg-control/wg-provisiond.service" /etc/systemd/system/wg-provisiond.service
  local WGTOK; WGTOK=$(gen); cred "WG_PROVISIOND_TOKEN=$WGTOK"
  vm_ssh "$ip" "mkdir -p /etc/barvea; printf 'TOKEN=$WGTOK\n' > /etc/barvea/wg-provisiond.env; chmod 600 /etc/barvea/wg-provisiond.env
    chmod 600 /etc/wireguard/*.key /etc/wireguard/*.conf
    systemctl daemon-reload; systemctl enable --now wg-quick@wg-users wg-quick@wg0 wg-provisiond"
}

svc_data() {   # VM 101 — Postgres 18 (PGDG) wg proxmox/vm101-postgres.md
  local ip="${LAN}.20"
  local PGA PGD; PGA=$(gen 32); PGD=$(gen 32)
  cred "PG barvea_app=$PGA barvea_admin=$PGD"
  vm_ssh "$ip" "DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-common >/dev/null
    yes | /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-18 postgresql-18-jit >/dev/null
    PGC=/etc/postgresql/18/main
    grep -q barvea_app \$PGC/pg_hba.conf || cat >> \$PGC/pg_hba.conf <<HBA
host  barvea  barvea_app    ${LAN}.0/24   scram-sha-256
host  all     barvea_admin  10.9.0.0/24   scram-sha-256
host  all     postgres      10.9.0.0/24   scram-sha-256
HBA
    pg_conftool 18 main set listen_addresses localhost,$ip
    systemctl restart postgresql@18-main"
  # SQL PLIKIEM (psql -f) — jedyna odporna droga przez warstwy cytowania
  # vm_ssh (run4/5: apostrofy zjadane, \047 to printf-izm). Idempotencja:
  # DO $$…$$ na role, \gexec na bazę (CREATE DATABASE nie może w DO).
  local SQL=/tmp/.pg.$$
  cat > "$SQL" <<SQLEOF
DO \$\$BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='barvea_app') THEN
    CREATE ROLE barvea_app LOGIN PASSWORD '$PGA';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='barvea_admin') THEN
    CREATE ROLE barvea_admin LOGIN SUPERUSER PASSWORD '$PGD';
  END IF;
END\$\$;
SELECT 'CREATE DATABASE barvea OWNER barvea_app'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='barvea')\gexec
SQLEOF
  vm_put "$ip" "$SQL" /tmp/pg-init.sql
  rm -f "$SQL"
  vm_ssh "$ip" "sudo -u postgres psql -v ON_ERROR_STOP=1 -f /tmp/pg-init.sql && rm -f /tmp/pg-init.sql"
  # TODO tuning (świadomie stock jak prod): shared_buffers itd. — osobna decyzja

  # ── Redis natywnie (prod: VM 101) — bind LAN, hasło → creds (REDIS_URL=redis://:<pw>@<ip>:6379)
  local RP; RP=$(gen 32); cred "REDIS_PASSWORD=$RP"
  # Sekrety do VM przez plik 0600 (scp), NIE przez argv ssh (ps/historia) — przegląd 2026-11-24.
  local SEC=/tmp/.ds.$$; (umask 077; printf 'RP=%s\nMROOT=%s\nMPASS=%s\nMAK=%s\nMSK=%s\n' "$RP" "barvea_root" "$(gen 40)" "barvea_app_minio" "$(gen 40)" > "$SEC")
  # shellcheck disable=SC1090
  . "$SEC"; cred "MINIO_ROOT_USER=$MROOT MINIO_ROOT_PASSWORD=$MPASS"; cred "MINIO_ACCESS_KEY=$MAK MINIO_SECRET_KEY=$MSK"; cred "MINIO_ENDPOINT=$ip"
  vm_put "$ip" "$SEC" /root/.barvea-data-secrets 600; rm -f "$SEC"
  vm_ssh "$ip" "chmod 600 /root/.barvea-data-secrets; . /root/.barvea-data-secrets
    DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server >/dev/null
    sed -i -E \"s/^bind .*/bind 127.0.0.1 $ip/; s/^# *requirepass .*/requirepass \$RP/; s/^requirepass .*/requirepass \$RP/\" /etc/redis/redis.conf
    grep -q \"^requirepass \" /etc/redis/redis.conf || echo \"requirepass \$RP\" >> /etc/redis/redis.conf
    systemctl enable --now redis-server; systemctl restart redis-server"

  # ── MinIO natywnie (prod: binarka + minio.service na VM 101; korekta APP 2026-11-24: MinIO ZOSTAJE —
  #    IFC/podglądy/zdjęcia/raporty/QR/migawki; datad/ZFS = tylko dokumenty CDE). Dane: /mnt/minio-data
  #    (dysk systemowy VM 101 200G; większe instancje: osobny dysk → TODO scsi1 z kreatora).
  #    Pin wersji = prod (RELEASE.2025-09-07T16-13-09Z); air-gap: binarki minio/mc w ASSETS_DIR.
  local MV="${MINIO_RELEASE:-RELEASE.2025-09-07T16-13-09Z}"
  local MB=/tmp/.minio.$$ MC=/tmp/.mc.$$
  fetch "https://dl.min.io/server/minio/release/linux-amd64/archive/minio.$MV" "$MB"
  fetch "https://dl.min.io/client/mc/release/linux-amd64/mc" "$MC"
  vm_put "$ip" "$MB" /usr/local/bin/minio; vm_put "$ip" "$MC" /usr/local/bin/mc; rm -f "$MB" "$MC"
  vm_put "$ip" "$REPO_DIR/proxmox/minio-policy-barvea-app.json" /tmp/minio-policy.json
  # MinIO: TLS off — tylko LAN gości (jak prod); sekrety z /root/.barvea-data-secrets (plik, nie argv).
  vm_ssh "$ip" ". /root/.barvea-data-secrets; chmod 755 /usr/local/bin/minio /usr/local/bin/mc
    id minio-user >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin minio-user
    mkdir -p /mnt/minio-data /etc/minio && chown minio-user: /mnt/minio-data
    printf \"MINIO_ROOT_USER=%s\\nMINIO_ROOT_PASSWORD=%s\\nMINIO_VOLUMES=/mnt/minio-data\\nMINIO_OPTS=--address $ip:9000 --console-address 127.0.0.1:9001\\n\" \"\$MROOT\" \"\$MPASS\" > /etc/minio/minio.conf
    chmod 600 /etc/minio/minio.conf
    printf \"[Unit]\\nDescription=MinIO\\nAfter=network-online.target\\n[Service]\\nUser=minio-user\\nGroup=minio-user\\nEnvironmentFile=/etc/minio/minio.conf\\nExecStart=/usr/local/bin/minio server \\\$MINIO_OPTS \\\$MINIO_VOLUMES\\nRestart=always\\nLimitNOFILE=65536\\n[Install]\\nWantedBy=multi-user.target\\n\" > /etc/systemd/system/minio.service
    systemctl daemon-reload; systemctl enable --now minio; sleep 3
    MC_HOST_local=http://\$MROOT:\$MPASS@$ip:9000 mc admin policy create local barvea-app-policy /tmp/minio-policy.json >/dev/null 2>&1 || true
    MC_HOST_local=http://\$MROOT:\$MPASS@$ip:9000 mc admin user add local \"\$MAK\" \"\$MSK\" >/dev/null 2>&1 || true
    MC_HOST_local=http://\$MROOT:\$MPASS@$ip:9000 mc admin policy attach local barvea-app-policy --user \"\$MAK\" >/dev/null 2>&1 || true
    for b in barvea-assets barvea-docs barvea-ifc barvea-qr barvea-reports; do MC_HOST_local=http://\$MROOT:\$MPASS@$ip:9000 mc mb -p local/\$b >/dev/null 2>&1 || true; done
    rm -f /tmp/minio-policy.json /root/.barvea-data-secrets"
}

svc_vault() {  # LXC 200 — Vault (init/unseal = RĘCZNA ceremonia po bootstrapie)
  pct exec 200 -- bash -c "command -v vault >/dev/null || {
      apt-get install -y wget gpg >/dev/null
      wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
      echo 'deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com bookworm main' > /etc/apt/sources.list.d/hashicorp.list
      apt-get update -qq && apt-get install -y vault >/dev/null; }"   # TODO air-gap: .deb z ASSETS_DIR
  sed "s|__VAULT_IP__|${LAN}.50|" "$REPO_DIR/vault/vault.hcl.template" > /tmp/.vh.$$
  pct push 200 /tmp/.vh.$$ /etc/vault.d/vault.hcl; rm -f /tmp/.vh.$$
  pct push 200 "$REPO_DIR/vault/bootstrap-vault.sh" /root/bootstrap-vault.sh
  pct exec 200 -- bash -c "chmod 755 /root/bootstrap-vault.sh; systemctl enable --now vault; command -v jq >/dev/null || apt-get install -y jq >/dev/null"
  if [ "$VAULT_KEYS" = file ]; then
      # Decyzja Miko 2026-11-23: init automatyczny, komplet kluczy + root token do pliku 0600,
      # operator ZABIERA plik poza serwer (handover). split = ceremonia ręczna (ramka niżej).
      log "VAULT: init + unseal + bootstrap-vault (klucze → /root/barvea-vault-keys.json w LXC 200)"
      pct exec 200 -- bash -c "export VAULT_ADDR=https://${LAN}.50:8200 VAULT_SKIP_VERIFY=1
        for i in \$(seq 1 30); do vault status >/dev/null 2>&1 && break; vault status 2>/dev/null | grep -q Sealed && break; sleep 2; done
        if vault status -format=json 2>/dev/null | jq -e '.initialized==false' >/dev/null; then
            umask 077; vault operator init -key-shares=5 -key-threshold=3 -format=json > /root/barvea-vault-keys.json
        fi
        [ -s /root/barvea-vault-keys.json ] || { echo 'brak /root/barvea-vault-keys.json (Vault już zainicjowany bez pliku?)'; exit 1; }
        for i in 0 1 2; do vault operator unseal \$(jq -r \".unseal_keys_b64[\$i]\" /root/barvea-vault-keys.json) >/dev/null; done
        export VAULT_TOKEN=\$(jq -r .root_token /root/barvea-vault-keys.json)
        cd /root && OUT_DIR=/root/vault-out GEN_APPROLE_CREDS=1 /root/bootstrap-vault.sh >/root/bootstrap-vault.log 2>&1 || { tail -20 /root/bootstrap-vault.log; exit 1; }
        # cert wewnętrzny dla appki (SAN: app + admin host) z pki_int → /root/vault-out/internal.{crt,key}
        vault write -format=json pki_int/issue/internal-server common_name=$APP_HOST alt_names=$ADMIN_HOST ip_sans=${LAN}.30 ttl=8760h > /root/vault-out/internal.json
        python3 - <<'PYEOF'
import json, os
d = '/root/vault-out'; j = json.load(open(d + '/internal.json'))['data']
open(d + '/internal.crt', 'w').write(j['certificate'] + '\\n' + '\\n'.join(j.get('ca_chain', [])) + '\\n')
open(d + '/internal.key', 'w').write(j['private_key'] + '\\n'); os.chmod(d + '/internal.key', 0o600); os.remove(d + '/internal.json')
PYEOF
        unset VAULT_TOKEN"
      # artefakty: root-ca → LXC 201 + VM 102; internal cert → VM 102 /etc/ssl/barvea; approle creds → creds
      local VO=/tmp/.vo.$$; mkdir -p "$VO"
      # katalogi docelowe istnieją ZANIM svc_storage/svc_app (kolejność faz: vault przed storage/app)
      pct exec 201 -- mkdir -p /etc/barvea /etc/vault 2>/dev/null || true
      vm_ssh "${LAN}.30" "mkdir -p /etc/ssl/barvea"
      for f in root-ca.crt internal.crt internal.key barvea-app.role_id barvea-app.secret_id barvea-storage.role_id barvea-storage.secret_id; do
          pct pull 200 "/root/vault-out/$f" "$VO/$f" 2>/dev/null || true
      done
      pct push 201 "$VO/root-ca.crt" /etc/barvea/root-ca.crt 2>/dev/null || true
      for f in root-ca.crt internal.crt internal.key; do vm_put "${LAN}.30" "$VO/$f" "/etc/ssl/barvea/$f"; done
      vm_ssh "${LAN}.30" "chmod 644 /etc/ssl/barvea/*.crt; chmod 600 /etc/ssl/barvea/internal.key"
      cred "VAULT_APPROLE_ROLE_ID=$(cat "$VO/barvea-app.role_id" 2>/dev/null) VAULT_APPROLE_SECRET_ID=$(cat "$VO/barvea-app.secret_id" 2>/dev/null)"
      cred "STORAGE_APPROLE_ROLE_ID=$(cat "$VO/barvea-storage.role_id" 2>/dev/null) (secret_id TYLKO w /etc/vault/storage-approle na hoście)"
      # AppRole storage: HOST (zfs-load-org.sh: VAULT_ROLE_ID/VAULT_SECRET_ID) + kopia do LXC 201 (/etc/vault)
      mkdir -p /etc/vault /etc/barvea
      printf 'VAULT_ROLE_ID=%s\nVAULT_SECRET_ID=%s\n' "$(cat "$VO/barvea-storage.role_id" 2>/dev/null)" "$(cat "$VO/barvea-storage.secret_id" 2>/dev/null)" > /etc/vault/storage-approle && chmod 600 /etc/vault/storage-approle
      # (przegląd 2026-11-24) AppRole z transit/decrypt per-org-keys ZOSTAJE TYLKO na hoście (zfs-load-org.sh);
      # LXC 201 go nie dostaje — gdyby datad/org-provision potrzebował Vaulta, osobna rola bez decrypt.
      # zfs-load-org.sh: pula orgów + adres Vaulta z konfiguracji (nie hardcode hddpool/10.10.0.50)
      printf 'ORGS_DS=%s/orgs\nVADDR=https://%s.50:8200\n' "$ORGS_POOL" "$LAN" > /etc/barvea/zfs-load-org.conf
      pct exec 200 -- rm -f /root/vault-out/barvea-app.secret_id /root/vault-out/barvea-storage.secret_id
      rm -rf "$VO"
      echo "  ✓ Vault zainicjowany; KLUCZE: /root/barvea-vault-keys.json w LXC 200 (pct pull 200 /root/barvea-vault-keys.json …) — ZABIERZ poza serwer i USUŃ."
      return
  fi
  cat <<CEREMONY

  ┌────────────────────────────────────────────────────────────────┐
  │ VAULT — CEREMONIA RĘCZNA (jedyny interaktywny krok):           │
  │   pct enter 200                                                │
  │   export VAULT_ADDR=https://${LAN}.50:8200 VAULT_SKIP_VERIFY=1 │
  │   vault operator init          # ZAPISZ 5 kluczy + root token! │
  │   vault operator unseal ×3                                     │
  │   export VAULT_TOKEN=<root> && /root/bootstrap-vault.sh        │
  │ (opcja „podział kluczy" dla klienta: rozdaj udziały wg umowy)  │
  └────────────────────────────────────────────────────────────────┘
CEREMONY
}

svc_storage() { # LXC 201 — Samba + datad + smb-provisiond + acl-sync
  pct exec 201 -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y samba python3 acl attr jq >/dev/null
    mkdir -p /srv/orgs /etc/samba/per-org /etc/barvea /var/lib/barvea-smb /var/lib/barvea-acl
    echo '${LAN}.30 app.barvea.internal' >> /etc/hosts
    echo '${LAN}.40 barvea-storage'      >> /etc/hosts"
  pct push 201 "$REPO_DIR/storage/samba/smb.conf.global.template" /etc/samba/smb.conf
  pct push 201 "$REPO_DIR/storage/samba/barvea-veto.conf" /etc/samba/barvea-veto.conf   # include z [global]
  # ClamAV: jeden clamd dla INSTREAM (uploady web) i SCAN (pliki z udziału) —
  # musi widzieć /srv/orgs, dlatego tu, nie na VM 102. Root (pliki 0600).
  pct exec 201 -- bash -c "apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y clamav-daemon clamav-freshclam >/dev/null; systemctl stop clamav-daemon"
  pct push 201 "$REPO_DIR/storage/clamav/clamd.conf" /etc/clamav/clamd.conf
  # TCP 3310 przez override socketu — przy aktywacji socketu clamd ignoruje TCPSocket z conf
  pct exec 201 -- mkdir -p /etc/systemd/system/clamav-daemon.socket.d
  pct push 201 "$REPO_DIR/storage/clamav/clamav-daemon.socket-tcp.conf" /etc/systemd/system/clamav-daemon.socket.d/tcp.conf
  # watchdog (2026-11-24): socket TCP po reboocie potrafi nie wstac → co 5 min test portu + restart
  pct push 201 "$REPO_DIR/storage/clamav/clamd-watchdog.service" /etc/systemd/system/clamd-watchdog.service
  pct push 201 "$REPO_DIR/storage/clamav/clamd-watchdog.timer"   /etc/systemd/system/clamd-watchdog.timer
  pct exec 201 -- bash -c "systemctl daemon-reload; systemctl enable --now clamav-freshclam clamd-watchdog.timer; freshclam --quiet || true; systemctl enable --now clamav-daemon.socket clamav-daemon"
  for f in barvea-datad.py smb-provisiond.py barvea-acl-sync.py; do
      pct push 201 "$REPO_DIR/storage/$f" "/usr/local/sbin/$f"
      pct exec 201 -- chmod 755 "/usr/local/sbin/$f"
  done
  pct push 201 "$REPO_DIR/storage/barvea-datad.service"      /etc/systemd/system/barvea-datad.service
  pct push 201 "$REPO_DIR/storage/smb-provisiond.service"    /etc/systemd/system/smb-provisiond.service
  # v2 (S1 2026-11): rekoncyliacja kont SMB per org z manifestami ACL — raz dziennie
  pct push 201 "$REPO_DIR/storage/systemd/smb-reconcile.service" /etc/systemd/system/smb-reconcile.service
  pct push 201 "$REPO_DIR/storage/systemd/smb-reconcile.timer"   /etc/systemd/system/smb-reconcile.timer
  pct push 201 "$REPO_DIR/storage/systemd/barvea-acl-sync.service" /etc/systemd/system/barvea-acl-sync.service
  pct push 201 "$REPO_DIR/storage/systemd/barvea-acl-sync.timer"   /etc/systemd/system/barvea-acl-sync.timer
  local DT ST AT; DT=$(gen); ST=$(gen); AT=$(gen)
  cred "DRIVE_DATA_TOKEN=$DT"; cred "SMB_PROVISIOND_TOKEN=$ST"; cred "DRIVE_ACL_SERVICE_TOKEN=$AT"
  pct exec 201 -- bash -c "
    printf 'TOKEN=$DT\nBIND=${LAN}.40\nPORT=8723\nSIGN_KEY=%s\n' \"\$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64)\" > /etc/barvea/barvea-datad.env
    printf 'TOKEN=$ST\nBIND=${LAN}.40\nPORT=8722\nUID_START=5100\nLEGACY_ACCOUNTS=0\nRECONCILE_DELETE_DAYS=30\n' > /etc/barvea/smb-provisiond.env
    printf 'DRIVE_ACL_SERVICE_TOKEN=$AT\nORG_SLUGS=\nAPP_URL=https://app.barvea.internal\nCA_FILE=/etc/barvea/root-ca.crt\n' > /etc/barvea/acl-sync.env
    chmod 600 /etc/barvea/*.env
    systemctl daemon-reload
    systemctl enable --now smbd barvea-datad smb-provisiond barvea-acl-sync.timer smb-reconcile.timer"
  echo "ℹ️  root-ca.crt do /etc/barvea/ w LXC 201 — po ceremonii Vaulta (z bootstrap-vault OUT_DIR)."
  echo "ℹ️  Nowy org: przepis proxmox/zfs-layout.md + storage/samba/per-org.conf.template."
}

svc_app() {    # VM 102 — docker + szkielet; DEPLOY APLIKACJI = bundle/deploy.sh (poza bootstrapem)
  local ip="${LAN}.30"
  vm_ssh "$ip" "command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null; }"  # TODO air-gap: docker .deb-y z ASSETS_DIR
  # Śluza uploadu na dysku scsi1 (patrz phase_guests). Bez tablicy partycji —
  # ext4 wprost na urządzeniu, więc powiększenie to `qm disk resize 102 scsi1
  # +NG` + `resize2fs /dev/sdb`, bez growpart. `-m 0` zdejmuje 5% rezerwy
  # roota (na 1 TB to 50 GB), `-T largefile4` = 1 i-węzeł na 4 MB (trzymamy
  # kilkanaście wielkich .part, nie miliony małych plików).
  vm_ssh "$ip" "if [ -b /dev/sdb ]; then
      findmnt -rn /srv/upload-tmp >/dev/null || {
        blkid -L upload-tmp >/dev/null 2>&1 || mkfs.ext4 -q -m 0 -L upload-tmp -T largefile4 /dev/sdb
        mkdir -p /srv/upload-tmp
        grep -q '^LABEL=upload-tmp ' /etc/fstab || echo 'LABEL=upload-tmp /srv/upload-tmp ext4 defaults,noatime,nofail 0 2' >> /etc/fstab
        systemctl daemon-reload; mount -a; }
      # uid/gid 1001 = barvea:nodejs z obrazu app. Bind-mount NIE dziedziczy
      # właściciela z obrazu (robi to tylko pusty named volume) — bez chown
      # każdy init uploadu pada na EACCES.
      chown 1001:1001 /srv/upload-tmp
      # scratch sidecarów na dysku śluzy (uid 57439 = wspólny uid sidecarów):
      # pcp (chmury punktów), ifc-clash (kolizje), ifc-extractor (zestawienia IFC).
      # Bind-mount nie dziedziczy uid z obrazu.
      install -d -o 57439 -g 57439 /srv/upload-tmp/pcp-scratch /srv/upload-tmp/clash-scratch /srv/upload-tmp/ifc-extractor-scratch
    else echo '⚠️  brak /dev/sdb — śluza uploadu NIE utworzona (dysk scsi1?)'; fi"
  vm_ssh "$ip" "mkdir -p /home/$CI_USER/barvea && chown $CI_USER: /home/$CI_USER/barvea"
  # journald trwały (logi kontenera app przez driver journald przeżywają recreate): 2 GB, 60 dni
  vm_ssh "$ip" "mkdir -p /var/log/journal /etc/systemd/journald.conf.d; printf '[Journal]
Storage=persistent
SystemMaxUse=2G
MaxRetentionSec=60day
' > /etc/systemd/journald.conf.d/barvea.conf; systemctl restart systemd-journald"
  # Sprzatanie docker build cache (rosnie ~37 GB na deploy; bez timera root 75 G
  # zapelnia sie po 2 deployach — prod 2026-08-31).
  vm_put "$ip" "$REPO_DIR/vm102/systemd/docker-prune.service" /etc/systemd/system/docker-prune.service
  vm_put "$ip" "$REPO_DIR/vm102/systemd/docker-prune.timer"   /etc/systemd/system/docker-prune.timer
  vm_ssh "$ip" "systemctl daemon-reload && systemctl enable --now docker-prune.timer"
  # Caddyfile: dedyk/staging = szablon bez Cloudflare (hosty *.barvea.internal, internal-CA,
  # admin host); saas = prod Caddyfile 1:1. Cert internal.{crt,key} wystawia svc_vault (pki_int).
  if [ "$DEPLOYMENT_MODE" = dedicated ] || [ "$PRESET" = staging ]; then
      sed -e "s|__APP_HOST__|$APP_HOST|g" -e "s|__ADMIN_HOST__|$ADMIN_HOST|g" \
          -e "s|__STORAGE_IP__|${LAN}.40|g" \
          -e "s|__MTLS_PROOF_LINE__|header_up X-Barvea-Mtls-Proof {env.MTLS_PROXY_SECRET}|" \
          "$REPO_DIR/Caddyfile.dedicated.template" > /tmp/.caddy.$$
      vm_put "$ip" /tmp/.caddy.$$ "/home/$CI_USER/barvea/Caddyfile"; rm -f /tmp/.caddy.$$
  else
      vm_put "$ip" "$REPO_DIR/Caddyfile" "/home/$CI_USER/barvea/Caddyfile"
  fi
  vm_ssh "$ip" "mkdir -p /etc/ssl/barvea && chmod 755 /etc/ssl/barvea"
  # Compose ≥ 2.20 (depends_on required:false w compose dedyka APP)
  vm_ssh "$ip" "v=\$(docker compose version --short 2>/dev/null || echo 0); printf '%s\n' \"\$v\" 2.20 | sort -V | head -1 | grep -qx 2.20 || echo '⚠️  docker compose < 2.20 (jest '\$v') — compose dedyka wymaga 2.20+'"
  vm_put "$ip" "$REPO_DIR/docker-compose.yml" "/home/$CI_USER/barvea/docker-compose.yml"
  echo "ℹ️  APLIKACJA: wgraj release-bundle (albo git clone app) + .env.production"
  echo "   (DATABASE_URL z creds: barvea_app@${LAN}.20/barvea) → scripts/deploy.sh. Poza bootstrapem."
}

phase_services() {
  if [ "$PRESET" = compact ]; then   # 1-VM: tylko app (reszta = kontenery bundla)
      log "USŁUGI: compact (1-VM) — tylko app; DB/redis/minio z bundla dedyk"
      done_f svc_app || { svc_app; mark svc_app; }
      mark services; return
  fi
  log "USŁUGI: VM 100 (WG hub)";     done_f svc_infra   || { svc_infra;   mark svc_infra; }
  log "USŁUGI: VM 101 (Postgres)";   done_f svc_data    || { svc_data;    mark svc_data; }
  log "USŁUGI: LXC 200 (Vault)";     done_f svc_vault   || { svc_vault;   mark svc_vault; }
  log "USŁUGI: LXC 201 (Storage)";   done_f svc_storage || { svc_storage; mark svc_storage; }
  log "USŁUGI: VM 102 (App/edge)";   done_f svc_app     || { svc_app;     mark svc_app; }
  mark services
}

# ═══ FAZA: verify ═══════════════════════════════════════════════════
phase_verify() {
  log "VERIFY"
  pct list; qm list
  for p in "${LAN}.50:8200 Vault" "${LAN}.40:445 Samba" "${LAN}.40:8723 datad" \
           "${LAN}.40:8722 smb-prov" "${LAN}.40:3310 clamd" "${LAN}.20:5432 Postgres" \
           "${LAN}.20:6379 Redis" "${LAN}.20:9000 MinIO" "${LAN}.10:8721 wg-prov"; do
      # shellcheck disable=SC2086
      set -- ${p/:/ }; local hostport="$1" name="${2:-}"
      timeout 3 bash -c "echo > /dev/tcp/${hostport/:/\/}" 2>/dev/null \
          && echo "  ✓ $p" || echo "  ✗ $p (sprawdź — Vault sealed? app niewdrożona?)"
  done
  # DNS tunelu: dnsmasq na hubie odpowiada tylko na wg-users — test z hosta przez VM 100
  vm_ssh "${LAN}.10" "getent hosts $APP_HOST >/dev/null 2>&1 || dig +short @${WG_USERS_ADDR%/*} $APP_HOST 2>/dev/null | grep -q . && echo '  ✓ dnsmasq: $APP_HOST' || echo '  ✗ dnsmasq: $APP_HOST (sprawdź /etc/dnsmasq.d/wg-users.conf)'" || true
  if [ "$BACKUP_TARGET" != skip ] && [ -n "$BACKUP_SFTP" ] && [ "$PRESET" != compact ]; then
      log "BACKUP: backup-enable.sh → $BACKUP_SFTP (interaktywnie: klucze do authorized_keys celu)"
      "$REPO_DIR/backup-enable.sh" "$BACKUP_SFTP" || echo "⚠️ backup-enable.sh nieudany — powtórz ręcznie: ./backup-enable.sh $BACKUP_SFTP"
  fi
  cat <<NEXT

  ═══ BOOTSTRAP KONIEC — kroki ręczne (kolejność!): ═══
  1. Vault: $([ "$VAULT_KEYS" = file ] && echo "ZROBIONE automatycznie — ZABIERZ /root/barvea-vault-keys.json z LXC 200 poza serwer i usuń go tam" || echo "ceremonia ręczna (ramka wyżej) → bootstrap-vault.sh → root-ca.crt na LXC 201 + internal cert na 102")
  2. App: bundle/git + .env.production (creds: $CREDS) → deploy.sh
  3. Backup off-site: $([ "$BACKUP_TARGET" = skip ] && echo "POMINIĘTY w kreatorze → ./backup-enable.sh user@host:/sciezka (kiedykolwiek, bez reinstalacji)" || echo "włączony przez backup-enable.sh (patrz wyżej) — sprawdź restic snapshots")
  4. Pierwszy org: proxmox/zfs-layout.md (dataset+.ct+mpN+share+ORG_SLUGS)
  5. WG peery: enroll przez APP (wg-provisiond) / admin wg0 ręcznie
  Creds wygenerowane: $CREDS (0600) — przenieś do managera haseł i USUŃ.
NEXT
  mark verify
}

# ═══ main ═══════════════════════════════════════════════════════════
main() {
  local only="${1:-}"
  mkdir -p "$STATE"
  for ph in preflight host guests services verify; do
      [ -n "$only" ] && [ "$only" != "$ph" ] && continue
      if [ -z "$only" ] && done_f "$ph"; then log "SKIP $ph (zrobione)"; continue; fi
      "phase_$ph"
  done
  log "DONE"
}
main "$@"
