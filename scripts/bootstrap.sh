#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# BARVEA — first-time bootstrap on barvea-app VM (10.10.0.30)
# ═══════════════════════════════════════════════════════════════
# Run ONCE on a fresh VM after:
#   - Docker + compose plugin installed
#   - barvea-data VM is up with Postgres/Redis/MinIO accessible from 10.10.0.30
#   - DNS for barvea.com points to public IP (DNAT'd to this VM)
#   - .env.production exists and is filled (chmod 600)
#
# What it does:
#   1. Sanity-checks barvea-data connectivity
#   2. Clones the app repo into ./app
#   3. Builds the Docker image
#   4. Verifies DB extensions are installed
#   5. Runs prisma migrate deploy
#   6. Creates MinIO buckets if missing (using mc client)
#   7. Starts compose stack
#   8. Waits for healthcheck + Caddy cert issuance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

if [[ ! -f .env.production ]]; then
  echo "ERROR: .env.production missing. Copy from .env.production.example and fill secrets."
  exit 1
fi

# Load env (export each line)
set -a
# shellcheck disable=SC1091
source .env.production
set +a

DATA_VM_IP=10.10.0.20
APP_DIR="$INFRA_DIR/app"

# ─── 1. Connectivity to barvea-data ───
echo ">>> [1/8] Checking connectivity to barvea-data ($DATA_VM_IP)..."
nc -zv $DATA_VM_IP 5432 || { echo "FAIL: cannot reach Postgres at $DATA_VM_IP:5432"; exit 1; }
nc -zv $DATA_VM_IP 6379 || { echo "FAIL: cannot reach Redis at $DATA_VM_IP:6379"; exit 1; }
nc -zv $DATA_VM_IP 9000 || { echo "FAIL: cannot reach MinIO at $DATA_VM_IP:9000"; exit 1; }
echo "OK: all 3 services reachable"

# ─── 2. Clone app repo ───
if [[ ! -d "$APP_DIR/.git" ]]; then
  echo ">>> [2/8] Cloning app repo from $APP_REPO_URL (branch $APP_REPO_BRANCH)..."
  git clone --branch "$APP_REPO_BRANCH" "$APP_REPO_URL" "$APP_DIR"
else
  echo ">>> [2/8] App repo already cloned, fetching latest..."
  git -C "$APP_DIR" fetch origin
  git -C "$APP_DIR" checkout "$APP_REPO_BRANCH"
  git -C "$APP_DIR" pull --ff-only origin "$APP_REPO_BRANCH"
fi

# ─── 3. Build image ───
echo ">>> [3/8] Building Docker image..."
docker compose --env-file .env.production build app

# ─── 4. Verify DB extensions ───
echo ">>> [4/8] Verifying DB extensions on barvea-data..."
REQUIRED_EXT=(postgis postgis_topology pg_trgm pgcrypto "uuid-ossp")
MISSING_EXT=()
for ext in "${REQUIRED_EXT[@]}"; do
  if ! PGPASSWORD="${DATABASE_URL##*:}" PGPASSWORD=$(echo "$DATABASE_URL" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|') \
       psql "$DATABASE_URL" -tAc "SELECT 1 FROM pg_extension WHERE extname='$ext'" 2>/dev/null | grep -q 1; then
    MISSING_EXT+=("$ext")
  fi
done
if [[ ${#MISSING_EXT[@]} -gt 0 ]]; then
  echo "WARNING: missing extensions on barvea-data: ${MISSING_EXT[*]}"
  echo "Connect to barvea-data and run as superuser:"
  for ext in "${MISSING_EXT[@]}"; do
    echo "  CREATE EXTENSION IF NOT EXISTS \"$ext\";"
  done
  read -rp "Continue anyway? (y/N) " yn
  [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

# ─── 5. Prisma migrate deploy ───
# The runtime image installs prisma@6.19.2 as a runtime dep (Dockerfile RUN
# `npm install --no-save --omit=dev prisma@6.19.2`), so npx resolves the
# local CLI from node_modules/.bin/ — no PATH workarounds needed and no
# accidental fetch of Prisma 7 from the npm registry.
echo ">>> [5/8] Running prisma migrate deploy..."
docker compose --env-file .env.production run --rm app npx prisma migrate deploy

# ─── 6. MinIO buckets ───
echo ">>> [6/8] Ensuring MinIO buckets exist..."
docker run --rm --network host \
  -e MC_HOST_local="http://${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}@${MINIO_ENDPOINT}:${MINIO_PORT}" \
  minio/mc:latest sh -c "
    for b in $MINIO_BUCKET_IFC $MINIO_BUCKET_DOCS $MINIO_BUCKET_ASSETS $MINIO_BUCKET_QR $MINIO_BUCKET_REPORTS; do
      if ! mc ls local/\$b >/dev/null 2>&1; then
        echo 'Creating bucket: '\$b
        mc mb local/\$b
        mc version enable local/\$b
        mc anonymous set none local/\$b
      else
        echo 'Bucket exists: '\$b
      fi
    done
  "

# ─── 7. Start stack ───
echo ">>> [7/8] Starting docker compose stack..."
docker compose --env-file .env.production up -d

# ─── 8. Wait for health + cert ───
echo ">>> [8/8] Waiting for app healthcheck + Caddy cert (up to 3 min)..."
for i in {1..36}; do
  if docker compose ps app | grep -q "healthy"; then
    echo "App: healthy"
    break
  fi
  sleep 5
done

echo "Tailing Caddy logs for 30s — watch for 'certificate obtained successfully'..."
timeout 30 docker compose logs -f caddy || true

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Bootstrap complete. Verify:"
echo "  curl -I https://barvea.com"
echo "  curl https://barvea.com/api/health"
echo "═══════════════════════════════════════════════════════════════"
