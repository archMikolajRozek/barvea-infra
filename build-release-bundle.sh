#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — build-release-bundle.sh v2: buduje PODPISANĄ paczkę wydania
# instalacji dedykowanej (D4, plan INSTALATOR-PLAN-2026-11.md).
#
# Uruchamiać U NAS, na barvea-app (VM 102): Docker + checkout repo APP +
# ~/barvea/.env.production (AppRole Vault do podpisu). Klient dostaje
# gotowy katalog paczki — nie ma dostępu do naszych repo ani Vaulta.
#
# Wynik (OUT):
#   images.tar              wszystkie obrazy (app + sidecary + bazowe) — docker save
#   compose.dedicated.yml   = APP deploy/dedicated/docker-compose.dedicated.yml
#   env.template            = APP deploy/dedicated/.env.dedicated.template
#   MANIFEST.json/.sig/.pub.pem  podpis Ed25519 (APP scripts/sign-release-manifest.ts, Vault transit)
#   SHA256SUMS              sumy wszystkich plików paczki (kontrola transportu)
#
# Kontrakt z deploy-app.dedicated.sh v2: MANIFEST.json kanoniczny (klucze
# posortowane), podpis nad jego bajtami, klucz publiczny = installer/update-manifest.pub.pem.
# Weryfikacja u klienta: openssl pkeyutl -verify -pubin -inkey pub.pem -rawin -in MANIFEST.json -sigfile <(base64 -d MANIFEST.sig)
#
# Użycie: ./build-release-bundle.sh <APP_SRC_DIR> <VERSION> [OUT]
#   APP_SRC_DIR  checkout repo aplikacji (np. ~/barvea/app)
#   VERSION      tag obrazów i paczki, np. 2026.11.25
#   OUT          katalog paczki (domyślnie ./barvea-bundle-<VERSION>)
# Zmienne: SIGN=0 (paczka bez podpisu — TYLKO testy; deploy-app odmówi bez ALLOW_UNSIGNED=1),
#          ENV_FILE=~/barvea/.env.production (AppRole do podpisu), MINIO_IMAGE=minio/minio:<pin>,
#          CLAMAV_IMAGE=clamav/clamav:<tag>, BUNDLE_PROFILES="pointcloud,collab,ifc,compact,av"
#          (które moduły pakować; rdzeń zawsze), NO_CACHE=1 (docker build --no-cache).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
APP_SRC="${1:?podaj katalog źródeł aplikacji (checkout repo APP)}"
VERSION="${2:?podaj wersję, np. 2026.11.25}"
OUT="${3:-./barvea-bundle-$VERSION}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$HOME/barvea/.env.production}"
SIGN="${SIGN:-1}"
BUNDLE_PROFILES="${BUNDLE_PROFILES:-pointcloud,collab,ifc,compact,av}"
INSTALLER_VERSION="$(tr -d '[:space:]' < "$REPO_DIR/INSTALLER_VERSION")"

# Obrazy bazowe — piny. MinIO: pin z proda (żywy kontener barvea-minio na starym
# prodzie albo MINIO_IMAGE=); natywny MinIO prod = RELEASE.2025-09-07T16-13-09Z.
PG_IMAGE="${PG_IMAGE:-postgres:18}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
# (prod ma MinIO natywnie — brak kontenera; docker inspect zostawiał pustą linię → „invalid reference format” 25.11)
MINIO_IMAGE="${MINIO_IMAGE:-$( (docker inspect barvea-minio --format '{{.Config.Image}}' 2>/dev/null || true) | tr -d '[:space:]')}"
[ -n "$MINIO_IMAGE" ] || MINIO_IMAGE="quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"   # Docker Hub minio/minio już nie istnieje (26.11)
CLAMAV_IMAGE="${CLAMAV_IMAGE:-clamav/clamav:stable}"   # tag bez _base = obraz Z bazą sygnatur (air-gap OK)

log() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
has_profile() { case ",$BUNDLE_PROFILES," in *",$1,"*) return 0;; *) return 1;; esac; }
command -v docker  >/dev/null || die "docker wymagany"
command -v python3 >/dev/null || die "python3 wymagany (manifest-input.json)"
command -v sha256sum >/dev/null || die "sha256sum wymagany"
[ -d "$APP_SRC" ] || die "brak APP_SRC: $APP_SRC"
[ -f "$APP_SRC/Dockerfile" ] || die "brak $APP_SRC/Dockerfile (root repo app)"
DD="$APP_SRC/deploy/dedicated"
[ -f "$DD/docker-compose.dedicated.yml" ] || die "brak $DD/docker-compose.dedicated.yml"
[ -f "$DD/.env.dedicated.template" ]     || die "brak $DD/.env.dedicated.template (dotfile!)"
if [ "$SIGN" = 1 ]; then
  [ -f "$ENV_FILE" ] || die "brak $ENV_FILE (AppRole Vault do podpisu) — albo SIGN=0 (paczka testowa)"
  grep -qE '^VAULT_APPROLE_ROLE_ID=' "$ENV_FILE" || die "$ENV_FILE bez VAULT_APPROLE_ROLE_ID — podpis niemożliwy"
