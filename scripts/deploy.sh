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
echo "Previous: $PREVIOUS_SHA"
echo "New:      $NEW_SHA"

if [[ "$PREVIOUS_SHA" == "$NEW_SHA" ]]; then
  echo "No new commits. Skipping rebuild."
  exit 0
fi

# ─── 2. Build new image ───
echo ">>> Building image..."
docker compose --env-file .env.production build app

# ─── 3. Run migrations ───
# Prisma CLI is installed at /opt/prisma-cli inside the runtime image (see
# the app Dockerfile) and symlinked to /usr/local/bin/prisma. Calling the
# binary directly avoids npx's "fall through to npm registry" path that
# could otherwise pull Prisma 7 and crash on the v6 schema.
echo ">>> Running prisma migrate deploy..."
docker compose --env-file .env.production run --rm app prisma migrate deploy

# ─── 4. Recreate app ───
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
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" https://barvea.com/api/health)
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "FAIL: /api/health returned $HTTP_CODE"
  exit 1
fi
echo "OK: /api/health returned 200"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Deploy complete: $PREVIOUS_SHA → $NEW_SHA"
echo "Backup retained: $BACKUP_DIR"
echo "═══════════════════════════════════════════════════════════════"
