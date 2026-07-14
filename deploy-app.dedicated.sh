#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — deploy-app.dedicated.sh: faza 4/5 installera dedyk.
# Wdraża aplikację z release-bundle (po ./bootstrap.sh), spina
# DEPLOYMENT_MODE + superadmin + licencję wg kontraktu z APP (2026-07-14).
#
# Uruchamiać na HOŚCIE (steruje app-VM przez ssh kluczem bootstrapa).
# Czyta ./bootstrap.conf + /root/barvea-bootstrap-creds.txt.
#
# ⚠️ SZKIELET — bundle APP (#4) jeszcze niegotowy: docker-images tarball,
#    compose.dedicated.yml, env.template, scripts/{bootstrap-instance,
#    apply-license}.ts przychodzą OD APP. Miejsca do uzupełnienia = # TODO(bundle).
#    Części pod naszą kontrolą (env-render, superadmin-call, license-apply,
#    health) — gotowe wg kontraktu. NIETESTOWANE do czasu bundla.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$REPO_DIR/bootstrap.conf" ] && . "$REPO_DIR/bootstrap.conf"
CREDS=/root/barvea-bootstrap-creds.txt
KEY=/root/.ssh/barvea-bootstrap
LAN="${LAN:-10.10.0}"; PRESET="${PRESET:-prod}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-dedicated}"
APP_IP="${LAN}.30"; CI_USER="${CI_USER:-miko}"
BUNDLE_DIR="${BUNDLE_DIR:-${ASSETS_DIR:-/root/barvea-assets}/bundle}"
APP_DIR="/home/$CI_USER/barvea"

log() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
cred_get() { grep -oP "(?<=^$1=)\S+" "$CREDS" | head -1; }
ash() { ssh -o StrictHostKeyChecking=accept-new -i "$KEY" "$CI_USER@$APP_IP" "sudo bash -c '$*'"; }
aput(){ scp -o StrictHostKeyChecking=accept-new -i "$KEY" "$1" "$CI_USER@$APP_IP:/tmp/.d.$$"; ash "mv /tmp/.d.$$ $2"; }

[ -d "$BUNDLE_DIR" ] || die "brak bundla: $BUNDLE_DIR (od APP: images.tar, compose.dedicated.yml, env.template, scripts/)"

# ── 1. Bundle na app-VM + docker load ──────────────────────────────
log "Bundle → app-VM ($APP_IP)"
ash "mkdir -p $APP_DIR"
for f in images.tar compose.dedicated.yml; do
    [ -f "$BUNDLE_DIR/$f" ] || die "brak $f w bundlu"
    aput "$BUNDLE_DIR/$f" "$APP_DIR/$f"
done
# TODO(bundle): jeśli obrazy podpisane update-manifest-ed25519 — weryfikacja
# podpisu manifestu PRZED load (updater sprawdza też updatesUntil z licencji).
log "docker load obrazów"
ash "docker load -i $APP_DIR/images.tar"

# ── 2. .env.production (z creds + parametrów; merge z env.template) ─
log "render .env.production"
PGA="$(cred_get 'barvea_app' || true)"   # svc_data zapisał 'PG barvea_app=<pw> ...'
PGA="$(grep -oP '(?<=barvea_app=)\S+' "$CREDS" | head -1)"
DT="$(cred_get DRIVE_DATA_TOKEN)"
NEXTAUTH_SECRET="$(dd if=/dev/urandom bs=48 count=1 2>/dev/null | base64 -w0)"
if [ "$PRESET" = compact ]; then
    DB_HOST=postgres; REDIS_HOST=redis; DRIVE_URL=""     # kontenery w compose
else
    DB_HOST="${LAN}.20"; REDIS_HOST="${LAN}.30"; DRIVE_URL="http://${LAN}.40:8723"
