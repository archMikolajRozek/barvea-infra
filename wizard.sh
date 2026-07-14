#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — wizard.sh: kreator (whiptail) faza 0 installera. Zbiera
# odpowiedzi → pisze bootstrap.conf. Druga instalacja = zero pytań
# (bootstrap.conf już jest). Po nim: ./bootstrap.sh
#
# ⚠️ NIETESTOWANY (napisany 2026-07-14 offline, wzorzec z bootstrap.sh
#    który przeszedł staging). Pierwszy run: staging VM 999 (migawka
#    czysty-bootstrap → można kręcić bez ryzyka).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
CONF="${1:-./bootstrap.conf}"
command -v whiptail >/dev/null || { apt-get update -qq && apt-get install -y whiptail; }

TITLE="BARVEA installer"
msg()  { whiptail --title "$TITLE" --msgbox "$1" "${2:-12}" 72; }
yesno(){ whiptail --title "$TITLE" --yesno "$1" "${2:-12}" 72; }
input(){ whiptail --title "$TITLE" --inputbox "$1" 10 72 "$2" 3>&1 1>&2 2>&3; }

whiptail --title "$TITLE" --msgbox \
"Kreator konfiguracji BARVEA.\n\nZbierze parametry i zapisze do:\n  $CONF\n\nPotem: ./bootstrap.sh postawi cały stack.\nUruchamiaj na ŚWIEŻYM Proxmox-hoście (root)." 14 72

[ "$(id -u)" = 0 ] || { echo "root wymagany"; exit 1; }
command -v pveversion >/dev/null || yesno "To nie wygląda na Proxmox (brak pveversion). Kontynuować mimo to?" || exit 1

# ── 1. Tryb wdrożenia ───────────────────────────────────────────────
MODE=$(whiptail --title "$TITLE" --menu "Tryb wdrożenia:" 15 72 3 \
  "dedicated" "on-prem u klienta (single-org, licencja, bez landing/billing)" \
  "saas"      "nasz multi-tenant (jak prod)" \
  "staging"   "test (mali goście, izolowane podsieci)" 3>&1 1>&2 2>&3)
PRESET=prod; DEPLOYMENT_MODE=saas
case "$MODE" in
  dedicated) DEPLOYMENT_MODE=dedicated
             TOPO=$(whiptail --title "$TITLE" --menu "Topologia dedyk:" 13 72 2 \
               "full"    "5 gości (jak prod) — pełna izolacja" \
               "compact" "1 VM (compose all-in-one) — mały klient" 3>&1 1>&2 2>&3)
             [ "$TOPO" = compact ] && PRESET=compact ;;
  staging)   PRESET=staging; DEPLOYMENT_MODE=saas ;;
esac

# ── 2. Pool ZFS ─────────────────────────────────────────────────────
mapfile -t FREE < <(lsblk -dnp -o NAME,SIZE,TYPE | awk '$3=="disk"{print $1" ("$2")"}')
DISKLIST=""; for d in "${FREE[@]}"; do DISKLIST+="$d {off} "; done
if [ -n "$DISKLIST" ]; then
  # shellcheck disable=SC2086
  SEL=$(whiptail --title "$TITLE" --checklist \
    "Dyski do pool ZFS (SPACJA zaznacza; system-dysk NIE zaznaczaj!):" \
    18 72 8 $DISKLIST 3>&1 1>&2 2>&3 || true)
  POOL_DISKS=$(echo "$SEL" | tr -d '"' | sed 's/([^)]*)//g' | tr -s ' ')
else POOL_DISKS=""; fi
NDISK=$(echo "$POOL_DISKS" | wc -w)
POOL_RAID=mirror
if [ "$NDISK" -ge 4 ]; then
  POOL_RAID=$(whiptail --title "$TITLE" --menu "RAID ($NDISK dysków):" 13 72 3 \
    "raidz2" "2 dyski redundancji (zalecane 4+)" \
    "raidz1" "1 dysk redundancji" \
    "mirror" "lustro par" 3>&1 1>&2 2>&3)
fi
[ -z "$POOL_DISKS" ] && ! yesno "NIE wybrano dysków — pool już istnieje na tym hoście?\n(Tak = użyj istniejącego. Nie = przerwij.)" && exit 1

# ── 3. Sieć LAN + kolizje ───────────────────────────────────────────
LAN=$(input "Prefix LAN /24 (goście dostaną .10/.20/.30/.40/.50):" "10.10.0")
while ip route 2>/dev/null | grep -qw "${LAN}.0/24"; do
  yesno "⚠️ ${LAN}.0/24 JUŻ w tablicy routingu (kolizja z siecią hosta/klienta!).\nWybrać inny?" \
    && LAN=$(input "Inny prefix LAN /24:" "10.30.0") || { FORCE_NETS=1; break; }
done
SSH_PORT=$(input "Port SSH (fail2ban):" "2277")

