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
LXC_TEMPLATE="${LXC_TEMPLATE:-debian-13-standard}"   # pveam nazwa-prefix
CLOUD_IMG_URL="${CLOUD_IMG_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
CI_USER="${CI_USER:-miko}"
STATE=/var/lib/barvea-bootstrap
CREDS=/root/barvea-bootstrap-creds.txt
KEY=/root/.ssh/barvea-bootstrap           # klucz do VM-ek (cloud-init)

# guest defs: id name ip cores mem(MB) balloon disk rola
if [ "$PRESET" = staging ]; then    # małe goście — test/staging (VM-w-VM,
  # suma RAM ~10G → mieści się w 12G nested-hoście z zapasem na PVE)
  GUESTS_LXC=( "200 vault    ${LAN}.50 1 1024 - 6  vault"
               "201 storage  ${LAN}.40 2 2048 - 10 storage" )
  GUESTS_VM=(  "100 barvea-infra ${LAN}.10 1 1024 -    20 infra 1"
               "101 barvea-data  ${LAN}.20 2 3072 -    40 data  2"
               "102 barvea-app   ${LAN}.30 2 3072 -    30 app   3" )
else
  GUESTS_LXC=( "200 vault    ${LAN}.50 2 2048 - 8  vault"
               "201 storage  ${LAN}.40 4 8192 - 16 storage" )
  GUESTS_VM=(  "100 barvea-infra ${LAN}.10 2 4096  -    50  infra 1"
               "101 barvea-data  ${LAN}.20 4 24576 8192 200 data  2"
               "102 barvea-app   ${LAN}.30 4 8192  4096 80  app   3" )
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
vm_put(){ local ip="$1" src="$2" dst="$3"; scp -o StrictHostKeyChecking=accept-new -i "$KEY" "$src" "$CI_USER@$ip:/tmp/.bp.$$"; vm_ssh "$ip" "mv /tmp/.bp.$$ $dst"; }
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
           wg-control/wg-provisiond.py backup/barvea-host-backup.sh; do
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
  zfs list "$POOL_NAME/orgs" >/dev/null 2>&1 || zfs create "$POOL_NAME/orgs"
  zfs set compression=zstd "$POOL_NAME/orgs"
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
      pct exec "$id" -- bash -c "echo '$ip $name' >> /etc/hosts; apt-get update -qq"
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
  for def in "${GUESTS_VM[@]}"; do set -- $def; wait_ssh "$3"; done
  mark guests
}