fi
ENV=/tmp/.env.$$
cat > "$ENV" <<ENVEOF
# BARVEA .env.production (dedicated) — deploy-app.dedicated.sh
DEPLOYMENT_MODE=$DEPLOYMENT_MODE
NEXT_PUBLIC_DEPLOYMENT_MODE=$DEPLOYMENT_MODE
DATABASE_URL=postgresql://barvea_app:${PGA}@${DB_HOST}:5432/barvea?schema=public
REDIS_URL=redis://${REDIS_HOST}:6379
NEXTAUTH_SECRET=$NEXTAUTH_SECRET
NEXTAUTH_URL=https://${PUBLIC_FQDN:-app.barvea.internal}
DRIVE_DATA_URL=$DRIVE_URL
DRIVE_DATA_TOKEN=$DT
# Turnstile/Stripe/SMTP: puste = fail-open/off (air-gap OK, APP potwierdził)
# TODO(bundle): domerge env.template APP (MINIO_*, VAULT AppRole, module flags,
#   NEXT_PUBLIC_APP_URL, licencja=hardcode w obrazie nie env).
ENVEOF
[ -f "$BUNDLE_DIR/env.template" ] && grep -vE '^\s*#|^\s*$' "$BUNDLE_DIR/env.template" \
    | grep -vE "^($(grep -oE '^[A-Z_]+' "$ENV" | paste -sd'|'))=" >> "$ENV" || true
aput "$ENV" "$APP_DIR/.env.production"; rm -f "$ENV"
ash "chmod 600 $APP_DIR/.env.production"

# ── 3. compose up (migracje = ENTRYPOINT obrazu app, wg kontraktu APP) ─
log "docker compose up"
ash "cd $APP_DIR && docker compose -f compose.dedicated.yml --env-file .env.production up -d"

log "health (do 3 min)"
for i in $(seq 1 36); do
    if ash "curl -fsS http://localhost:3005/api/health >/dev/null 2>&1"; then
        echo "  ✓ app healthy"; break; fi
    [ "$i" = 36 ] && die "health timeout — sprawdź: docker compose logs app"
    sleep 5
done

# ── 4. Superadmin (bootstrap-instance.ts — po migrate, idempotentny) ─
log "superadmin (bootstrap-instance)"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"; ADMIN_ORG="${ADMIN_ORG:-}"
[ -n "$ADMIN_EMAIL" ] || ADMIN_EMAIL=$(read -rp "Email superadmina: " x; echo "$x")
[ -n "$ADMIN_ORG" ]   || ADMIN_ORG=$(read -rp "Nazwa organizacji: " x; echo "$x")
ADMIN_PW="${BOOTSTRAP_ADMIN_PASSWORD:-$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | base64 -w0 | tr -d '/+=' | head -c 20)}"
echo "  hasło superadmina: $ADMIN_PW  (zapisz!)"
# wołane W kontenerze app (node), wzorzec APP; hasło przez env (nie argv)
ash "cd $APP_DIR && docker compose -f compose.dedicated.yml exec -T -e BOOTSTRAP_ADMIN_PASSWORD='$ADMIN_PW' app \
     npx tsx scripts/bootstrap-instance.ts --email '$ADMIN_EMAIL' --org '$ADMIN_ORG' --force-2fa" \
     || die "bootstrap-instance padł (exit != 0)"

# ── 5. Licencja (apply-license.ts; LICENSE_TOKEN z pliku) ──────────
if [ -n "${LICENSE_FILE:-}" ] && [ -f "$LICENSE_FILE" ]; then
    log "apply-license"
    TOK=$(cat "$LICENSE_FILE")
    ash "cd $APP_DIR && docker compose -f compose.dedicated.yml exec -T -e LICENSE_TOKEN='$TOK' app \
         npx tsx scripts/apply-license.ts" \
         && echo "  ✓ licencja wgrana" || die "apply-license odrzucił token (exit 2?)"
else
    echo "  ℹ️ brak LICENSE_FILE — instancja startuje UNLICENSED (read-only)."
    echo "     Wgraj później: panel platform-admin → Licencja, albo LICENSE_FILE= i re-run."
fi

log "DEPLOY APP DONE"
cat <<NEXT
  Dostęp: https://${PUBLIC_FQDN:-app.barvea.internal}  (login: $ADMIN_EMAIL)
  Backup: backup/README.md (jeśli BACKUP_TARGET != none).
  Moduł drive: licencja modules:["drive"] → warstwa dostępu (WG/Samba) już stoi.
NEXT
