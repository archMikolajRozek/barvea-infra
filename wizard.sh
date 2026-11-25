#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — wizard.sh v2 (2026-11-24): kreator (whiptail) faza 0 installera.
# Zbiera odpowiedzi → pisze bootstrap.conf (+ szkic HANDOVER). Druga
# instalacja = zero pytań (bootstrap.conf już jest). Po nim: ./bootstrap.sh
#
# v2 wg INSTALATOR-PLAN-2026-11.md §D2: dwie pule dysków (fast/bulk), DNS tunelu,
# nazwy hostów *.barvea.internal, backup z opcją „skip” (backup-enable.sh później),
# Vault (komplet kluczy do pliku / podział Shamira), pierwszy admin (hasło
# generuje deploy-app), moduły z licznikiem RAM/CPU, licencja, szkic handover.
#
# ⚠️ Pierwszy run: VM 999 (migawka czysty-bootstrap). Klucze bootstrap.conf
#    starsze (POOL_DISKS/POOL_RAID) są nadal pisane = fast pool (zgodność).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
CONF="${1:-./bootstrap.conf}"
HANDOVER="${HANDOVER:-./HANDOVER-draft.md}"
command -v whiptail >/dev/null || { apt-get update -qq && apt-get install -y whiptail; }

TITLE="BARVEA installer v2"
msg()  { whiptail --title "$TITLE" --msgbox "$1" "${2:-12}" 76; }
yesno(){ whiptail --title "$TITLE" --yesno "$1" "${2:-12}" 76; }
input(){ whiptail --title "$TITLE" --inputbox "$1" 10 76 "$2" 3>&1 1>&2 2>&3; }
menu() { local t="$1"; shift; whiptail --title "$TITLE" --menu "$t" 18 76 8 "$@" 3>&1 1>&2 2>&3; }

whiptail --title "$TITLE" --msgbox \
"Kreator konfiguracji BARVEA (v2).\n\nZbierze parametry i zapisze do:\n  $CONF\noraz szkic listy przekazania:\n  $HANDOVER\n\nPotem: ./bootstrap.sh (infra) → ./deploy-app.dedicated.sh (aplikacja).\nUruchamiaj na ŚWIEŻYM Proxmox-hoście (root)." 16 76

[ "$(id -u)" = 0 ] || { echo "root wymagany"; exit 1; }
command -v pveversion >/dev/null || yesno "To nie wygląda na Proxmox (brak pveversion). Kontynuować mimo to?" || exit 1

HOST_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
HOST_CORES=$(nproc)

# ── 1. Tryb wdrożenia ───────────────────────────────────────────────
MODE=$(menu "Tryb wdrożenia:" \
  "dedicated" "on-prem u klienta (single-org, licencja, bez landing/billing)" \
  "saas"      "nasz multi-tenant (jak prod)" \
  "staging"   "test (mali goście, izolowane podsieci)")
PRESET=prod; DEPLOYMENT_MODE=saas; TOPO=full
case "$MODE" in
  dedicated) DEPLOYMENT_MODE=dedicated
             TOPO=$(menu "Topologia dedyk:" \
               "full"    "5 gości (jak prod) — pełna izolacja, Drive, Vault" \
               "compact" "1 VM (compose all-in-one) — mały klient, BEZ Drive")
             [ "$TOPO" = compact ] && PRESET=compact ;;
  staging)   PRESET=staging ;;
esac

