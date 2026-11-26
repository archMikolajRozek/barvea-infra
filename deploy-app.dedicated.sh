#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — deploy-app.dedicated.sh v2 (D4, 2026-11-25): wdrożenie aplikacji
# z PODPISANEJ paczki wydania na instancji dedykowanej (po wizard.sh + bootstrap.sh).
#
# Uruchamiać na HOŚCIE (root): czyta ./bootstrap.conf + /root/barvea-bootstrap-creds.txt,
# steruje VM aplikacji przez ssh kluczem bootstrapa, LXC 201 przez pct.
#
# Pierwsza instalacja:  BUNDLE_DIR=/root/barvea-bundle-<wersja> ./deploy-app.dedicated.sh
#   1. weryfikacja paczki (podpis Ed25519 kluczem z repo, sha256 images.tar i plików,
#      minInstallerVersion, data budowy vs licencja.updatesUntil),
#   2. paczka → VM aplikacji, docker load,
#   3. .env.production z env.template: sekrety generowane TU, adresy z kreatora, dane
#      z creds (baza, Redis, MinIO, Vault, Drive, WG) — nic do ręcznego wpisywania,
#   4. katalogi na dużym dysku, barvea-compose (wrapper), compose up, health,
#   5. bootstrap-instance (admin + org + 2FA wymuszone) — hasło wypisane RAZ + do creds,
#   6. warstwa plików pierwszej organizacji (provision-org.sh: dataset, udział, ACL) — full,
#   7. licencja (LICENSE_FILE z kreatora, token przez stdin — nie argv),
#   8. smoke (app, panel admina, Caddy) + sekcja w HANDOVER-draft.md.
# Aktualizacja:  BUNDLE_DIR=<nowa paczka> ./deploy-app.dedicated.sh --update
#   = kroki 1-2 + podmiana BARVEA_VERSION/MINIO_IMAGE_TAG/CLAMAV_IMAGE_TAG w .env.production
#   + up -d (migracje robi aplikacja przy starcie) + health. Rollback: poprzednie obrazy
#   zostają — BARVEA_VERSION=<stara> w .env.production + barvea-compose up -d.
# Zmienne: ALLOW_UNSIGNED=1 (paczka testowa bez podpisu — NIGDY u klienta),
#          WG_PUBLIC_HOST=<host:port widoczny dla klientów Drive> (domyślnie: adres hosta
#          z trasy domyślnej + port wg-users), BOOTSTRAP_ADMIN_PASSWORD (puste = generowane).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$REPO_DIR/bootstrap.conf" ] || { echo "FATAL: brak $REPO_DIR/bootstrap.conf (wizard.sh)"; exit 1; }
. "$REPO_DIR/bootstrap.conf"
MODE=install; case "${1:-}" in --update) MODE=update;; --license) MODE=license;; "") ;; *) echo "użycie: $0 [--update|--license]"; exit 2;; esac
CREDS=/root/barvea-bootstrap-creds.txt
KEY=/root/.ssh/barvea-bootstrap
LAN="${LAN:-10.10.0}"; PRESET="${PRESET:-prod}"; CI_USER="${CI_USER:-miko}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-dedicated}"
INTERNAL_DOMAIN="${INTERNAL_DOMAIN:-barvea.internal}"
APP_HOST="${APP_HOST:-app.$INTERNAL_DOMAIN}"; ADMIN_HOST="${ADMIN_HOST:-admin.$INTERNAL_DOMAIN}"; DRIVE_HOST="${DRIVE_HOST:-drive.$INTERNAL_DOMAIN}"
WG_USERS_ADDR="${WG_USERS_ADDR:-10.67.0.1/16}"; WG_USERS_PORT="${WG_USERS_PORT:-51821}"
MOD_DRIVE="${MOD_DRIVE:-1}"; MOD_AV="${MOD_AV:-1}"; MOD_COLLAB="${MOD_COLLAB:-1}"; MOD_POINTCLOUD="${MOD_POINTCLOUD:-0}"; MOD_IFC="${MOD_IFC:-1}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"; AIRGAP="${AIRGAP:-0}"
APP_IP="${LAN}.30"; DATA_IP="${LAN}.20"; STORAGE_IP="${LAN}.40"; INFRA_IP="${LAN}.10"; VAULT_IP="${LAN}.50"
APP_DIR="/home/$CI_USER/barvea"
BUNDLE_DIR="${BUNDLE_DIR:-${ASSETS_DIR:-/root/barvea-assets}/bundle}"
HANDOVER="${HANDOVER:-$REPO_DIR/HANDOVER-draft.md}"
INSTALLER_VERSION="$(tr -d '[:space:]' < "$REPO_DIR/INSTALLER_VERSION")"
PUBKEY="$REPO_DIR/installer/update-manifest.pub.pem"
COMPACT=0; { [ "$PRESET" = compact ] || [[ ",$COMPOSE_PROFILES," == *",compact,"* ]]; } && COMPACT=1

log() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
has_profile() { case ",$COMPOSE_PROFILES," in *",$1,"*) return 0;; *) return 1;; esac; }
cred_get() { grep -oP "(?<=\b$1=)\S+" "$CREDS" 2>/dev/null | head -1; }
# ssh do VM aplikacji: rsh = surowe polecenie; rsudo = argumenty cytowane (%q), sudo; stdin przechodzi
rsh()   { ssh -o StrictHostKeyChecking=accept-new -i "$KEY" "$CI_USER@$APP_IP" "$@"; }
rsudo() { local c; c=$(printf '%q ' "$@"); rsh "sudo $c"; }
# plik → VM (install ze stdin; bez etapu w /tmp gościa): vput <src> <dst> [mode] [owner]
vput()  { local src="$1" dst="$2" mode="${3:-644}" own="${4:-root}"; rsh "sudo install -m $mode -o $own -g $own -D /dev/stdin $dst" < "$src"; }
gen_alnum() { dd if=/dev/urandom bs=256 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }
pem1() { awk 'BEGIN{ORS="\\n"}1' "$1"; }   # PEM → jedna linia z \n (compose rozwija w cudzysłowie)
for t in ssh openssl python3 sha256sum base64 curl; do command -v $t >/dev/null || die "brak narzędzia: $t"; done
[ -f "$KEY" ] || die "brak klucza $KEY (bootstrap.sh)"
[ -f "$CREDS" ] || [ "$COMPACT" = 1 ] || die "brak $CREDS (bootstrap.sh) — bez creds nie zrenderuję .env.production"
[ -f "$PUBKEY" ] || die "brak $PUBKEY"

if [ "$MODE" = license ]; then
  [ -n "${LICENSE_FILE:-}" ] && [ -f "$LICENSE_FILE" ] || die "--license: podaj LICENSE_FILE=<plik>"
  log "apply-license ($LICENSE_FILE)"
  tr -d '\r\n' < "$LICENSE_FILE" | rsh "sudo barvea-compose exec -T app sh -c 'LICENSE_TOKEN=\$(cat) npx tsx scripts/apply-license.ts'" \
    && { echo "  ✓ licencja wgrana"; exit 0; } || die "apply-license odrzucił token (exit 2 = nieważny/nie dla tej instancji)"
fi

# ═══ 1. Weryfikacja paczki ═════════════════════════════════════════
log "paczka: $BUNDLE_DIR"
[ -d "$BUNDLE_DIR" ] || die "brak katalogu paczki: $BUNDLE_DIR"
for f in images.tar compose.dedicated.yml env.template MANIFEST.json; do [ -f "$BUNDLE_DIR/$f" ] || die "brak $f w paczce"; done
if [ -f "$BUNDLE_DIR/MANIFEST.sig" ]; then
  cmp -s "$BUNDLE_DIR/MANIFEST.pub.pem" "$PUBKEY" 2>/dev/null || die "MANIFEST.pub.pem z paczki ≠ klucz instalatora ($PUBKEY) — paczka z innego klucza / inna wersja instalatora"
  SIGBIN="$(mktemp)"; base64 -d "$BUNDLE_DIR/MANIFEST.sig" > "$SIGBIN"
  openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin -in "$BUNDLE_DIR/MANIFEST.json" -sigfile "$SIGBIN" >/dev/null 2>&1 \
    || { rm -f "$SIGBIN"; die "PODPIS MANIFESTU NIEPRAWIDŁOWY — paczka zmieniona albo nie od BARVEA. STOP."; }
  rm -f "$SIGBIN"; echo "  ✓ podpis Ed25519 (klucz $PUBKEY)"
else
  [ "${ALLOW_UNSIGNED:-0}" = 1 ] || die "paczka BEZ podpisu (brak MANIFEST.sig) — odmowa. Testy: ALLOW_UNSIGNED=1"
  echo "  ⚠️  paczka BEZ podpisu — ALLOW_UNSIGNED=1 (tylko testy!)"
