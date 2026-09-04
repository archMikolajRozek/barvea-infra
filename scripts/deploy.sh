#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# BARVEA — update workflow on barvea-app VM
# ═══════════════════════════════════════════════════════════════
# Run after each release (git tag or main branch update).
#
# Steps:
#   1. Pull latest code
#   2. Rebuild image
#   3. Run new migrations
#   4. Recreate app container with zero downtime via rolling update
#   5. Verify health

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

APP_DIR="$INFRA_DIR/app"

if [[ ! -f .env.production ]]; then
  echo "ERROR: .env.production missing"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env.production
set +a

# ─── Pre-flight: required env vars ───
# Fail-early before any irreversible step (backup / git pull / migrate).
REQUIRED_ENV=(DATABASE_URL APP_REPO_BRANCH)
MISSING=()
for var in "${REQUIRED_ENV[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    MISSING+=("$var")
  fi
done
# NextAuth v5 reads AUTH_SECRET; v4 used NEXTAUTH_SECRET. Accept either.
if [[ -z "${AUTH_SECRET:-}" && -z "${NEXTAUTH_SECRET:-}" ]]; then
  MISSING+=("AUTH_SECRET (or NEXTAUTH_SECRET legacy)")
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required env vars in .env.production: ${MISSING[*]}"
  exit 1
fi

# ─── Pre-deploy backup ───
echo ">>> Creating pre-deploy backup..."
BACKUP_DIR="$INFRA_DIR/backups/$(date +%Y%m%d_%H%M%S)_pre_deploy"
mkdir -p "$BACKUP_DIR"

# pg_dump rejects Prisma-style query params (?schema=public&connection_limit=...).
# Strip everything from the first `?` onwards before passing to pg_dump.
PGURL="$(printf '%s' "$DATABASE_URL" | cut -d'?' -f1)"

BACKUP_FILE="$BACKUP_DIR/pre_deploy.pgcustom"
if ! docker run --rm --network host postgres:18-alpine \
    pg_dump "$PGURL" --format=custom --no-owner > "$BACKUP_FILE"; then
  echo "ERROR: pg_dump failed. Aborting before code/migration changes."
  rm -f "$BACKUP_FILE"
  exit 1
fi
if [[ ! -s "$BACKUP_FILE" ]]; then
  echo "ERROR: backup file is empty ($BACKUP_FILE). Aborting."
  rm -f "$BACKUP_FILE"
  exit 1
fi
echo "Backup: $BACKUP_FILE ($(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE") bytes)"

# ─── 1. Pull latest ───
echo ">>> Pulling latest from $APP_REPO_BRANCH..."
git -C "$APP_DIR" fetch origin
PREVIOUS_SHA=$(git -C "$APP_DIR" rev-parse HEAD)
git -C "$APP_DIR" checkout "$APP_REPO_BRANCH"
git -C "$APP_DIR" pull --ff-only origin "$APP_REPO_BRANCH"
NEW_SHA=$(git -C "$APP_DIR" rev-parse HEAD)

# Skip-check przeciw PLIKOWI STANU, nie przeciw HEAD sprzed pulla.
# Stan zapisujemy dopiero PO udanym smoke tescie, wiec przerwany deploy
# (np. build padl na sieci do Docker Huba) NIE zostawia "No new commits" —
# ponowne odpalenie deploy.sh po prostu dokancza robote. Wczesniejsza wersja
# porownywala HEAD pre/post-pull: po wywalce pull byl juz zrobiony i skrypt
# przy retry klamal, ze nie ma nic do zrobienia (2026-09-02).
STATE_FILE="$INFRA_DIR/.last-deployed-sha"
LAST_DEPLOYED=$(cat "$STATE_FILE" 2>/dev/null || echo "none")
echo "Last deployed: $LAST_DEPLOYED"
echo "New:           $NEW_SHA"

if [[ "$LAST_DEPLOYED" == "$NEW_SHA" ]]; then
  echo "No changes since last successful deploy. Nothing to do."
  exit 0
fi

# ─── 2. Build new images ───
echo ">>> Building app image..."
docker compose --env-file .env.production build app