# ── 4. WG podsieci (dedyk: sieć klienta może gryźć nasze!) ──────────
WG_USERS_CIDR=$(input "WireGuard USERS (devices/Drive) CIDR:" "10.67.0.0/16")
WG_USERS_ADDR="${WG_USERS_CIDR%.*.*/*}.0.1/${WG_USERS_CIDR#*/}"
WG_USERS_PORT=$(input "Port WG users (UDP):" "51821")
WG0_CIDR=$(input "WireGuard ADMIN CIDR:" "10.9.0.0/24")
WG0_ADDR="${WG0_CIDR%.*/*}.1/${WG0_CIDR#*/}"
WG0_PORT=$(input "Port WG admin (UDP):" "51820")

# ── 5. TLS / dostęp ─────────────────────────────────────────────────
if yesme=$(yesno "Instancja ma dostęp do internetu?\n(Nie = air-gap: TLS z własnego CA, updaty z nośnika)"; echo $?); [ "$yesme" = 0 ]; then
  AIRGAP=0; FQDN=$(input "Publiczny FQDN (Let's Encrypt), pusto=LAN-only:" "")
else
  AIRGAP=1; FQDN=""
  msg "Air-gap: TLS wyłącznie z internal-CA (Vault pki_int), zero Let's Encrypt.\nUpdaty aplikacji = podpisany bundle z nośnika."
fi
ASSETS_DIR=""
[ "$AIRGAP" = 1 ] && ASSETS_DIR=$(input "Katalog z artefaktami offline (template/qcow2/.deb/bundle):" "/root/barvea-assets")

# ── 6. Backup ───────────────────────────────────────────────────────
BACKUP=$(whiptail --title "$TITLE" --menu "Backup off-site:" 14 72 3 \
  "storagebox" "Hetzner Storage Box (SFTP) — jak prod" \
  "custom-sftp" "SFTP klienta (poda ścieżkę później)" \
  "none"        "BRAK (⚠️ tylko snapshoty lokalne!)" 3>&1 1>&2 2>&3)

# ── 7. Licencja (dedicated) ─────────────────────────────────────────
LICENSE_FILE=""
[ "$DEPLOYMENT_MODE" = dedicated ] && \
  LICENSE_FILE=$(input "Ścieżka pliku licencji BARVEA-LICENSE.v1... (pusto=wgrasz potem w panelu):" "")

# ── podsumowanie + zapis ────────────────────────────────────────────
SUMMARY="Tryb:        $MODE (DEPLOYMENT_MODE=$DEPLOYMENT_MODE, preset=$PRESET)
Pool:        ${POOL_DISKS:-<istniejący>} [$POOL_RAID]
LAN:         ${LAN}.0/24   SSH:$SSH_PORT
WG users:    $WG_USERS_CIDR :$WG_USERS_PORT
WG admin:    $WG0_CIDR :$WG0_PORT
TLS:         $([ "$AIRGAP" = 1 ] && echo 'air-gap internal-CA' || echo "${FQDN:-LAN-only internal-CA}")
Backup:      $BACKUP
Licencja:    ${LICENSE_FILE:-<panel>}"
yesno "Zapisać konfigurację?\n\n$SUMMARY" 20 || { echo "Anulowano."; exit 1; }

{
  echo "# BARVEA bootstrap.conf — wygenerowany przez wizard.sh $(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8)"
  echo "PRESET=$PRESET"
  echo "DEPLOYMENT_MODE=$DEPLOYMENT_MODE"
  [ -n "$POOL_DISKS" ] && echo "POOL_DISKS=\"$POOL_DISKS\""
  echo "POOL_RAID=$POOL_RAID"
  echo "LAN=$LAN"
  echo "SSH_PORT=$SSH_PORT"
  echo "WG_USERS_CIDR=$WG_USERS_CIDR"
  echo "WG_USERS_ADDR=$WG_USERS_ADDR"
  echo "WG_USERS_PORT=$WG_USERS_PORT"
  echo "WG0_CIDR=$WG0_CIDR"
  echo "WG0_ADDR=$WG0_ADDR"
  echo "WG0_PORT=$WG0_PORT"
  echo "AIRGAP=$AIRGAP"
  [ -n "$ASSETS_DIR" ] && echo "ASSETS_DIR=$ASSETS_DIR"
  [ -n "$FQDN" ] && echo "PUBLIC_FQDN=$FQDN"
  echo "BACKUP_TARGET=$BACKUP"
  [ -n "$LICENSE_FILE" ] && echo "LICENSE_FILE=$LICENSE_FILE"
  [ "${FORCE_NETS:-0}" = 1 ] && echo "FORCE_NETS=1"
} > "$CONF"
chmod 600 "$CONF"

msg "Zapisano $CONF.\n\nDalej:\n  ./bootstrap.sh\n\n(Vault: ceremonia init/unseal ręczna — bootstrap wypisze instrukcję.\n Po deployu apki: ./deploy-app.dedicated.sh)" 15