fi
# pola manifestu → zmienne (python3 = na hoście Proxmox; bez jq)
eval "$(python3 - "$BUNDLE_DIR/MANIFEST.json" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
tags = {i['service']: i['tag'] for i in m['images']}
print('M_VERSION=' + shlex.quote(m['bundleVersion']))
print('M_BUILD_DATE=' + shlex.quote(m['buildDate']))
print('M_MODE=' + shlex.quote(m['deploymentMode']))
print('M_MIN_INSTALLER=' + shlex.quote(str(m['minInstallerVersion'])))
print('M_TAR_SHA=' + shlex.quote(m['tarSha256']))
print('M_PROFILES=' + shlex.quote(','.join(m.get('profiles', []))))
print('M_COMMIT=' + shlex.quote(m.get('appCommit', '')))
print('M_MINIO_TAG=' + shlex.quote(tags.get('minio', '')))
print('M_CLAMAV_TAG=' + shlex.quote(tags.get('clamav', '')))
print('M_FILES=' + shlex.quote(' '.join(f"{f['path']}={f['sha256']}" for f in m['files'])))
PY
)"
[ "$M_MODE" = dedicated ] || die "paczka deploymentMode=$M_MODE, oczekiwane dedicated"
[ "$(printf '%s\n%s\n' "$M_MIN_INSTALLER" "$INSTALLER_VERSION" | sort -V | head -1)" = "$M_MIN_INSTALLER" ] \
  || die "paczka wymaga instalatora ≥ $M_MIN_INSTALLER, ten ma $INSTALLER_VERSION — zaktualizuj barvea-infra"
echo "  wersja $M_VERSION (build $M_BUILD_DATE, commit ${M_COMMIT:0:10}), profile w paczce: ${M_PROFILES:-rdzeń}"
for want in $(printf '%s' "$COMPOSE_PROFILES" | tr ',' ' '); do
  [[ ",$M_PROFILES," == *",$want,"* ]] || die "kreator wybrał moduł '$want', a paczka go nie zawiera (profile: $M_PROFILES)"
done
echo "  sha256 images.tar (duży plik, chwilę potrwa)…"
[ "$(sha256sum "$BUNDLE_DIR/images.tar" | cut -d' ' -f1)" = "$M_TAR_SHA" ] || die "sha256 images.tar ≠ manifest — paczka uszkodzona w transporcie"
for kv in $M_FILES; do
  [ "$(sha256sum "$BUNDLE_DIR/${kv%%=*}" | cut -d' ' -f1)" = "${kv#*=}" ] || die "sha256 ${kv%%=*} ≠ manifest"
done
echo "  ✓ sumy plików"
# data budowy vs okno aktualizacji licencji (gdy plik licencji podany; format BARVEA-LICENSE.v1.<payload b64url>.<sig>)
if [ -n "${LICENSE_FILE:-}" ] && [ -f "$LICENSE_FILE" ]; then
  python3 - "$LICENSE_FILE" "$M_BUILD_DATE" <<'PY' || die "paczka zbudowana PO końcu okna aktualizacji licencji (updatesUntil) — potrzebna nowa licencja albo starsza paczka"
import base64, json, sys, datetime
tok = open(sys.argv[1], encoding='utf-8').read().strip()
until = None
for seg in tok.split('.'):
    try:
        d = json.loads(base64.urlsafe_b64decode(seg + '=' * (-len(seg) % 4)))
        if isinstance(d, dict) and d.get('updatesUntil'):
            until = d['updatesUntil']; break
    except Exception:
        pass
if until is None:
    print('  ℹ️ licencja bez pola updatesUntil (albo inny format) — kontrola okna aktualizacji pominięta'); sys.exit(0)
b = datetime.datetime.fromisoformat(sys.argv[2].replace('Z', '+00:00')).date()
u = datetime.date.fromisoformat(str(until)[:10])
print(f'  licencja: aktualizacje do {u}, paczka z {b}')
sys.exit(0 if b <= u else 1)
PY
fi

# ═══ 2. Paczka → VM aplikacji + docker load ════════════════════════
log "paczka → $APP_IP:$APP_DIR"
rsudo install -d -o "$CI_USER" -g "$CI_USER" -m 750 "$APP_DIR"
REMOTE_SHA="$(rsh "sha256sum $APP_DIR/images.tar 2>/dev/null | cut -d' ' -f1" || true)"
if [ "$REMOTE_SHA" = "$M_TAR_SHA" ]; then
  echo "  images.tar już na VM (sha zgodne) — bez kopiowania"
else
  echo "  kopiowanie images.tar ($(du -h "$BUNDLE_DIR/images.tar" | cut -f1))…"
  vput "$BUNDLE_DIR/images.tar" "$APP_DIR/images.tar" 644 "$CI_USER"
  [ "$(rsh "sha256sum $APP_DIR/images.tar | cut -d' ' -f1")" = "$M_TAR_SHA" ] || die "sha256 images.tar na VM ≠ manifest — błąd kopiowania"
