#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — build-release-bundle.sh: buduje release-bundle dedyk z source
# aplikacji (nasza strona #4). Uruchamiać na maszynie Z DOCKEREM + dostępem
# do repo APP (my budujemy, klient dostaje gotowy bundle — nie ma dostępu
# do naszych repo). Wynik → bundle/ dla deploy-app.dedicated.sh /
# build-offline-assets.sh.
#
# KLUCZOWE (kontrakt APP 2026-07-14): NEXT_PUBLIC_DEPLOYMENT_MODE=dedicated
# musi być --build-arg (Next inline'uje NEXT_PUBLIC w BUILD, nie runtime).
# MINIO_IMAGE_TAG + BARVEA_VERSION podstawia ten builder.
#
# ⚠️ SZKIELET/NIETESTOWANE — dokładne ścieżki/nazwy obrazów potwierdzić z
#    APP (deploy/dedicated/ layout, Dockerfile args, dwg-converter build).
#    Miejsca: # CONFIRM(APP).
#
# Użycie: ./build-release-bundle.sh <APP_SRC_DIR> <VERSION> [OUT]
#   APP_SRC_DIR = checkout repo aplikacji (git clone/pull u NAS)
#   VERSION     = tag, np. 2026.07.14
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
APP_SRC="${1:?podaj katalog źródeł aplikacji (checkout repo APP)}"
VERSION="${2:?podaj wersję, np. 2026.07.14}"
OUT="${3:-./barvea-assets/bundle}"

# Obrazy bazowe (APP CONFIRM 2026-07-14: postgres:18 [K2], redis:7-alpine).
# minio: pin z proda — auto-detect z żywego kontenera barvea-minio (uruchamiaj
# na maszynie z dostępem do proda, np. barvea-app), albo podaj MINIO_IMAGE=.
PG_IMAGE="${PG_IMAGE:-postgres:18}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
MINIO_IMAGE="${MINIO_IMAGE:-$(docker inspect barvea-minio --format '{{.Config.Image}}' 2>/dev/null || true)}"
APP_IMAGE="barvea-app:$VERSION"       # VERSION = TAG obrazu (nie build-arg; APP)
DWG_IMAGE="barvea-dwg-converter:$VERSION"
OFFICE_IMAGE="barvea-office-converter:$VERSION"

log() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
command -v docker >/dev/null || die "docker wymagany"
[ -d "$APP_SRC" ] || die "brak APP_SRC: $APP_SRC"
[ -f "$APP_SRC/Dockerfile" ] || die "brak $APP_SRC/Dockerfile (root repo app)"
[ -n "$MINIO_IMAGE" ] || die "MINIO_IMAGE nieustawione i brak kontenera barvea-minio — podaj MINIO_IMAGE=minio/minio:<pin>"
mkdir -p "$OUT"

# ── 1. Build obrazu app — TYLKO build-arg NEXT_PUBLIC_DEPLOYMENT_MODE
#      (Next inline'uje w build; default ""=saas). Dockerfile=root, kontekst=root.
#      VERSION = tag obrazu, NIE build-arg (APP CONFIRM). ──
log "build $APP_IMAGE (NEXT_PUBLIC_DEPLOYMENT_MODE=dedicated inline)"
docker build \
  --build-arg NEXT_PUBLIC_DEPLOYMENT_MODE=dedicated \
  -t "$APP_IMAGE" \
  "$APP_SRC"

# ── 2. dwg-converter (kontekst = docker/dwg-converter/; APP CONFIRM) ─
if [ -f "$APP_SRC/docker/dwg-converter/Dockerfile" ]; then
  log "build $DWG_IMAGE"
  docker build -t "$DWG_IMAGE" "$APP_SRC/docker/dwg-converter"
else
  die "brak $APP_SRC/docker/dwg-converter/Dockerfile"
fi

