# BARVEA — Infrastructure & Deployment

Production deployment configuration for `barvea.com` running on Hetzner SX65 / Proxmox VE.

**Stack:** Docker + Docker Compose · Next.js (Node 20, image from app repo) · Caddy 2 · auto Let's Encrypt

This repo holds **only configuration** — no application code. App code lives in:
- https://github.com/archMikolajRozek/barvea (cloned by `bootstrap.sh` into `./app`)

---

## Architecture

```
                    Internet (DNS: barvea.com → 178.63.205.222)
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  barvea-host (Hetzner SX65, Proxmox VE 8.4)                  │
│  Public IPv4: 178.63.205.222                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌────────────────┐   │
│  │ VM 100      │    │ VM 101      │    │ VM 102         │   │
│  │ barvea-infra│    │ barvea-data │    │ barvea-app     │◄──┼─ THIS REPO
│  │ 10.10.0.10  │    │ 10.10.0.20  │    │ 10.10.0.30     │   │
│  │             │    │             │    │                │   │
│  │ WireGuard   │    │ Postgres 18 │    │ Docker:        │   │
│  │ DNAT 80→app │───▶│ + PostGIS   │◄───│  - app (3005)  │   │
│  │ DNAT 443→app│    │ Redis 8     │◄───│  - caddy (80)  │   │
│  │             │    │ MinIO       │◄───│       (443)    │   │
│  └─────────────┘    └─────────────┘    └────────────────┘   │
│                                                               │
│  vmbr1 (private 10.10.0.0/24) — all VMs                      │
│  vmbr0 (public)               — only barvea-infra            │
└──────────────────────────────────────────────────────────────┘
```

**Public ports:** 80/TCP, 443/TCP, 51820/UDP (WireGuard), 2277/TCP (SSH)
**Admin access (Postgres UI, MinIO Console, Proxmox UI):** WireGuard only.

---

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | App container + Caddy reverse proxy. NO database/cache/storage — those live on VM 101. |
| `Caddyfile` | TLS termination, HSTS, upload routing (1 GB limit), `/api/webhooks/*` raw-body, `/api/health` exposed. |
| `.env.production.example` | Template for prod secrets. Copy, fill, chmod 600 — never commit. |
| `scripts/bootstrap.sh` | First-time deploy: connectivity check → clone app → build → migrate → MinIO buckets → start. |
| `scripts/deploy.sh` | Update workflow: pre-deploy backup → git pull → build → migrate deploy → recreate app. |
| `scripts/backup.sh` | Daily Postgres pg_dump (cron). Retention: 14d daily + Sunday weekly. |
| `scripts/verify-data-vm.sh` | Sanity check Postgres/Redis/MinIO connectivity + extensions + buckets. |

---

## First-time deploy

### Prerequisites on barvea-app (VM 102)

- Debian 13, Docker 29.4.1, docker compose plugin
- SSH key for GitHub deploy (`/root/.ssh/id_ed25519`) added to `archMikolajRozek/barvea` deploy keys (read-only)
- Reachable to `10.10.0.20` over `vmbr1`
- `nc` (netcat) installed: `apt install -y netcat-openbsd`

### Prerequisites on barvea-data (VM 101)

- PostgreSQL 18.3 listening on `10.10.0.20:5432`
  - DB `barvea`, user `barvea_app` with RW grants, scram-sha-256 password
  - Extensions: `postgis`, `postgis_topology`, `pg_trgm`, `pgcrypto`, `uuid-ossp`
- Redis 8.0.2 with `requirepass`, listening on `10.10.0.20:6379`
- MinIO listening on `10.10.0.20:9000`, with user `barvea_app_minio` and 5 buckets:
  `barvea-ifc`, `barvea-docs`, `barvea-assets`, `barvea-qr`, `barvea-reports`
  (each with versioning enabled, anonymous access disabled)

### Prerequisites — DNS

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | @ | `178.63.205.222` | 300 |
| A | www | `178.63.205.222` | 300 |
| CAA | @ | `0 issue "letsencrypt.org"` | 3600 |

### Steps

