#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# BARVEA — verify connectivity + state of barvea-data (10.10.0.20)
# ═══════════════════════════════════════════════════════════════
# Run on barvea-app to sanity-check Postgres, Redis, MinIO before deploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

if [[ ! -f .env.production ]]; then
  echo "ERROR: .env.production missing"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env.production
set +a

DATA_VM=10.10.0.20
FAIL=0

# psql chokes on Prisma-style query params (?schema=public&connection_limit=…).
# Strip everything after the first `?` so libpq parses the URL cleanly.
# Same pattern used in deploy.sh.
PGURL="$(printf '%s' "$DATABASE_URL" | cut -d'?' -f1)"

echo "═══════════════════════════════════════════════════════════════"
echo "BARVEA data-layer connectivity check (barvea-data $DATA_VM)"
echo "═══════════════════════════════════════════════════════════════"

# ─── Network ping ───
echo -n "Ping $DATA_VM ... "
if ping -c 2 -W 2 $DATA_VM >/dev/null 2>&1; then echo OK; else echo FAIL; FAIL=1; fi

# ─── Postgres ───
echo -n "TCP $DATA_VM:5432 (Postgres) ... "
if nc -zv $DATA_VM 5432 >/dev/null 2>&1; then echo OK; else echo FAIL; FAIL=1; fi

echo -n "Postgres login (barvea_app) ... "
if docker run --rm --network host postgres:18-alpine \
   psql "$PGURL" -tAc "SELECT 1" >/dev/null 2>&1; then
  echo OK
else
  echo FAIL
  FAIL=1
fi

echo -n "Postgres extensions ... "
EXT_OUT=$(docker run --rm --network host postgres:18-alpine \
   psql "$PGURL" -tAc "SELECT extname FROM pg_extension ORDER BY extname" 2>/dev/null || echo ERR)
if echo "$EXT_OUT" | grep -q postgis; then
  echo "OK (installed: $(echo "$EXT_OUT" | tr '\n' ',' | sed 's/,$//'))"
else
  echo "MISSING postgis. Run as superuser on barvea-data:"
  echo "  CREATE EXTENSION IF NOT EXISTS postgis;"
  echo "  CREATE EXTENSION IF NOT EXISTS postgis_topology;"
  echo "  CREATE EXTENSION IF NOT EXISTS pg_trgm;"
  echo "  CREATE EXTENSION IF NOT EXISTS pgcrypto;"
  echo "  CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
  FAIL=1
fi

# ─── Redis ───
echo -n "TCP $DATA_VM:6379 (Redis) ... "
if nc -zv $DATA_VM 6379 >/dev/null 2>&1; then echo OK; else echo FAIL; FAIL=1; fi

echo -n "Redis ping (with auth) ... "
REDIS_PASS=$(echo "$REDIS_URL" | sed -E 's|.*://[^:]*:([^@]+)@.*|\1|')
if docker run --rm --network host redis:7-alpine \
   redis-cli -h $DATA_VM -p 6379 -a "$REDIS_PASS" PING 2>/dev/null | grep -q PONG; then
  echo OK
else
  echo FAIL
  FAIL=1
fi

# ─── MinIO ───
echo -n "TCP $DATA_VM:9000 (MinIO) ... "
if nc -zv $DATA_VM 9000 >/dev/null 2>&1; then echo OK; else echo FAIL; FAIL=1; fi

echo -n "MinIO health ... "
HC=$(curl -sk -o /dev/null -w "%{http_code}" "http://$DATA_VM:9000/minio/health/live" || echo ERR)
if [[ "$HC" == "200" ]]; then echo "OK ($HC)"; else echo "FAIL ($HC)"; FAIL=1; fi

echo -n "MinIO buckets exist ... "
BUCKETS=("$MINIO_BUCKET_IFC" "$MINIO_BUCKET_DOCS" "$MINIO_BUCKET_ASSETS" "$MINIO_BUCKET_QR" "$MINIO_BUCKET_REPORTS")
MISSING=()
for b in "${BUCKETS[@]}"; do
  if ! docker run --rm --network host \
       -e MC_HOST_local="http://${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}@${MINIO_ENDPOINT}:${MINIO_PORT}" \
       minio/mc:latest ls "local/$b" >/dev/null 2>&1; then
    MISSING+=("$b")
  fi
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo "OK (all 5 buckets present)"
else
  echo "MISSING: ${MISSING[*]}"
  FAIL=1
fi

echo "═══════════════════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
  echo "All checks PASSED. Ready to deploy."
  exit 0
else
  echo "Some checks FAILED. Fix above before running bootstrap.sh / deploy.sh."
  exit 1
fi