fi
vput "$BUNDLE_DIR/compose.dedicated.yml" "$APP_DIR/compose.dedicated.yml" 644 "$CI_USER"
vput "$BUNDLE_DIR/MANIFEST.json" "$APP_DIR/MANIFEST.$M_VERSION.json" 644 "$CI_USER"
log "docker load ($M_VERSION)"
rsudo docker load -i "$APP_DIR/images.tar" | tail -3
rsh "test -f $APP_DIR/Caddyfile" || die "brak $APP_DIR/Caddyfile na VM (bootstrap svc_app)"
rsh "test -f /etc/ssl/barvea/internal.crt -a -f /etc/ssl/barvea/internal.key" || die "brak /etc/ssl/barvea/internal.{crt,key} na VM (bootstrap svc_vault)"
# wrapper compose (operator: barvea-compose ps/logs/up)
sed "s|__APP_DIR__|$APP_DIR|" "$REPO_DIR/vm102/barvea-compose.sh" > /tmp/.bc.$$; vput /tmp/.bc.$$ /usr/local/sbin/barvea-compose 755; rm -f /tmp/.bc.$$

# ═══ 3. .env.production ════════════════════════════════════════════
if [ "$MODE" = update ]; then
  log "update: podmiana wersji w .env.production"
  rsh "test -f $APP_DIR/.env.production" || die "brak $APP_DIR/.env.production — to nie jest zainstalowana instancja (uruchom bez --update)"
  rsudo sed -i -e "s|^BARVEA_VERSION=.*|BARVEA_VERSION=$M_VERSION|" \
    -e "s|^MINIO_IMAGE_TAG=.*|MINIO_IMAGE_TAG=${M_MINIO_TAG}|" -e "s|^CLAMAV_IMAGE_TAG=.*|CLAMAV_IMAGE_TAG=${M_CLAMAV_TAG}|" "$APP_DIR/.env.production"
