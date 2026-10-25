# Współedycja (barvea-collab) — runbook wdrożenia infra (2026-10-25)

Kontrakt APP: `serwer/BARVEA_COLLAB_INFRA_HANDOFF.md` (+ `app/docs/BARVEA_COAUTHORING_PLAN.md`).
Zmiany w repo (commit „collab: …"): `docker-compose.yml` (usługa `collab`, sieć `barvea_collab`,
wolumen `collab_spool`, `app`/`caddy` w nowej sieci, `COLLAB_INTERNAL_URL`), `Caddyfile`
(`/_collab` WS + 404 na `/api/v1/internal/*` na obu vhostach), `scripts/deploy.sh`
(build nie-fatalny, collab PRZED app, stan tylko przy komplecie), `build-release-bundle.sh`,
`.env.example`.

## Odstępstwa od propozycji APP (świadome)
1. **Bez `NODE_OPTIONS` w compose** — Dockerfile ma `node --max-old-space-size=768` w CMD
   (flaga CLI wygrywa), dwa źródła prawdy = pułapka przy zmianie `mem_limit`.
2. **`COLLAB_TRUST_X_REAL_IP=1` potwierdzone jako bezpieczne**: Caddy ma globalnie
   `trusted_proxies` (zakresy CF) + `client_ip_headers Cf-Connecting-Ip`, więc `{client_ip}`
   to użytkownik, nie edge. APP tego „nie potwierdzał w repo" — teraz potwierdzone.
3. **Ryzyko resztkowe nazwane w compose**: konwertery na `barvea_internal` dosięgają `app:3005`,
   więc `/api/v1/internal/*` od ich strony chroni tylko Bearer + odrzucanie śladów proxy
   (po stronie appki). Akceptowane (token 64 hex), nie da się zamknąć siecią bez rozbicia
   appki na dwa kontenery.

## Kolejność na serwerze (barvea-app, `ssh -p 2277 miko@10.10.0.30`)

```bash
# 0. kod
git -C ~/barvea pull --ff-only origin main
git -C ~/barvea/app pull --ff-only origin main          # musi mieć collab-server/ + scripts/collab-keys.mjs
ls ~/barvea/app/collab-server/Dockerfile ~/barvea/app/scripts/collab-keys.mjs

# 1. walidacja konfigów ZANIM cokolwiek ruszy
cd ~/barvea && docker compose --env-file .env.production config -q && echo COMPOSE-OK
docker run --rm -v ~/barvea/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile

# 2. sekrety (wypisuje na stdout; NIE wklejać do czatu ani screenów)
cd ~/barvea/app && docker run --rm -v "$PWD/scripts:/s:ro" node:24.12.0-alpine node /s/collab-keys.mjs
#    → dopisać do ~/barvea/.env.production (chmod 600):
#      COLLAB_PUBLIC_URL=wss://app.barvea.com/_collab
#      COLLAB_SERVICE_TOKEN="…"  COLLAB_JWT_PRIVATE_KEY="…"  COLLAB_JWT_PUBLIC_KEY="…"
#    (COLLAB_INTERNAL_URL jest w environment usługi app — NIE dublować w .env)
grep -c '^COLLAB_' ~/barvea/.env.production                # 4

# 3. build + start collab (appka jeszcze bez COLLAB_* w env — współedycja ciemna)
cd ~/barvea && docker compose --env-file .env.production build collab
docker compose --env-file .env.production up -d --no-deps collab
sleep 20 && docker compose --env-file .env.production ps collab          # (healthy)
docker compose --env-file .env.production logs --tail 20 collab          # "ev":"collab.started"

# 4. caddy: nowa sieć = recreate (KILKA SEKUND PRZERWY DLA CAŁEGO RUCHU — spokojna chwila)
docker compose --env-file .env.production up -d --no-deps caddy
curl -s -o /dev/null -w '%{http_code}\n' https://app.barvea.com/api/health   # 200

# 5. app: dostaje COLLAB_* (env_file) + sieć barvea_collab
docker compose --env-file .env.production up -d --no-deps --force-recreate app
sleep 45 && docker exec barvea-app printenv COLLAB_PUBLIC_URL COLLAB_INTERNAL_URL

# 6. testy §9 z handoffu (skrót)
docker exec barvea-collab id -u                                            # 57439
docker exec barvea-collab touch /app/x 2>&1 | grep -o "Read-only"          # read-only
docker exec barvea-app   wget -qO- http://collab:1235/health; echo         # {"ok":true}
docker exec barvea-collab wget -qO- -T 5 http://app:3005/api/health | head -c 60; echo
docker exec barvea-collab wget -qO- -T 5 https://example.com 2>&1 | tail -1  # ma PAŚĆ (brak egressu)
ss -ltn | grep -E ':123[45]\b' || echo "porty 1234/1235 NIE na hoście (ok)"
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://app.barvea.com/api/v1/internal/collab/load  # 404
curl -s https://app.barvea.com/_collab | head -c 40; echo                  # "Welcome to Hocuspocus!"
```

## Cloudflare (dashboard, przed krokiem 4)
- strefa barvea.com → **Network → WebSockets = On**
- Security → Bots / WAF: nie challenge'ować `GET /_collab*` z `Upgrade: websocket`
  (challenge JS na upgrade = brak połączenia). W razie potrzeby wyjątek na ścieżkę.

## Rollback
Handoff §8: usunąć `COLLAB_PUBLIC_URL` z `.env.production` → recreate `app` (tryb jednego
edytora) → po ~2 min `compose stop collab` (SIGTERM = zapis + spool) → sprawdzić spool:
`docker run --rm -v barvea_collab_spool:/s alpine ls -la /s` (puste = nic nie utknęło).
Blokadę `/api/v1/internal/*` w Caddy ZOSTAWIĆ.

## Pamięć VM 102
Sumy `mem_limit`: pcp 12 + office 3 + dwg 3 + collab 1 = 19 G przy 16 G VM — sufity, nie
rezerwacje, ale **VM 102 → 24 G** (okno z restartem) jest już w kolejce i teraz bardziej zasadne.