# ── 2. Dyski → DWIE PULE (fast: VM/Postgres/docker/śluza; bulk: dane org) ──
# Jeden nośnik/zestaw = jedna pula (bulk = fast). Wykrywanie SSD/HDD po ROTA.
mapfile -t DISKS < <(lsblk -dnp -o NAME,SIZE,ROTA,TYPE | awk '$4=="disk"{t=($3=="0")?"SSD":"HDD"; print $1"|"$2"|"t}')
pick_disks() {  # $1 tytuł, $2 domyślny typ do zaznaczenia (SSD|HDD|none)
  local list="" d name size typ on
  for d in "${DISKS[@]}"; do
    IFS='|' read -r name size typ <<<"$d"
    on=off; [ "$typ" = "$2" ] && on=on
    list+="$name $size,$typ $on "
  done
  [ -z "$list" ] && { echo ""; return; }
  # shellcheck disable=SC2086
  whiptail --title "$TITLE" --checklist "$1\n(SPACJA zaznacza; dysk systemowy NIE zaznaczaj!)" 20 76 10 $list 3>&1 1>&2 2>&3 | tr -d '"'
}
raid_for() {  # $1 liczba dysków
  if [ "$1" -ge 4 ]; then menu "RAID ($1 dysków):" "raidz2" "2 dyski redundancji (zalecane 4+)" "raidz1" "1 dysk redundancji" "mirror" "lustro par"
  elif [ "$1" -ge 2 ]; then menu "RAID ($1 dyski):" "mirror" "lustro" "raidz1" "1 dysk redundancji (3+)"
  else echo ""; fi
}
FAST_DISKS=$(pick_disks "Pula FAST (SSD/NVMe): system gości, Postgres, docker, śluza uploadu" SSD)
FAST_N=$(echo "$FAST_DISKS" | wc -w); FAST_RAID=$(raid_for "$FAST_N")
if yesno "Osobna pula BULK (HDD) na dane organizacji (/orgs)?\n(Nie = dane org na puli FAST; jeden nośnik = jedna pula)"; then
  BULK_DISKS=$(pick_disks "Pula BULK (HDD): dane organizacji (CDE/Drive)" HDD)
  BULK_N=$(echo "$BULK_DISKS" | wc -w); BULK_RAID=$(raid_for "$BULK_N")
  for d in $FAST_DISKS; do echo " $BULK_DISKS " | grep -q " $d " && { msg "Dysk $d jest w OBU pulach — popraw."; exit 1; }; done
else
  BULK_DISKS=""; BULK_RAID=""
fi
if [ -z "$FAST_DISKS" ]; then
  yesno "NIE wybrano dysków FAST — pula już istnieje na tym hoście?\n(Tak = użyj istniejącej (POOL_NAME). Nie = przerwij.)" || exit 1
fi

# ── 3. Sieć LAN + kolizje ───────────────────────────────────────────
LAN=$(input "Prefix LAN /24 (goście dostaną .10/.20/.30/.40/.50):" "10.10.0")
while ip route 2>/dev/null | grep -qw "${LAN}.0/24"; do
  yesno "⚠️ ${LAN}.0/24 JUŻ w tablicy routingu (kolizja z siecią hosta/klienta!).\nWybrać inny?" \
    && LAN=$(input "Inny prefix LAN /24:" "10.30.0") || { FORCE_NETS=1; break; }
done
SSH_PORT=$(input "Port SSH (fail2ban):" "2277")

# ── 4. WG podsieci + DNS tunelu ─────────────────────────────────────
WG_USERS_CIDR=$(input "WireGuard USERS (urządzenia/Drive) CIDR:" "10.67.0.0/16")
WG_USERS_ADDR="${WG_USERS_CIDR%.*.*/*}.0.1/${WG_USERS_CIDR#*/}"
WG_USERS_PORT=$(input "Port WG users (UDP):" "51821")
WG0_CIDR=$(input "WireGuard ADMIN CIDR:" "10.9.0.0/24")
WG0_ADDR="${WG0_CIDR%.*/*}.1/${WG0_CIDR#*/}"
WG0_PORT=$(input "Port WG admin (UDP):" "51820")
WG_DNS="${WG_USERS_ADDR%/*}"   # dnsmasq na hubie: *.barvea.internal, zawsze

# ── 5. TLS / dostęp / nazwy hostów ──────────────────────────────────
INTERNAL_DOMAIN=barvea.internal      # decyzja Miko 2026-11-23: stała (klienci Drive/plugin = jedna konfiguracja)
APP_HOST="app.$INTERNAL_DOMAIN"; DRIVE_HOST="drive.$INTERNAL_DOMAIN"; ADMIN_HOST="admin.$INTERNAL_DOMAIN"
if yesno "Instancja ma dostęp do internetu?\n(Nie = air-gap: TLS z własnego CA, updaty z nośnika)"; then
  AIRGAP=0; FQDN=$(input "Publiczny FQDN appki (Let's Encrypt), pusto = tylko WG/LAN ($APP_HOST):" "")