fi
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
APP_COMMIT="$(git -C "$APP_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
[ -z "$(git -C "$APP_SRC" status --porcelain 2>/dev/null)" ] || echo "⚠️  APP_SRC ma niezacommitowane zmiany — appCommit=$APP_COMMIT nie opisuje dokładnie paczki"
BUILD_OPTS=(); [ "${NO_CACHE:-0}" = 1 ] && BUILD_OPTS+=(--no-cache)

# ── 1. Obrazy barvea-* (rdzeń zawsze; moduły wg BUNDLE_PROFILES) ───
# VERSION = TAG obrazu (nie build-arg). app: TYLKO build-arg
# NEXT_PUBLIC_DEPLOYMENT_MODE=dedicated (Next inline'uje NEXT_PUBLIC w build).
declare -a SERVICES=() IMAGES=()
build() { # build <service> <image> <dockerfile> <context> [build-args...]
  local svc="$1" img="$2:$VERSION" df="$3" ctx="$4"; shift 4
  [ -f "$df" ] || die "brak $df"
  log "build $img ($svc)"
  docker build "${BUILD_OPTS[@]}" "$@" -f "$df" -t "$img" "$ctx"
  SERVICES+=("$svc"); IMAGES+=("$img")
}
build app              barvea-app                 "$APP_SRC/Dockerfile"                         "$APP_SRC" --build-arg NEXT_PUBLIC_DEPLOYMENT_MODE=dedicated
build dwg-converter    barvea-dwg-converter       "$APP_SRC/docker/dwg-converter/Dockerfile"    "$APP_SRC/docker/dwg-converter"
build office-converter barvea-office-converter    "$APP_SRC/docker/office-converter/Dockerfile" "$APP_SRC/docker/office-converter"
has_profile pointcloud && build point-cloud-preview barvea-point-cloud-preview "$APP_SRC/docker/point-cloud-preview/Dockerfile" "$APP_SRC/docker/point-cloud-preview"
if has_profile ifc; then
  build ifc-clash     barvea-ifc-clash     "$APP_SRC/docker/ifc-clash/Dockerfile"     "$APP_SRC/docker/ifc-clash"
  build ifc-extractor barvea-ifc-extractor "$APP_SRC/docker/ifc-extractor/Dockerfile" "$APP_SRC/docker/ifc-extractor"
fi
has_profile collab && build collab barvea-collab "$APP_SRC/collab-server/Dockerfile" "$APP_SRC"   # kontekst = CAŁE repo

# ── 2. Obrazy bazowe (pull → w images.tar dla air-gap) ─────────────
pull() { local svc="$1" img="$2"; log "pull $img ($svc)"; docker pull -q "$img" >/dev/null; SERVICES+=("$svc"); IMAGES+=("$img"); }
pull caddy "$CADDY_IMAGE"
if has_profile compact; then
  pull postgres "$PG_IMAGE"; pull redis "$REDIS_IMAGE"
  # MinIO: pull z quay.io, ale compose dedyka woła `minio/minio:${MINIO_IMAGE_TAG}` → retag pod tę nazwę (air-gap: żadnego pulla)
  log "pull $MINIO_IMAGE (minio) → tag minio/minio:${MINIO_IMAGE##*:}"
  docker pull -q "$MINIO_IMAGE" >/dev/null; docker tag "$MINIO_IMAGE" "minio/minio:${MINIO_IMAGE##*:}"
  SERVICES+=(minio); IMAGES+=("minio/minio:${MINIO_IMAGE##*:}")
  has_profile av && pull clamav "$CLAMAV_IMAGE"
fi

# ── 3. docker save → images.tar ────────────────────────────────────
log "docker save ${#IMAGES[@]} obrazów → images.tar (chwilę potrwa)"
docker save "${IMAGES[@]}" -o "$OUT/images.tar"
TAR_SHA="$(sha256sum "$OUT/images.tar" | cut -d' ' -f1)"

# ── 4. Pliki paczki od APP ─────────────────────────────────────────
log "compose + env.template"
cp "$DD/docker-compose.dedicated.yml" "$OUT/compose.dedicated.yml"
cp "$DD/.env.dedicated.template"      "$OUT/env.template"
# Kontrola: szablon env nie może nieść wartości sekretów (czysty szablon)
if grep -E '^(NEXTAUTH_SECRET|TOTP_ENCRYPTION_KEY|DATABASE_URL|VAULT_APPROLE_SECRET_ID)=.+' "$OUT/env.template" >/dev/null; then
  die "env.template zawiera wartości sekretów — szablon musi być pusty w polach [GEN]/[INFRA]"
fi

# ── 5. manifest-input.json (kontrakt sign-release-manifest.ts) ─────
# images[]: service, image (repo bez tagu), tag, imageId=sha256:<64hex> (docker inspect .Id)
log "manifest-input.json"
MANIFEST_IMAGES=""
for i in "${!IMAGES[@]}"; do
  img="${IMAGES[$i]}"; id="$(docker inspect --format '{{.Id}}' "$img")"
  MANIFEST_IMAGES+="${SERVICES[$i]}|${img%:*}|${img##*:}|${id}"$'\n'