else
  if rsh "test -f $APP_DIR/.env.production" && [ "${FORCE_REINIT:-0}" != 1 ]; then
    die "$APP_DIR/.env.production już istnieje — aktualizacja: --update; świeża instalacja na nowo: FORCE_REINIT=1 (NADPISZE sekrety!)"
  fi
  log "render .env.production (sekrety generowane tutaj, reszta z kreatora i creds)"
  declare -A OV=()
  # ── wersje, moduły, adresy ──
  OV[BARVEA_VERSION]="$M_VERSION"; OV[MINIO_IMAGE_TAG]="$M_MINIO_TAG"; OV[CLAMAV_IMAGE_TAG]="$M_CLAMAV_TAG"
  OV[COMPOSE_PROFILES]="$COMPOSE_PROFILES"
  OV[OFFLINE_MODE]="$([ "$AIRGAP" = 1 ] && echo true || echo false)"
  OV[APP_URL]="https://$APP_HOST"; OV[NEXTAUTH_URL]="https://$APP_HOST"; OV[NEXT_PUBLIC_APP_URL]="https://$APP_HOST"
  OV[ADMIN_HOST]="$ADMIN_HOST"
  # ── sekrety aplikacji ──
  S=$(openssl rand -base64 32); OV[NEXTAUTH_SECRET]="$S"; OV[AUTH_SECRET]="$S"
  OV[TOTP_ENCRYPTION_KEY]="$(openssl rand -base64 32)"
  OV[MTLS_PROXY_SECRET]="$(openssl rand -hex 32)"; OV[CRON_SECRET]="$(openssl rand -hex 32)"
  # ── baza, Redis, MinIO ──
  if [ "$COMPACT" = 1 ]; then
    PGPW=$(gen_alnum 32); RDPW=$(gen_alnum 32); MU=$(gen_alnum 20); MP=$(gen_alnum 40)
    OV[POSTGRES_PASSWORD]="$PGPW"; OV[REDIS_PASSWORD]="$RDPW"
    OV[DATABASE_URL]="postgresql://barvea:${PGPW}@postgres:5432/barvea?schema=public"
    OV[REDIS_URL]="redis://:${RDPW}@redis:6379"
    OV[MINIO_ENDPOINT]=minio; OV[MINIO_ROOT_USER]="$MU"; OV[MINIO_ROOT_PASSWORD]="$MP"; OV[MINIO_ACCESS_KEY]="$MU"; OV[MINIO_SECRET_KEY]="$MP"
  else
    PGA="$(grep -oP '(?<=barvea_app=)\S+' "$CREDS" | head -1)"; [ -n "$PGA" ] || die "creds: brak hasła barvea_app (svc_data)"
    OV[DATABASE_URL]="postgresql://barvea_app:${PGA}@${DATA_IP}:5432/barvea?schema=public"
    RDPW="$(cred_get REDIS_PASSWORD)"; OV[REDIS_URL]="redis://${RDPW:+:$RDPW@}${DATA_IP}:6379"
    for k in MINIO_ENDPOINT MINIO_ROOT_USER MINIO_ROOT_PASSWORD MINIO_ACCESS_KEY MINIO_SECRET_KEY; do
      v="$(cred_get $k)"; [ -n "$v" ] || die "creds: brak $k (svc_data MinIO)"; OV[$k]="$v"; done
    # ── Vault (full) ──
    OV[VAULT_ENDPOINT]="https://${VAULT_IP}:8200"
    OV[VAULT_APPROLE_ROLE_ID]="$(cred_get VAULT_APPROLE_ROLE_ID)"; OV[VAULT_APPROLE_SECRET_ID]="$(cred_get VAULT_APPROLE_SECRET_ID)"
    [ -n "${OV[VAULT_APPROLE_ROLE_ID]}" ] && [ -n "${OV[VAULT_APPROLE_SECRET_ID]}" ] || die "creds: brak AppRole barvea-app (svc_vault / bootstrap-vault.sh)"
  fi
  # ── para ES256 (tokeny sesji Drive) ──
  T=$(mktemp -d); chmod 700 "$T"
  openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out "$T/es.key" 2>/dev/null
  openssl ec -in "$T/es.key" -pubout -out "$T/es.pub" 2>/dev/null
  OV[UNWRAP_TOKEN_PRIVATE_KEY_PEM]="\"$(pem1 "$T/es.key")\""; OV[UNWRAP_TOKEN_PUBLIC_KEY_PEM]="\"$(pem1 "$T/es.pub")\""
  # ── Drive (full + MOD_DRIVE) ──
  if [ "$COMPACT" = 0 ] && [ "$MOD_DRIVE" = 1 ]; then
    OV[DRIVE_DATA_URL]="http://${STORAGE_IP}:8723"; OV[DRIVE_DATA_TOKEN]="$(cred_get DRIVE_DATA_TOKEN)"
    OV[DRIVE_ACL_SERVICE_TOKEN]="$(cred_get DRIVE_ACL_SERVICE_TOKEN)"
    OV[DRIVE_SMB_HOST]="$DRIVE_HOST"
    OV[DRIVE_SMB_PROVISION_URL]="http://${STORAGE_IP}:8722"; OV[DRIVE_SMB_PROVISION_TOKEN]="$(cred_get SMB_PROVISIOND_TOKEN)"
    WGT="$(cred_get WG_PROVISIOND_TOKEN)"
    OV[DRIVE_WG_PROVISION_URL]="http://${INFRA_IP}:8721"; OV[DRIVE_WG_PROVISION_TOKEN]="$WGT"; OV[DRIVE_WG_MANIFEST_TOKEN]="$WGT"
    WGIP="${WG_USERS_ADDR%/*}"
    OV[DRIVE_WG_ALLOWED_IPS]="${APP_IP}/32,${STORAGE_IP}/32,${WGIP}/32"; OV[DRIVE_WG_DNS]="$WGIP"
    # mapa nazw tunelu → adresy dla fallbacku klienta Drive (NRPT z polityki domeny; decyzja 26.11: fallback TAK, hardcode NIE)
    OV[DRIVE_WG_INTERNAL_HOSTS]="${APP_HOST}=${APP_IP},${DRIVE_HOST}=${STORAGE_IP}"
    if [ -n "${WG_PUBLIC_HOST:-}" ]; then OV[DRIVE_WG_ENDPOINT]="$WG_PUBLIC_HOST"
    else OV[DRIVE_WG_ENDPOINT]="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )\S+' || hostname -I | awk '{print $1}'):${WG_USERS_PORT}"; fi
    OV[DRIVE_WG_SERVER_PUBKEY]="$(ssh -o StrictHostKeyChecking=accept-new -i "$KEY" "$CI_USER@$INFRA_IP" 'sudo cat /etc/wireguard/server_public.key' | tr -d '\n')"
    for k in DRIVE_DATA_TOKEN DRIVE_ACL_SERVICE_TOKEN DRIVE_SMB_PROVISION_TOKEN DRIVE_WG_PROVISION_TOKEN DRIVE_WG_SERVER_PUBKEY; do
      [ -n "${OV[$k]}" ] || die "Drive: brak $k (creds / VM 100)"; done
    OV[AV_DRIVE_MOUNT]=/srv/orgs
  fi
  # ── antywirus ──
  if [ "$MOD_AV" = 1 ]; then
    OV[AV_MODE]=block; OV[AV_CLAMD_HOST]="$([ "$COMPACT" = 1 ] && echo clamav || echo "$STORAGE_IP")"
    [ "$COMPACT" = 1 ] && ! has_profile av && die "MOD_AV=1 w compact wymaga profilu 'av' w COMPOSE_PROFILES"
  else OV[AV_MODE]=off; fi
  # ── moduły: adresy TYLKO dla włączonych (pusty = moduł wyłączony w appce) ──
  if has_profile pointcloud; then OV[POINT_CLOUD_PREVIEW_URL]="http://point-cloud-preview:8080"; OV[POINTCLOUD_PREVIEW_TOKEN]="$(openssl rand -hex 32)"; fi
  if has_profile ifc; then
    OV[IFC_CLASH_URL]="http://ifc-clash:8080"; OV[IFC_EXTRACTOR_URL]="http://ifc-extractor:8080"
    OV[IFC_CLASH_TOKEN]="$(openssl rand -hex 32)"; OV[IFC_EXTRACTOR_TOKEN]="$(openssl rand -hex 32)"
  fi
  if has_profile collab; then
    OV[COLLAB_INTERNAL_URL]="http://collab:1235"; OV[COLLAB_PUBLIC_URL]="wss://$APP_HOST/_collab"
    OV[COLLAB_INTERNAL_WS_URL]="ws://collab:1234"   # edycja plików przez AI (handoff 26.11) — app łączy się z collab jak przeglądarka
    OV[COLLAB_SERVICE_TOKEN]="$(openssl rand -hex 32)"
    openssl genpkey -algorithm ed25519 -out "$T/ed.key" 2>/dev/null; openssl pkey -in "$T/ed.key" -pubout -out "$T/ed.pub" 2>/dev/null
    OV[COLLAB_JWT_PRIVATE_KEY]="\"$(pem1 "$T/ed.key")\""; OV[COLLAB_JWT_PUBLIC_KEY]="\"$(pem1 "$T/ed.pub")\""
  fi
  rm -rf "$T"
  # ── poczta z kreatora (opcjonalnie w bootstrap.conf) ──
  for k in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS FROM_EMAIL; do v="${!k:-}"; [ -n "$v" ] && OV[$k]="$v"; done
  # ── render: szablon linia po linii; KEY= z nadpisaniem → wartość, reszta bez zmian ──
  ENV=$(mktemp); chmod 600 "$ENV"
  { echo "# BARVEA .env.production — deploy-app.dedicated.sh v2 $(date -Is), paczka $M_VERSION. NIE edytować sekretów ręcznie."
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
        k="${BASH_REMATCH[1]}"
        if [ -n "${OV[$k]+x}" ]; then printf '%s=%s\n' "$k" "${OV[$k]}"; unset 'OV[$k]'; else printf '%s\n' "$line"; fi
      else printf '%s\n' "$line"; fi
    done < "$BUNDLE_DIR/env.template"
    for k in "${!OV[@]}"; do echo "⚠️  zmienna $k nieobecna w env.template paczki — dopisuję na końcu" >&2; printf '%s=%s\n' "$k" "${OV[$k]}"; done
  } > "$ENV"
  for must in DATABASE_URL NEXTAUTH_SECRET TOTP_ENCRYPTION_KEY MTLS_PROXY_SECRET MINIO_ENDPOINT BARVEA_VERSION; do
    grep -qE "^$must=.+" "$ENV" || die "render: pusta $must"; done
  vput "$ENV" "$APP_DIR/.env.production" 600 "$CI_USER"; rm -f "$ENV"
  echo "  ✓ .env.production ($(rsh "grep -cE '^[A-Z_0-9]+=' $APP_DIR/.env.production") zmiennych, 600)"
  # ── katalogi na dużym dysku (bind-mount nie dziedziczy właściciela z obrazu) ──
  rsudo bash -c "install -d -o 1001 -g 1001 /srv/upload-tmp; for d in pcp-scratch clash-scratch ifc-extractor-scratch; do install -d -o 57439 -g 57439 /srv/upload-tmp/\$d; done"