```bash
# On barvea-app (10.10.0.30):

# 1. Clone this infra repo into your home dir
git clone git@github.com:archMikolajRozek/barvea-infra.git ~/barvea
cd ~/barvea

# 2. Configure secrets
cp .env.production.example .env.production
chmod 600 .env.production
nano .env.production    # fill all __PLACEHOLDERS__

# 3. Verify data layer reachable
chmod +x scripts/*.sh
./scripts/verify-data-vm.sh
# Must end with "All checks PASSED"

# 4. FIRST-RUN ONLY — switch Caddy to staging Let's Encrypt to avoid rate-limit
# Edit Caddyfile, uncomment the line:
#   acme_ca https://acme-staging-v02.api.letsencrypt.org/directory

# 5. Bootstrap
./scripts/bootstrap.sh

# 6. Verify TLS staging works
curl -k https://barvea.com/api/health
# JSON {"status":"healthy",...}

# 7. Switch to production Let's Encrypt
# Comment out acme_ca line in Caddyfile
docker compose --env-file .env.production restart caddy

# 8. Verify real cert
curl https://barvea.com/api/health     # no -k, must succeed
```

---

## Update workflow

```bash
ssh -p 2277 miko@10.10.0.30
cd ~/barvea
git pull --ff-only origin main      # pull latest infra (deploy.sh, scripts)
ls -la scripts/                     # verify -rwxr-xr-x on *.sh
./scripts/deploy.sh
```

What it does:
1. Creates pre-deploy DB backup
2. `git pull` in `./app`
3. Rebuilds Docker image
4. `prisma migrate deploy`
5. Recreates app container
6. Waits for healthcheck
7. Smoke-tests `/api/health`

If healthcheck fails, script prints rollback instructions including DB restore from the pre-deploy backup.

---

## Rollback

If a deploy breaks production:

```bash
cd ~/barvea/app
git log --oneline -5                             # find previous good SHA
git reset --hard <previous-sha>
cd ..
docker compose --env-file .env.production build app
docker compose --env-file .env.production up -d --no-deps --force-recreate app

# If DB schema must also revert (broken migration):
docker run --rm --network host postgres:18-alpine \
  pg_restore -d "$DATABASE_URL" --clean --if-exists \
  ~/barvea/backups/<timestamp>_pre_deploy/pre_deploy.pgcustom
```

---

## Backup strategy

| What | Where | Frequency | Retention |
|------|-------|-----------|-----------|
| Postgres dump | barvea-app `~/barvea/backups/` | Daily 03:00 | 14 daily + Sunday weekly + 1st of month |
| MinIO data | barvea-data (native, separate cron) | TBD | TBD |
| Redis snapshot | barvea-data RDB persistence | Continuous (every 60s if 1000+ writes) | RDB on disk |
| Off-site replication | rclone → external S3/B2 | Weekly | 6 months |

Backup of MinIO and Redis is **not** in scope of this repo — those run on barvea-data and own their data volumes there.

---

## Security checklist

Before going live:

- [ ] `.env.production` is `chmod 600`, owned by deploy user, never committed
- [ ] All `__PLACEHOLDER__` values replaced with `openssl rand -base64 32` outputs
- [ ] `STRIPE_WEBHOOK_SECRET` matches the endpoint registered in Stripe dashboard
- [ ] DNS CAA record limits CA to `letsencrypt.org`
- [ ] Public ports limited to 80/443/51820/2277 on barvea-infra (firewall verified)
- [ ] PostgreSQL `pg_hba.conf` allows `barvea_app` from `10.10.0.30/32` only, scram-sha-256
- [ ] Redis `requirepass` set, listen on `0.0.0.0:6379` but `iptables` blocks all except 10.10.0.30
- [ ] MinIO bucket policies: anonymous denied, only `barvea_app_minio` user can write
- [ ] Caddy issues real Let's Encrypt cert (not staging)
- [ ] HSTS preload header active
- [ ] `/api/health` returns 200 without authentication (monitoring will hit it)
- [ ] Rate limiter active in app (test: 6 failed logins → account locked 15 min)
- [ ] Email verification works end-to-end (register → SMTP delivers → click link)
- [ ] Stripe webhook test fires successfully (Stripe CLI: `stripe trigger invoice.paid`)

---

## Smoke test (after first deploy)

```bash
# 1. TLS valid
curl -I https://barvea.com
# HTTP/2 200, valid certificate

# 2. Health endpoint
curl https://barvea.com/api/health
# {"status":"healthy","checks":{"database":"ok","redis":"ok","minio":"ok"},...}

# 3. Landing page renders
curl -s https://barvea.com | grep -i barvea
# matches "BARVEA"

# 4. www redirects to apex
curl -I https://www.barvea.com
# HTTP/2 301, location: https://barvea.com/

# 5. Stripe webhook accepts payload
stripe listen --forward-to https://barvea.com/api/webhooks/stripe
# (in another terminal)
stripe trigger invoice.paid
```