else
  AIRGAP=1; FQDN=""
  msg "Air-gap: TLS wyłącznie z internal-CA (Vault pki_int), zero Let's Encrypt.\nUpdaty aplikacji = podpisany bundle z nośnika (MANIFEST.sig)."
fi
ASSETS_DIR=""
[ "$AIRGAP" = 1 ] && ASSETS_DIR=$(input "Katalog z artefaktami offline (template/qcow2/.deb/bundle):" "/root/barvea-assets")
msg "Hosty instancji (tylko przez WireGuard/LAN, DNS tunelu $WG_DNS):\n  $APP_HOST   → aplikacja\n  $DRIVE_HOST → udziały Drive\n  $ADMIN_HOST → panel administratora (osobna sesja, 2FA zawsze)\n$([ -n "$FQDN" ] && echo "Publicznie: https://$FQDN (parowanie, mobile)")" 14

# ── 6. Moduły → profile compose + rozmiar gości ─────────────────────
# Sufity RAM (prod 2026-11): app ~8 G + dwg 3 + office 3 (zawsze); pcp 12; collab 1; ifc-clash 12 + ifc-extractor 4; AV = clamd ~1.5 G na storage (LXC 201).
MOD_DRIVE=0; MOD_AV=0; MOD_COLLAB=0; MOD_POINTCLOUD=0; MOD_IFC=0
if [ "$TOPO" = compact ]; then DRIVE_OPT=("drive" "Drive (WG+Samba) — NIEDOSTĘPNY w compact" off); else DRIVE_OPT=("drive" "BARVEA Drive (WireGuard + Samba, LXC 201)  +0 G app / +0 G" on); fi
SEL=$(whiptail --title "$TITLE" --checklist \
  "Moduły (SPACJA zaznacza). W nawiasie: dodatkowy RAM VM aplikacji.\nHost: ${HOST_RAM_MB} MB RAM, ${HOST_CORES} rdzeni." 20 76 8 \
  "${DRIVE_OPT[@]}" \
  "av"         "Antywirus uploadów (ClamAV)                    +1.5 G storage" on \
  "collab"     "Współedycja dokumentów (collab)                +1 G" on \
  "pointcloud" "Podgląd chmur punktów (PDAL)                   +12 G" off \
  "ifc"        "Kolizje IFC + zestawienia (ifc-clash, extractor) +16 G" on \
  3>&1 1>&2 2>&3 | tr -d '"')
for m in $SEL; do case "$m" in
  drive) [ "$TOPO" = compact ] || MOD_DRIVE=1 ;; av) MOD_AV=1 ;; collab) MOD_COLLAB=1 ;;
  pointcloud) MOD_POINTCLOUD=1 ;; ifc) MOD_IFC=1 ;; esac; done
PROFILES=""
[ "$MOD_POINTCLOUD" = 1 ] && PROFILES+="pointcloud,"
[ "$MOD_COLLAB" = 1 ] && PROFILES+="collab,"
[ "$MOD_IFC" = 1 ] && PROFILES+="ifc,"
[ "$TOPO" = compact ] && PROFILES+="compact,"
[ "$TOPO" = compact ] && [ "$MOD_AV" = 1 ] && PROFILES+="av,"
COMPOSE_PROFILES="${PROFILES%,}"
# RAM VM 102 (MB): baza 8 G + dwg 3 + office 3 + moduły; compact dodatkowo postgres/redis/minio ~3 G (+ clamav 3 G).
VM102_MEM_MB=$((8192 + 3072 + 3072))
[ "$MOD_POINTCLOUD" = 1 ] && VM102_MEM_MB=$((VM102_MEM_MB + 12288))
[ "$MOD_COLLAB" = 1 ] && VM102_MEM_MB=$((VM102_MEM_MB + 1024))
[ "$MOD_IFC" = 1 ] && VM102_MEM_MB=$((VM102_MEM_MB + 16384))
[ "$TOPO" = compact ] && VM102_MEM_MB=$((VM102_MEM_MB + 3072 + (MOD_AV == 1 ? 3072 : 0)))
VM102_CORES=8; [ "$MOD_IFC" = 1 ] || [ "$MOD_POINTCLOUD" = 1 ] || VM102_CORES=4
LXC201_MEM_MB=$((8192 + (MOD_AV == 1 ? 8192 : 0)))   # 16 G z clamd (prod), 8 G bez
TOTAL_MB=$((VM102_MEM_MB + 4096 + 24576 + 2048 + LXC201_MEM_MB))   # +VM100 4G +VM101 24G +Vault 2G
[ "$TOPO" = compact ] && TOTAL_MB=$VM102_MEM_MB
if [ "$PRESET" = staging ]; then
  msg "Preset staging: goście mali (test ścieżki), moduły wg wyboru, RAM gości NIE skalowany.\nProfile compose: ${COMPOSE_PROFILES:-<brak>}" 12