# Konwertery: build NIE-fatalny. To uslugi poboczne — chwilowo niedostepny
# Docker Hub (TLS timeout na metadanych ubuntu:24.04, 2026-09-02) nie moze
# blokowac deployu aplikacji. Przy faili: stare kontenery jada dalej,
# wypisujemy ostrzezenie i pomijamy recreate tej uslugi.
# Recreate tylko przy ZMIANIE obrazu — bez zmian nie ma po co ubijac
# kontenera (zimny start dwg-converter generowal falszywe alerty health).
img_id() { docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || echo "none"; }

CONVERTER_RECREATE=()
CONVERTER_FAILED=()
for svc in dwg-converter office-converter point-cloud-preview; do
  BEFORE_ID=$(img_id "barvea-$svc:latest")
  echo ">>> Building $svc image..."
  if docker compose --env-file .env.production build "$svc"; then
    AFTER_ID=$(img_id "barvea-$svc:latest")
    if [[ "$AFTER_ID" != "$BEFORE_ID" ]]; then
      CONVERTER_RECREATE+=("$svc")
    else
      echo "$svc: image unchanged — skipping recreate (no cold start)"
    fi
  else
    CONVERTER_FAILED+=("$svc")
    echo "WARN: $svc build FAILED — old container keeps running; retry deploy later"
  fi
done

# ─── 3. Run migrations ───
# Prisma CLI is installed at /opt/prisma-cli inside the runtime image (see
# the app Dockerfile) and symlinked to /usr/local/bin/prisma. Calling the
# binary directly avoids npx's "fall through to npm registry" path that
# could otherwise pull Prisma 7 and crash on the v6 schema.
echo ">>> Running prisma migrate deploy..."
docker compose --env-file .env.production run --rm app prisma migrate deploy

# ─── 4. Recreate containers ───
for svc in "${CONVERTER_RECREATE[@]}"; do
  echo ">>> Recreating $svc container (image changed)..."
  docker compose --env-file .env.production up -d --no-deps --force-recreate "$svc"
done
echo ">>> Recreating app container..."
docker compose --env-file .env.production up -d --no-deps --force-recreate app

# ─── 5. Wait for health ───
echo ">>> Waiting for healthcheck (up to 2 min)..."
for i in {1..24}; do
  if docker compose ps app | grep -q "healthy"; then
    echo "App: healthy"
    break
  fi
  sleep 5
  if [[ $i -eq 24 ]]; then
    echo "FAIL: app did not become healthy. Recent logs:"
    docker compose logs --tail 50 app
    echo ""
    echo "ROLLBACK suggested:"
    echo "  git -C $APP_DIR reset --hard $PREVIOUS_SHA"
    echo "  docker compose --env-file .env.production build app"
    echo "  docker compose --env-file .env.production up -d --no-deps app"
    echo "  # If migration broke DB:"
    echo "  docker run --rm --network host postgres:18-alpine pg_restore -d \"\$DATABASE_URL\" --clean --if-exists $BACKUP_DIR/pre_deploy.pgcustom"
    exit 1
  fi
done

# ─── 6. Smoke test ───
echo ">>> Smoke test..."
sleep 3
# app.barvea.com od cutover 2026-07-28 (barvea.com = CMS biura, zwraca 301)
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" https://app.barvea.com/api/health)
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "FAIL: /api/health returned $HTTP_CODE"
  exit 1
fi
echo "OK: /api/health returned 200"

# Stan zapisywany DOPIERO tutaj — po healthchecku i smoke tescie, i TYLKO
# gdy komplet buildow przeszedl. Kazde wczesniejsze wyjscie oraz fail
# konwertera zostawia stary SHA w pliku, wiec ponowny deploy.sh widzi
# roznice i dokancza (build appki wtedy leci z cache w sekundy).
if [[ ${#CONVERTER_FAILED[@]} -eq 0 ]]; then
  echo "$NEW_SHA" > "$STATE_FILE"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Deploy complete: $PREVIOUS_SHA → $NEW_SHA"
echo "Backup retained: $BACKUP_DIR"
if [[ ${#CONVERTER_FAILED[@]} -gt 0 ]]; then
  echo "⚠️  UWAGA: build padl dla: ${CONVERTER_FAILED[*]} — stare kontenery"
  echo "   dzialaja dalej. Odpal deploy.sh ponownie, gdy Docker Hub wroci"
  echo "   (stan NIE zostal oznaczony jako pelny — retry przebuduje)."
fi
echo "═══════════════════════════════════════════════════════════════"