# ═══ FAZA: usługi per węzeł ═════════════════════════════════════════
svc_infra() {  # VM 100 — WG hub + wg-provisiond
  local ip="${LAN}.10"
  # nftables: PostUp wg0 (tabela wg_nat) — cloud-image go NIE ma (run3 staging)
  vm_ssh "$ip" "DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables nftables python3 >/dev/null
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
  vm_put "$ip" "$REPO_DIR/wg-control/wg-provisiond.py" /usr/local/sbin/wg-provisiond.py
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
    mkdir -p \$PGC/conf.d
    printf \"listen_addresses = \\047localhost,$ip\\047\\n\" > \$PGC/conf.d/barvea.conf
    systemctl restart postgresql@18-main
    sudo -u postgres psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='barvea_app'\" | grep -q 1 || \
        sudo -u postgres psql -c \"CREATE ROLE barvea_app LOGIN PASSWORD '$PGA'\"
    sudo -u postgres psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='barvea_admin'\" | grep -q 1 || \
        sudo -u postgres psql -c \"CREATE ROLE barvea_admin LOGIN SUPERUSER PASSWORD '$PGD'\"
    sudo -u postgres psql -tc \"SELECT 1 FROM pg_database WHERE datname='barvea'\" | grep -q 1 || \
        sudo -u postgres createdb -O barvea_app barvea"
  # TODO tuning (świadomie stock jak prod): shared_buffers itd. — osobna decyzja
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
  pct exec 200 -- bash -c "chmod 755 /root/bootstrap-vault.sh; systemctl enable --now vault"
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
  for f in barvea-datad.py smb-provisiond.py barvea-acl-sync.py; do
      pct push 201 "$REPO_DIR/storage/$f" "/usr/local/sbin/$f"
      pct exec 201 -- chmod 755 "/usr/local/sbin/$f"
  done
  pct push 201 "$REPO_DIR/storage/barvea-datad.service"      /etc/systemd/system/barvea-datad.service
  pct push 201 "$REPO_DIR/storage/smb-provisiond.service"    /etc/systemd/system/smb-provisiond.service
  pct push 201 "$REPO_DIR/storage/systemd/barvea-acl-sync.service" /etc/systemd/system/barvea-acl-sync.service
  pct push 201 "$REPO_DIR/storage/systemd/barvea-acl-sync.timer"   /etc/systemd/system/barvea-acl-sync.timer
  local DT ST AT; DT=$(gen); ST=$(gen); AT=$(gen)
  cred "DRIVE_DATA_TOKEN=$DT"; cred "SMB_PROVISIOND_TOKEN=$ST"; cred "DRIVE_ACL_SERVICE_TOKEN=$AT"
  pct exec 201 -- bash -c "
    printf 'TOKEN=$DT\nBIND=${LAN}.40\nPORT=8723\nSIGN_KEY=%s\n' \"\$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64)\" > /etc/barvea/barvea-datad.env
    printf 'TOKEN=$ST\nBIND=${LAN}.40\nPORT=8722\nUID_START=5100\n' > /etc/barvea/smb-provisiond.env
    printf 'DRIVE_ACL_SERVICE_TOKEN=$AT\nORG_SLUGS=\nAPP_URL=https://app.barvea.internal\nCA_FILE=/etc/barvea/root-ca.crt\n' > /etc/barvea/acl-sync.env
    chmod 600 /etc/barvea/*.env
    systemctl daemon-reload
    systemctl enable --now smbd barvea-datad smb-provisiond barvea-acl-sync.timer"
  echo "ℹ️  root-ca.crt do /etc/barvea/ w LXC 201 — po ceremonii Vaulta (z bootstrap-vault OUT_DIR)."
  echo "ℹ️  Nowy org: przepis proxmox/zfs-layout.md + storage/samba/per-org.conf.template."
}

svc_app() {    # VM 102 — docker + szkielet; DEPLOY APLIKACJI = bundle/deploy.sh (poza bootstrapem)
  local ip="${LAN}.30"
  vm_ssh "$ip" "command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null; }"  # TODO air-gap: docker .deb-y z ASSETS_DIR
  vm_ssh "$ip" "mkdir -p /home/$CI_USER/barvea && chown $CI_USER: /home/$CI_USER/barvea"
  vm_put "$ip" "$REPO_DIR/Caddyfile" "/home/$CI_USER/barvea/Caddyfile"
  vm_put "$ip" "$REPO_DIR/docker-compose.yml" "/home/$CI_USER/barvea/docker-compose.yml"
  echo "ℹ️  APLIKACJA: wgraj release-bundle (albo git clone app) + .env.production"
  echo "   (DATABASE_URL z creds: barvea_app@${LAN}.20/barvea) → scripts/deploy.sh. Poza bootstrapem."
}

phase_services() {
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
           "${LAN}.40:8722 smb-prov" "${LAN}.20:5432 Postgres"; do
      # shellcheck disable=SC2086
      set -- ${p/:/ }; local hostport="$1" name="${2:-}"
      timeout 3 bash -c "echo > /dev/tcp/${hostport/:/\/}" 2>/dev/null \
          && echo "  ✓ $p" || echo "  ✗ $p (sprawdź — Vault sealed? app niewdrożona?)"
  done
  cat <<NEXT

  ═══ BOOTSTRAP KONIEC — kroki ręczne (kolejność!): ═══
  1. Ceremonia Vaulta (ramka wyżej) → bootstrap-vault.sh → root-ca.crt
     → /etc/barvea/root-ca.crt na LXC 201 (+ Caddy internal cert na 102)
  2. App: bundle/git + .env.production (creds: $CREDS) → deploy.sh
  3. Backup off-site: backup/README.md (klucz→Storage Box, hasło repo)
     + install barvea-host-backup.sh + timer
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