else
  WARN=""; [ "$TOTAL_MB" -gt "$HOST_RAM_MB" ] && WARN="\n⚠️ HOST MA ZA MAŁO RAM ($HOST_RAM_MB MB) — zmniejsz moduły albo dołóż pamięć."
  yesno "Rekomendowane zasoby:\n  VM aplikacji: ${VM102_CORES} rdzeni / $((VM102_MEM_MB/1024)) GB RAM\n  storage (LXC 201): $((LXC201_MEM_MB/1024)) GB\n  RAZEM goście: $((TOTAL_MB/1024)) GB  (host: $((HOST_RAM_MB/1024)) GB)\n  profile compose: ${COMPOSE_PROFILES:-<rdzeń>}$WARN\n\nKontynuować z tymi wartościami?" 18 || exit 1
fi

# ── 7. Backup ───────────────────────────────────────────────────────
BACKUP=$(menu "Backup off-site (restic, nocny):" \
  "storagebox"  "Hetzner Storage Box (SFTP) — jak prod" \
  "custom-sftp" "SFTP klienta (user@host:/sciezka)" \
  "skip"        "POMIŃ teraz — włączysz później: ./backup-enable.sh (lokalne dumpy i snapshoty zawsze)")
BACKUP_SFTP=""
[ "$BACKUP" = custom-sftp ] && BACKUP_SFTP=$(input "Cel SFTP (user@host:/sciezka; port przez ~/.ssh/config):" "")
[ "$BACKUP" = storagebox ] && BACKUP_SFTP=$(input "Storage Box (uXXXXXX@uXXXXXX.your-storagebox.de:/barvea):" "")

# ── 8. Vault (klucze) ───────────────────────────────────────────────
VAULT_KEYS=file
[ "$TOPO" = compact ] || VAULT_KEYS=$(menu "Vault — klucze unseal (Shamir 5, próg 3) i root token:" \
  "file"  "komplet do pliku /root/barvea-vault-keys.json (0600) — operator ZABIERA poza serwer [domyślne]" \
  "split" "podział: klucze drukowane raz na ekranie, nic na dysku — klient trzyma udziały")

# ── 9. Pierwszy administrator + organizacja ─────────────────────────
ADMIN_EMAIL=$(input "E-mail pierwszego administratora platformy:" "")
ADMIN_NAME=$(input "Imię i nazwisko administratora:" "")
ORG_NAME=$(input "Nazwa organizacji (pierwsza org w instancji):" "")
ORG_SLUG=$(input "Adres organizacji (slug, [a-z0-9-]):" "$(echo "$ORG_NAME" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-' | cut -c1-24)")
msg "Hasło administratora WYGENERUJE deploy-app.dedicated.sh i pokaże RAZ (trafi też do pliku handover).\nPrzy pierwszym logowaniu obowiązkowy kreator 2FA; organizacja ma „2FA wymagane” dla wszystkich." 12

# ── 10. Licencja (dedicated) ────────────────────────────────────────
LICENSE_FILE=""
[ "$DEPLOYMENT_MODE" = dedicated ] && \
  LICENSE_FILE=$(input "Ścieżka pliku licencji BARVEA-LICENSE.v1... (pusto = wgrasz potem w panelu):" "")