done
PROFILES_LIST="$(printf '%s' "$BUNDLE_PROFILES" | tr ',' '\n' | sed '/^$/d')"
MANIFEST_IMAGES="$MANIFEST_IMAGES" PROFILES_LIST="$PROFILES_LIST" \
python3 - "$OUT" "$VERSION" "$APP_COMMIT" "$INSTALLER_VERSION" "$TAR_SHA" <<'PY'
import datetime, hashlib, json, os, sys
out, version, commit, inst_ver, tar_sha = sys.argv[1:6]
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for c in iter(lambda: f.read(1 << 20), b''):
            h.update(c)
    return h.hexdigest()
images = []
for line in os.environ['MANIFEST_IMAGES'].splitlines():
    if line.strip():
        svc, image, tag, iid = line.split('|')
        images.append({'service': svc, 'image': image, 'tag': tag, 'imageId': iid})
files = [{'path': p, 'sha256': sha(f'{out}/{p}')} for p in ('compose.dedicated.yml', 'env.template')]
m = {
    'bundleVersion': version,
    'buildDate': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    'appCommit': commit,
    'deploymentMode': 'dedicated',
    'minInstallerVersion': inst_ver,
    'tarSha256': tar_sha,
    'profiles': [p for p in os.environ['PROFILES_LIST'].splitlines() if p],
    'images': images,
    'files': files,
}
with open(f'{out}/manifest-input.json', 'w', encoding='utf-8') as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
print(json.dumps({k: v for k, v in m.items() if k != 'images'}, ensure_ascii=False))
print('images:', ', '.join(f"{i['image']}:{i['tag']}" for i in images))
PY

# ── 6. Podpis (APP sign-release-manifest.ts w obrazie builder, AppRole z ENV_FILE) ─
# Obraz builder = ten sam wzorzec co skrypty diagnostyczne na prodzie (barvea-diag).
# docker --env-file NIE zdejmuje cudzysłowów → filtr sed jak w runbookach.
if [ "$SIGN" = 1 ]; then
  log "podpis MANIFEST (Vault transit update-manifest-ed25519)"
  docker build -q --target builder -t barvea-diag:latest "$APP_SRC" >/dev/null
  ENVF="$(mktemp)"; chmod 600 "$ENVF"
  grep -E '^(VAULT_ENDPOINT|VAULT_APPROLE_ROLE_ID|VAULT_APPROLE_SECRET_ID|VAULT_STRICT_SSL|VAULT_TOKEN)=' "$ENV_FILE" \
    | sed -E "s/^([A-Za-z_0-9]+)=[\"'](.*)[\"']\$/\1=\2/" > "$ENVF"
  docker run --rm --network host --env-file "$ENVF" -v "$OUT:/bundle" barvea-diag:latest \
    npx -y tsx scripts/sign-release-manifest.ts /bundle || { rm -f "$ENVF"; die "podpis nieudany — paczka NIEWAŻNA"; }
  rm -f "$ENVF"
  # klucz z paczki = klucz wbudowany w instalator (rotacja = nowy PEM w repo + bump INSTALLER_VERSION)
  if ! cmp -s "$OUT/MANIFEST.pub.pem" "$REPO_DIR/installer/update-manifest.pub.pem"; then
    die "MANIFEST.pub.pem ≠ installer/update-manifest.pub.pem — klucz Vault zrotowany? zaktualizuj repo + INSTALLER_VERSION"
  fi
  # niezależna weryfikacja openssl — dokładnie to, co zrobi deploy-app u klienta
  SIGBIN="$(mktemp)"; base64 -d "$OUT/MANIFEST.sig" > "$SIGBIN"
  openssl pkeyutl -verify -pubin -inkey "$REPO_DIR/installer/update-manifest.pub.pem" -rawin -in "$OUT/MANIFEST.json" -sigfile "$SIGBIN" >/dev/null \
    || { rm -f "$SIGBIN"; die "openssl nie weryfikuje podpisu — paczka NIEWAŻNA"; }
  rm -f "$SIGBIN"; echo "  ✓ podpis zweryfikowany (openssl, klucz z repo)"
  rm -f "$OUT/manifest-input.json"   # MANIFEST.json = kanoniczne źródło; wejście zbędne
else
  echo "⚠️  SIGN=0 — paczka BEZ podpisu (tylko testy; deploy-app wymaga ALLOW_UNSIGNED=1)"
  mv "$OUT/manifest-input.json" "$OUT/MANIFEST.json"   # niepodpisany, nie-kanoniczny — tylko do odczytu wersji
fi

# ── 7. SHA256SUMS (kontrola transportu nośnika) ────────────────────
( cd "$OUT" && sha256sum images.tar compose.dedicated.yml env.template MANIFEST.* > SHA256SUMS )
log "DONE → $OUT"
du -sh "$OUT" | sed 's/^/  rozmiar: /'
echo "  Dalej: katalog na nośnik / do klienta → na hoście klienta: BUNDLE_DIR=<katalog> ./deploy-app.dedicated.sh"
echo "  Kontrola po przeniesieniu: (cd <katalog> && sha256sum -c SHA256SUMS)"