fi

# ═══ 4. compose up + health ════════════════════════════════════════
log "barvea-compose up -d (profile: ${COMPOSE_PROFILES:-rdzeń})"
rsudo barvea-compose up -d --remove-orphans
echo "  health aplikacji (pierwszy start = migracje; do 10 min)…"
for i in $(seq 1 120); do
  st="$(rsudo docker inspect --format '{{.State.Health.Status}}' barvea-app 2>/dev/null || echo starting)"
  [ "$st" = healthy ] && { echo "  ✓ app healthy"; break; }
  [ "$st" = unhealthy ] && { rsudo barvea-compose logs --tail 60 app; die "app unhealthy — logi wyżej"; }
  [ "$i" = 120 ] && { rsudo barvea-compose logs --tail 60 app; die "health timeout"; }
  sleep 5
done
rsudo barvea-compose ps --format 'table {{.Service}}\t{{.Status}}'

# ═══ 5. Pierwszy administrator + organizacja (tylko instalacja) ════
ORG_ID=""
if [ "$MODE" = install ]; then
  log "bootstrap-instance: $ADMIN_EMAIL / org \"$ORG_NAME\" [$ORG_SLUG] (+ 2FA wymuszone)"
  [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ORG_NAME:-}" ] && [ -n "${ORG_SLUG:-}" ] || die "bootstrap.conf: brak ADMIN_EMAIL / ORG_NAME / ORG_SLUG (wizard.sh)"
  ADMIN_PW="${BOOTSTRAP_ADMIN_PASSWORD:-$(gen_alnum 24)}"
  [[ "$ORG_SLUG" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "ORG_SLUG '$ORG_SLUG' — dozwolone [a-z0-9-]"
  # hasło przez stdin → env w kontenerze (nigdy w argv ssh/docker); argumenty (nazwa org z polskimi
  # znakami/spacjami) przez skrypt kroku na VM i "$@" do sh -c — bez zagnieżdżonych cudzysłowów ssh
  BI=$(mktemp); chmod 600 "$BI"
  { printf '#!/bin/bash\nset -e\n'
    printf 'exec barvea-compose exec -T app sh -c %s sh --email %s --org %s --org-slug %s --name %s --force-2fa\n' \
      "'BOOTSTRAP_ADMIN_PASSWORD=\$(cat) exec npx tsx scripts/bootstrap-instance.ts \"\$@\"'" \
      "$(printf %q "$ADMIN_EMAIL")" "$(printf %q "$ORG_NAME")" "$(printf %q "$ORG_SLUG")" "$(printf %q "${ADMIN_NAME:-Administrator}")"
  } > "$BI"
  vput "$BI" /root/.barvea-bootstrap-instance.sh 700; rm -f "$BI"
  printf '%s' "$ADMIN_PW" | rsh "sudo bash /root/.barvea-bootstrap-instance.sh; r=\$?; sudo rm -f /root/.barvea-bootstrap-instance.sh; exit \$r" \
    || die "bootstrap-instance padł — logi: barvea-compose logs app"
  printf 'ADMIN_LOGIN=%s ADMIN_PASSWORD=%s\n' "$ADMIN_EMAIL" "$ADMIN_PW" >> "$CREDS"; chmod 600 "$CREDS"
  printf '\n  ╔════════════════════════════════════════════════════════╗\n  ║ HASŁO PIERWSZEGO ADMINISTRATORA (pokazane raz, też w %s):\n  ║   %s\n  ║   %s\n  ║ Pierwsze logowanie: https://%s → kreator 2FA (wymuszony)\n  ╚════════════════════════════════════════════════════════╝\n\n' "$CREDS" "$ADMIN_EMAIL" "$ADMIN_PW" "$APP_HOST"
  unset ADMIN_PW
  # id organizacji (warstwa plików Drive = dataset per orgId)
  if [ "$COMPACT" = 0 ]; then
    ORG_ID="$(ssh -o StrictHostKeyChecking=accept-new -i "$KEY" "$CI_USER@$DATA_IP" "sudo -u postgres psql -d barvea -Atc \"select id from \\\"Organization\\\" where slug='$ORG_SLUG'\"" | tr -d '[:space:]')"
  else
    ORG_ID="$(rsh "sudo barvea-compose exec -T postgres psql -U barvea -d barvea -Atc \"select id from \\\"Organization\\\" where slug='$ORG_SLUG'\"" | tr -d '[:space:]')"
  fi
  [ -n "$ORG_ID" ] || echo "  ⚠️  nie odczytałem id organizacji $ORG_SLUG z bazy — provision-org.sh uruchom ręcznie"