# ── podsumowanie + zapis ────────────────────────────────────────────
SUMMARY="Tryb:        $MODE / $TOPO (DEPLOYMENT_MODE=$DEPLOYMENT_MODE, preset=$PRESET)
Pula FAST:   ${FAST_DISKS:-<istniejąca>} [$FAST_RAID]
Pula BULK:   ${BULK_DISKS:-= FAST} ${BULK_RAID:+[$BULK_RAID]}
LAN:         ${LAN}.0/24   SSH:$SSH_PORT
WG users:    $WG_USERS_CIDR :$WG_USERS_PORT  DNS $WG_DNS
WG admin:    $WG0_CIDR :$WG0_PORT
Hosty:       $APP_HOST / $DRIVE_HOST / $ADMIN_HOST ${FQDN:+/ publ. $FQDN}
TLS:         $([ "$AIRGAP" = 1 ] && echo 'air-gap internal-CA' || echo "${FQDN:-WG/LAN-only internal-CA}")
Moduły:      drive=$MOD_DRIVE av=$MOD_AV collab=$MOD_COLLAB pointcloud=$MOD_POINTCLOUD ifc=$MOD_IFC
Profile:     ${COMPOSE_PROFILES:-<rdzeń>}   VM app: ${VM102_CORES}c/$((VM102_MEM_MB/1024))G  storage: $((LXC201_MEM_MB/1024))G
Backup:      $BACKUP ${BACKUP_SFTP:+($BACKUP_SFTP)}
Vault:       klucze → $VAULT_KEYS
Admin:       $ADMIN_EMAIL ($ADMIN_NAME) / org $ORG_NAME [$ORG_SLUG]
Licencja:    ${LICENSE_FILE:-<panel>}"
yesno "Zapisać konfigurację?\n\n$SUMMARY" 26 || { echo "Anulowano."; exit 1; }

{
  echo "# BARVEA bootstrap.conf — wygenerowany przez wizard.sh v2 $(date -Is)"
  echo "WIZARD_VERSION=2"
  echo "PRESET=$PRESET"
  echo "DEPLOYMENT_MODE=$DEPLOYMENT_MODE"
  echo "TOPO=$TOPO"
  # pule: nowe klucze + stare (POOL_* = fast) dla zgodności z bootstrap v1
  [ -n "$FAST_DISKS" ] && { echo "FAST_DISKS=\"$FAST_DISKS\""; echo "POOL_DISKS=\"$FAST_DISKS\""; }
  echo "FAST_RAID=${FAST_RAID:-mirror}"; echo "POOL_RAID=${FAST_RAID:-mirror}"
  [ -n "$BULK_DISKS" ] && { echo "BULK_DISKS=\"$BULK_DISKS\""; echo "BULK_RAID=$BULK_RAID"; }
  echo "LAN=$LAN"
  echo "SSH_PORT=$SSH_PORT"
  echo "WG_USERS_CIDR=$WG_USERS_CIDR"
  echo "WG_USERS_ADDR=$WG_USERS_ADDR"
  echo "WG_USERS_PORT=$WG_USERS_PORT"
  echo "WG_DNS=$WG_DNS"
  echo "WG0_CIDR=$WG0_CIDR"
  echo "WG0_ADDR=$WG0_ADDR"
  echo "WG0_PORT=$WG0_PORT"
  echo "INTERNAL_DOMAIN=$INTERNAL_DOMAIN"
  echo "APP_HOST=$APP_HOST"; echo "DRIVE_HOST=$DRIVE_HOST"; echo "ADMIN_HOST=$ADMIN_HOST"
  echo "AIRGAP=$AIRGAP"
  [ -n "$ASSETS_DIR" ] && echo "ASSETS_DIR=$ASSETS_DIR"
  [ -n "$FQDN" ] && echo "PUBLIC_FQDN=$FQDN"
  echo "MOD_DRIVE=$MOD_DRIVE"; echo "MOD_AV=$MOD_AV"; echo "MOD_COLLAB=$MOD_COLLAB"
  echo "MOD_POINTCLOUD=$MOD_POINTCLOUD"; echo "MOD_IFC=$MOD_IFC"
  echo "COMPOSE_PROFILES=$COMPOSE_PROFILES"
  echo "VM102_CORES=$VM102_CORES"; echo "VM102_MEM_MB=$VM102_MEM_MB"; echo "LXC201_MEM_MB=$LXC201_MEM_MB"
  echo "BACKUP_TARGET=$BACKUP"
  [ -n "$BACKUP_SFTP" ] && echo "BACKUP_SFTP=\"$BACKUP_SFTP\""
  echo "VAULT_KEYS=$VAULT_KEYS"
  echo "ADMIN_EMAIL=$ADMIN_EMAIL"; echo "ADMIN_NAME=\"$ADMIN_NAME\""
  echo "ORG_NAME=\"$ORG_NAME\""; echo "ORG_SLUG=$ORG_SLUG"
  [ -n "$LICENSE_FILE" ] && echo "LICENSE_FILE=$LICENSE_FILE"
  [ "${FORCE_NETS:-0}" = 1 ] && echo "FORCE_NETS=1"
} > "$CONF"
chmod 600 "$CONF"