# ── 2b. office-converter (LibreOffice → PDF; kontekst = docker/office-converter/) ─
#      UWAGA: obraz ~1.5 GB — bundle rośnie o tyle w images.tar.
#      TODO APP: deploy/dedicated/docker-compose.dedicated.yml nie ma jeszcze
#      serwisu office-converter ani OFFICE_CONVERTER_URL — dopóki go nie doda,
#      obraz jedzie w bundlu, ale dedyk go nie uruchomi.
if [ -f "$APP_SRC/docker/office-converter/Dockerfile" ]; then
  log "build $OFFICE_IMAGE"
  docker build -t "$OFFICE_IMAGE" "$APP_SRC/docker/office-converter"
else
  die "brak $APP_SRC/docker/office-converter/Dockerfile"
fi

# ── 3. Pull obrazów bazowych (dla air-gap = zapisane w images.tar) ─
log "pull obrazów bazowych"
for img in "$PG_IMAGE" "$REDIS_IMAGE" "$MINIO_IMAGE"; do
  docker pull "$img"
done

# ── 4. docker save wszystkiego → images.tar ────────────────────────
log "docker save → images.tar"
# shellcheck disable=SC2086
docker save $APP_IMAGE $DWG_IMAGE $OFFICE_IMAGE "$PG_IMAGE" "$REDIS_IMAGE" "$MINIO_IMAGE" \
  -o "$OUT/images.tar"

# ── 5. Compose + env-template z repo APP (ścieżki APP CONFIRM) ─────
log "compose + env-template (deploy/dedicated/ od APP)"
DD="$APP_SRC/deploy/dedicated"
[ -f "$DD/docker-compose.dedicated.yml" ] || die "brak $DD/docker-compose.dedicated.yml"
[ -f "$DD/.env.dedicated.template" ] || die "brak $DD/.env.dedicated.template (DOTFILE!)"
cp "$DD/docker-compose.dedicated.yml" "$OUT/compose.dedicated.yml"
cp "$DD/.env.dedicated.template" "$OUT/env.template"   # dotfile → env.template (nazwa deploy-app)
# scripts/{bootstrap-instance,apply-license}.ts są W OBRAZIE app (exec npx tsx),
# nie kopiujemy osobno — deploy-app woła `compose exec app npx tsx ...`.

# ── 6. MANIFEST + (opcja) podpis update-manifest-ed25519 ───────────
log "manifest"
{
  echo "barvea-release-bundle"
  echo "version=$VERSION"
  echo "buildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  echo "deploymentMode=dedicated"
  echo "images=$APP_IMAGE $DWG_IMAGE $OFFICE_IMAGE $PG_IMAGE $REDIS_IMAGE $MINIO_IMAGE"
  echo "sha256(images.tar)=$(sha256sum "$OUT/images.tar" | cut -d' ' -f1)"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"

if [ "${SIGN:-0}" = 1 ]; then
  # Podpis manifestu = W CAŁOŚCI NASZE (APP CONFIRM (d): APP NIE ma updatera,
  # nie weryfikuje żadnego manifestu). Podpis I weryfikacja = nasz bundle-
  # -updater (do napisania). update-manifest-ed25519 = SIGN-helper (ten sam
  # klucz co auto-update WPF BarveaDrive). Format = jak licencja (payload
  # b64url + ed25519 po bajtach ASCII segmentu) — nasz updater sprawdzi też
  # buildDate vs licencja.updatesUntil. Wymaga VAULT_ADDR+VAULT_TOKEN.
  IN=$(base64 -w0 "$OUT/MANIFEST.txt")
  SIG=$(curl -fsS --cacert "${VAULT_CACERT:-/opt/vault/tls/tls.crt}" \
    -H "X-Vault-Token: $VAULT_TOKEN" --data "{\"input\":\"$IN\"}" \
    "$VAULT_ADDR/v1/transit/sign/update-manifest-ed25519" \
    | grep -oP '(?<="signature":")[^"]+')
  echo "$SIG" > "$OUT/MANIFEST.sig"
  echo "  podpisano (update-manifest-ed25519) — weryfikacja: nasz updater"
fi

log "DONE → $OUT (images.tar + compose + env.template + MANIFEST)"
echo "  Dalej: wrzuć bundle/ do nośnika air-gap (build-offline-assets.sh) albo"
echo "  podaj BUNDLE_DIR=$OUT dla deploy-app.dedicated.sh."