fi

# ═══ 6. Warstwa plików pierwszej organizacji (full + Drive) ════════
if [ "$MODE" = install ] && [ "$COMPACT" = 0 ] && [ "$MOD_DRIVE" = 1 ] && [ -n "$ORG_ID" ]; then
  log "provision-org.sh $ORG_ID $ORG_SLUG (dataset, udział [$ORG_SLUG], ACL)"
  pct exec 201 -- sed -i "s|^APP_URL=.*|APP_URL=https://$APP_HOST|" /etc/barvea/acl-sync.env   # bootstrap wpisał domyślny host
  "$REPO_DIR/proxmox/provision-org.sh" "$ORG_ID" "$ORG_SLUG" || die "provision-org.sh nieudany — powtórz ręcznie: proxmox/provision-org.sh $ORG_ID $ORG_SLUG"
fi

# ═══ 7. Licencja (token przez stdin) ═══════════════════════════════
if [ "$MODE" = install ]; then
  if [ -n "${LICENSE_FILE:-}" ] && [ -f "$LICENSE_FILE" ]; then
    log "apply-license ($LICENSE_FILE)"
    tr -d '\r\n' < "$LICENSE_FILE" | rsh "sudo barvea-compose exec -T app sh -c 'LICENSE_TOKEN=\$(cat) npx tsx scripts/apply-license.ts'" \
      && echo "  ✓ licencja wgrana" || die "apply-license odrzucił token (exit 2 = nieważny/nie dla tej instancji)"
  else
    echo "  ℹ️  brak LICENSE_FILE — instancja startuje bez licencji (tylko odczyt). Panel administratora → Licencja, albo LICENSE_FILE=<plik> ./deploy-app.dedicated.sh --license"
  fi
