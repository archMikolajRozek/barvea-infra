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

# CONFIRM(APP): pin obrazów bazowych (APP: postgres:18 [K2], redis:7-alpine,
# minio:<pin z prod: docker images|grep minio>). dwg-converter = build z repo.
PG_IMAGE="${PG_IMAGE:-postgres:18}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
MINIO_IMAGE="${MINIO_IMAGE:-minio/minio:RELEASE.2025-01-01T00-00-00Z}"  # CONFIRM(APP) realny pin
APP_IMAGE="barvea-app:$VERSION"
DWG_IMAGE="barvea-dwg-converter:$VERSION"

log() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
command -v docker >/dev/null || die "docker wymagany"
[ -d "$APP_SRC" ] || die "brak APP_SRC: $APP_SRC"
mkdir -p "$OUT"

# ── 1. Build obrazu app (NEXT_PUBLIC w BUILD-ARG — krytyczne!) ──────
log "build $APP_IMAGE (NEXT_PUBLIC_DEPLOYMENT_MODE=dedicated inline)"
# CONFIRM(APP): ścieżka Dockerfile aplikacji (zakładam $APP_SRC z Dockerfile).
docker build \
  --build-arg NEXT_PUBLIC_DEPLOYMENT_MODE=dedicated \
  --build-arg BARVEA_VERSION="$VERSION" \
  -t "$APP_IMAGE" \
  "$APP_SRC"

# ── 2. dwg-converter (osobny kontener; CONFIRM ścieżka) ────────────
if [ -d "$APP_SRC/docker/dwg-converter" ]; then
  log "build $DWG_IMAGE"
  docker build -t "$DWG_IMAGE" "$APP_SRC/docker/dwg-converter"   # CONFIRM(APP) ścieżka
else
  echo "  ⚠️ brak docker/dwg-converter w źródłach — pomijam (CONFIRM z APP)"
  DWG_IMAGE=""
fi

# ── 3. Pull obrazów bazowych (dla air-gap = zapisane w images.tar) ─
log "pull obrazów bazowych"
for img in "$PG_IMAGE" "$REDIS_IMAGE" "$MINIO_IMAGE"; do
  docker pull "$img"
done

# ── 4. docker save wszystkiego → images.tar ────────────────────────
log "docker save → images.tar"
# shellcheck disable=SC2086
docker save $APP_IMAGE $DWG_IMAGE "$PG_IMAGE" "$REDIS_IMAGE" "$MINIO_IMAGE" \
  -o "$OUT/images.tar"

# ── 5. Compose + env-template + scripts z repo APP ─────────────────
log "compose + env-template + scripts (deploy/dedicated/ od APP)"
DD="$APP_SRC/deploy/dedicated"   # CONFIRM(APP): to ścieżka z ich #4
if [ -d "$DD" ]; then
  cp "$DD/compose.dedicated.yml" "$OUT/" 2>/dev/null || \
    cp "$DD"/compose*.yml "$OUT/compose.dedicated.yml"
  cp "$DD/env.template" "$OUT/" 2>/dev/null || cp "$DD"/*.env.template "$OUT/env.template"
else
  echo "  ⚠️ brak $DD — skopiuj compose.dedicated.yml + env.template ręcznie (CONFIRM z APP)"
fi
# scripts/{bootstrap-instance,apply-license}.ts są W OBRAZIE app (exec npx tsx),
# nie kopiujemy osobno — deploy-app woła je przez `compose exec app npx tsx ...`.

# ── 6. MANIFEST + (opcja) podpis update-manifest-ed25519 ───────────
log "manifest"
{
  echo "barvea-release-bundle"
  echo "version=$VERSION"
  echo "buildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  echo "deploymentMode=dedicated"
  echo "images=$APP_IMAGE $DWG_IMAGE $PG_IMAGE $REDIS_IMAGE $MINIO_IMAGE"
  echo "sha256(images.tar)=$(sha256sum "$OUT/images.tar" | cut -d' ' -f1)"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"

if [ "${SIGN:-0}" = 1 ]; then
  # podpis manifestu przez Vault transit update-manifest-ed25519 (updater
  # klienta weryfikuje + sprawdza buildDate vs licencja.updatesUntil).
  # Wymaga VAULT_ADDR+VAULT_TOKEN. CONFIRM format z APP (updater).
  IN=$(base64 -w0 "$OUT/MANIFEST.txt")
  SIG=$(curl -fsSk -H "X-Vault-Token: $VAULT_TOKEN" \
    --data "{\"input\":\"$IN\"}" \
    "$VAULT_ADDR/v1/transit/sign/update-manifest-ed25519" \
    | grep -oP '(?<="signature":")[^"]+')
  echo "$SIG" > "$OUT/MANIFEST.sig"
  echo "  podpisano (update-manifest-ed25519)"
fi

log "DONE → $OUT (images.tar + compose + env.template + MANIFEST)"
echo "  Dalej: wrzuć bundle/ do nośnika air-gap (build-offline-assets.sh) albo"
echo "  podaj BUNDLE_DIR=$OUT dla deploy-app.dedicated.sh."