# szkic handover — deploy-app uzupełnia (hasło admina raz, klucze Vault, backup)
{
  echo "# BARVEA — przekazanie instancji ($ORG_NAME) — szkic z kreatora $(date -I)"
  echo
  echo "## Adresy (tylko przez WireGuard; DNS tunelu $WG_DNS)"
  echo "- Aplikacja: https://$APP_HOST ${FQDN:+(publicznie: https://$FQDN)}"
  echo "- Panel administratora: https://$ADMIN_HOST (osobne logowanie, kod 2FA zawsze)"
  [ "$MOD_DRIVE" = 1 ] && echo "- BARVEA Drive: \\\\$DRIVE_HOST\\<org> (klient Drive, parowanie w aplikacji)"
  echo
  echo "## Porty do otwarcia na zaporze klienta (do serwera $LAN.x → host Proxmox)"
  echo "- UDP $WG_USERS_PORT — WireGuard użytkowników/Drive (z sieci klienta i z zewnątrz, jeśli praca zdalna)"
  echo "- UDP $WG0_PORT — WireGuard administracyjny (tylko operator)"
  echo "- TCP $SSH_PORT — SSH hosta (tylko operator, najlepiej tylko przez WG admin)"
  [ -n "$FQDN" ] && echo "- TCP 443 — publiczny FQDN $FQDN (opcjonalnie)"
  echo
  echo "## Klucze i sekrety (UZUPEŁNIA deploy-app)"
  echo "- Vault: $([ "$VAULT_KEYS" = split ] && echo 'udziały Shamira u klienta (5, próg 3) — wydrukowane raz' || echo 'komplet w /root/barvea-vault-keys.json — operator zabiera poza serwer') ; root token tamże"
  echo "- Hasło pierwszego administratora ($ADMIN_EMAIL): <wypisane raz przez deploy-app>"
  echo "- Hasła/tokeny usług: /root/barvea-bootstrap-creds.txt (0600) — kopia poza serwer"
  echo
  echo "## Backup"
  echo "- $([ "$BACKUP" = skip ] && echo 'BRAK off-site (tylko snapshoty ZFS + dumpy lokalne) — włączyć: ./backup-enable.sh' || echo "restic nocny → $BACKUP ${BACKUP_SFTP:+$BACKUP_SFTP}; hasło repo w creds")"
  echo
  echo "## Moduły: drive=$MOD_DRIVE av=$MOD_AV collab=$MOD_COLLAB pointcloud=$MOD_POINTCLOUD ifc=$MOD_IFC (profile: ${COMPOSE_PROFILES:-rdzeń})"
  echo "## Aktualizacje: podpisany bundle (MANIFEST.sig) → ./deploy-app.dedicated.sh; sygnatury AV z bundla/wolumenu clamav_db"
} > "$HANDOVER"
chmod 600 "$HANDOVER"

msg "Zapisano $CONF i szkic $HANDOVER.\n\nDalej:\n  ./bootstrap.sh            (infra: pule → goście → usługi → Vault → verify)\n  ./deploy-app.dedicated.sh (aplikacja z bundla, admin, licencja, handover)" 14