fi

# ═══ 8. Smoke ══════════════════════════════════════════════════════
log "smoke (z hosta, --resolve na $APP_IP)"
code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$1:443:$APP_IP" "https://$1$2" || echo 000; }
A=$(code "$APP_HOST" /api/health); [ "$A" = 200 ] && echo "  ✓ https://$APP_HOST/api/health 200" || echo "  ✗ https://$APP_HOST/api/health → $A"
B=$(code "$ADMIN_HOST" /); case "$B" in 200|302|307) echo "  ✓ https://$ADMIN_HOST/ → $B";; *) echo "  ✗ https://$ADMIN_HOST/ → $B";; esac
C=$(code "$APP_HOST" /api/v1/admin/ping); [ "$C" = 404 ] || [ "$C" = 401 ] && echo "  ✓ /api/v1/admin/* pod hostem appki → $C (zamknięte)" || echo "  ℹ️ /api/v1/admin/* pod hostem appki → $C"
D=$(code "$APP_HOST" /api/v1/internal/ping); [ "$D" = 404 ] && echo "  ✓ /api/v1/internal/* → 404" || echo "  ✗ /api/v1/internal/* → $D (ma być 404)"
echo "  cert: $(echo | openssl s_client -connect "$APP_IP:443" -servername "$APP_HOST" 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"

# ═══ 9. HANDOVER ═══════════════════════════════════════════════════
if [ "$MODE" = install ]; then
  { printf '\n## deploy-app (%s) — paczka %s (build %s)\n' "$(date -I)" "$M_VERSION" "$M_BUILD_DATE"
    printf -- '- Aplikacja: https://%s · panel administratora: https://%s (2FA zawsze) · Drive: \\\\%s\\%s\n' "$APP_HOST" "$ADMIN_HOST" "$DRIVE_HOST" "${ORG_SLUG:-<slug>}"
    printf -- '- Pierwszy administrator: %s — hasło w %s (pokazane raz przy instalacji; usunąć plik po przeniesieniu do managera haseł)\n' "$ADMIN_EMAIL" "$CREDS"
    printf -- '- Organizacja: %s [%s]%s\n' "$ORG_NAME" "$ORG_SLUG" "${ORG_ID:+ · id $ORG_ID · dataset per org + udział Samby [$ORG_SLUG]}"
    printf -- '- Licencja: %s\n' "$([ -n "${LICENSE_FILE:-}" ] && echo "wgrana z $LICENSE_FILE" || echo 'BRAK — wgrać w panelu administratora')"
    printf -- '- Moduły (profile compose): %s · antywirus: %s · tryb offline: %s\n' "${COMPOSE_PROFILES:-rdzeń}" "$([ "$MOD_AV" = 1 ] && echo block || echo off)" "$([ "$AIRGAP" = 1 ] && echo tak || echo nie)"
    printf -- '- Operator na VM aplikacji: `barvea-compose ps|logs -f app|up -d` (katalog %s). Aktualizacja: nowa paczka → `BUNDLE_DIR=… ./deploy-app.dedicated.sh --update` na hoście. Rollback: BARVEA_VERSION=<poprzednia> w .env.production + `barvea-compose up -d`.\n' "$APP_DIR"
    printf -- '- Kolejne organizacje: utworzyć w panelu → na hoście `proxmox/provision-org.sh <orgId> <slug>`.\n'
  } >> "$HANDOVER"
  echo "  ✓ sekcja dopisana do $HANDOVER"
fi
log "DEPLOY APP DONE ($MODE, $M_VERSION)"
[ "$MODE" = install ] && echo "  Następne: zaloguj się jako $ADMIN_EMAIL (2FA), wgraj licencję jeśli brak, test uploadu (AV) i parowania Drive." || true