---

## Cron — backup

On barvea-app:

```cron
# /etc/cron.d/barvea-backup
0 3 * * * miko /home/miko/barvea/scripts/backup.sh >> /var/log/barvea-backup.log 2>&1
```

Add monitoring (UptimeRobot / Better Stack) to ping `https://barvea.com/api/health` every 60 s.

---

## Skrypty ops/diag (TypeScript) na produkcji

Skrypty z `app/scripts/*.ts` **nie odpalą się** w kontenerze `barvea-app`.
Runtime image to Next standalone: ma `server.js`, `prisma/`, `scripts/`,
`node_modules` — ale **nie ma katalogu `lib/`**, a każdy diag robi
`import '../lib/prisma'`. `docker exec barvea-app npx tsx scripts/X.ts`
kończy się `Cannot find module '../lib/prisma'`. `tsx` nie jest też w
`package.json` (żadna zależność) — `npx` musi go dociągnąć z rejestru.

Działa uruchomienie w stage **`builder`** — tam jest pełne źródło + komplet
`node_modules`. Warstwy są w cache po deployu, więc build trwa sekundy:

```bash
cd ~/barvea
docker build --target builder -t barvea-diag:latest ./app

# DATABASE_URL podajemy przez shell, NIE przez --env-file:
# .env.production ma wartości w apostrofach; `docker compose` je zdejmuje,
# gołe `docker run --env-file` NIE — Prisma dostaje URL zaczynający się od '
# i pada na "URL must start with the protocol postgresql://".
set -a && . ./.env.production && set +a
docker run --rm --network host -e DATABASE_URL="$DATABASE_URL"   barvea-diag:latest npx -y tsx scripts/<nazwa>.ts
```

`--network host` = ten sam wzorzec co rollback `pg_restore` w `deploy.sh`
(bezpośredni dostęp do 10.10.0.20). Skrypty `*.mjs` z `scripts/` idą wprost
w runtime image: `docker compose run --rm app node scripts/<x>.mjs`.

---

## Sprzątanie po dockerze (VM 102)

Build cache rośnie z każdym deployem i **nikt go nie kasuje automatycznie**.
2026-08-25 uzbierało się 51 GB cache (47.95 GB do odzyskania) — dysk 75 G był
w 83%. Przed każdym większym buildem (albo cyklicznie):

```bash
df -h / && docker system df
docker builder prune -f --filter until=168h   # zostaw cache z ostatniego tygodnia
```

Nie kasuj całego cache bez `--filter` bez potrzeby — następny build app
leci wtedy od zera (npm ci + next build).

---

## Troubleshooting

**Caddy can't issue cert:** DNS not pointing to VM yet. Verify with `dig +short barvea.com` from external host. Caddy retries every 30 s.

**App keeps restarting:** Check `docker compose logs app`. Common causes:
- DB connection: `verify-data-vm.sh` will diagnose
- Missing env var: app won't start without `NEXTAUTH_SECRET`, `DATABASE_URL`
- Migration drift: run `docker compose run --rm app npx prisma migrate status`

**MinIO uploads fail:** Bucket missing or wrong access keys. Run `verify-data-vm.sh`.

**Stripe webhook returns 400:** `STRIPE_WEBHOOK_SECRET` doesn't match the endpoint. Each Stripe webhook endpoint has its own secret — copy from the specific endpoint's settings, not from a different one.

**504 timeouts on IFC upload:** Caddy `read_timeout` for `/api/v1/orgs/*/projects/*/ifc-models*` should be 600 s (set in Caddyfile). If upload >1 GB, increase `request_body max_size` in `Caddyfile`.

---

## Repo layout

```
barvea-infra/
├── README.md                 # this file
├── .gitignore                # excludes .env, secrets, logs, backups
├── docker-compose.yml        # app + caddy
├── Caddyfile                 # TLS + reverse proxy
├── .env.production.example   # secrets template
├── scripts/
│   ├── bootstrap.sh          # first-time deploy
│   ├── deploy.sh             # update workflow
│   ├── backup.sh             # daily Postgres dump
│   └── verify-data-vm.sh     # data-layer connectivity check
└── app/                      # cloned by bootstrap.sh — gitignored
```

---

## Related repos

- **App code:** https://github.com/archMikolajRozek/barvea
- **Backups location (off-server):** TBD (S3/B2 — configure when ready)
