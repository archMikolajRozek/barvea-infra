# Kolizje IFC (`ifc-clash`, K1) + API pluginu 19.11 — runbook infra

**STAN: PRZYGOTOWANE W REPO 2026-11-19 (noc), NIEWDROŻONE.** Deploy razem z gałęzią `feat/iso19650`
(APP), w którą wchodzą: K0/K1 (kolizje), API pluginu („jedna aktualizacja pluginu”), fix CSP `483c196c`.
Źródła: `app/docs/INFRA_HANDOFF_IFC_CLASH_2026-11-19.md` (K1 — do infry trafił dopiero 19.11 wieczorem, przy
okazji handoffu API pluginu) i `serwer/archiwum/INFRA_HANDOFF_API_PLUGINU_2026-11-19.md`.

## 1. Co doszło w repo infra
| Plik | Zmiana |
|---|---|
| `docker-compose.yml` | usługa `ifc-clash` (hardening jak pcp: uid 57439, read_only, cap_drop ALL, no-new-privileges, pids 512, tmpfs /tmp 64m, `init: true`, `mem_limit 12g`, `cpus 4`, limity 1 GiB, scratch bind `/srv/upload-tmp/clash-scratch`, tylko `barvea_internal`); usługa `ifc-extractor` (zestawienia IFC, ten sam hardening, `mem_limit 4g`, `cpus 2`, `IFC_MAX_BYTES` 400 MB, scratch bind `/srv/upload-tmp/ifc-extractor-scratch` → `/tmp/ifc`); `app`: `IFC_CLASH_URL`, `IFC_EXTRACTOR_URL` + `depends_on … service_started` |
| `scripts/deploy.sh` | `ifc-clash` w obu pętlach sidecarów (build nie-fatalny, `up -d --no-deps`); kontrola scratch (`case` pcp / clash: katalog musi istnieć i nie być root-owned) |
| `Caddyfile` | `@pluginAnalytics` (init ≤ 8 MiB, parts ≤ 16 MiB → `max_size 17MB`, 600 s); `…/ifc/{modelId}/file` w `@mobileStream` (1800 s, flush -1, Range); `/api/v1/plugin/projects/*/ifc-upload` w `@uploads` (dotąd leciał catch-allem ze 120 s) |
| `.env.example` | `IFC_CLASH_TOKEN` (🔑), opcjonalne `CLASH_*`, notka: `MINIO_PUBLIC_ENDPOINT` celowo brak |
| `bootstrap.sh` | `install -d -o 57439 …/pcp-scratch …/clash-scratch` (dedyk) |

Catch-all Caddy **nie ma** `request_body max_size` (limit = CF 100 MB/żądanie). Caddy ani CF nie dekodują
`Content-Encoding: gzip` w żądaniach — części OUT-53 docierają surowe (sha256 w `X-Content-SHA256` zgadza się).

## 2. Decyzje / odpowiedzi dla APP (pyt. 1–5 z handoffu API pluginu)
1. `max_size` catch-all: brak → 16 MiB przechodzi; i tak dostał własny matcher (timeout 600 s na wolne łącze).
2. Strumień `…/ifc/{modelId}/file`: TAK, w `@mobileStream` (ta sama klasa: 1800 s, `flush_interval -1`).
3. `MINIO_PUBLIC_ENDPOINT`: **NIE jest ustawione i nie będzie** — MinIO (10.10.0.20:9000) widzi tylko LAN VM-ów,
   origin przyjmuje 80/443 wyłącznie z Cloudflare, a zasada „tylko app.barvea.com / *.barvea.internal”
   (wytyczne 19.11) wyklucza drugi publiczny host. **Raporty kolizji → przez appkę** (krótki strumień ≤ kilkanaście
   MB; `/dl/` z datad jeśli plik leży na ZFS, albo `/api/…/report/download` z MinIO). Bez tego `url` z presign
   wskazuje 10.10.0.20 i nie otworzy się ani w pluginie, ani w www.
4. `mem_limit` kontenera `app`: **brak** (cgroup bez sufitu; VM 102 24 G, sufity sidecarów 19 g + ifc-clash 8 g).
   Szczyt `sync` ≤ 2 × 2 GB = 4 GB mieści się, ale razem z parserem (`IFC_PARSE_HEAP_MB` 3072) i buildem Nexta
   na tej samej VM — zalecenie: slot serwera `sync` = 1 do czasu VM 102 → 32 G.
5. Indeks `IfcElement_revitUniqueId_idx`: **zwykły `CREATE INDEX`, deploy wieczorem** (jak zawsze). `prisma migrate
   deploy` wykonuje migrację w transakcji → `CONCURRENTLY` w pliku migracji nie przejdzie; gdyby tabela była duża
   (> ~10 mln wierszy), krok ręczny: `psql … CREATE INDEX CONCURRENTLY …` + `prisma migrate resolve --applied`.
   Rozmiar sprawdzić przed deployem (VM 101):
   `sudo -u postgres psql -d barvea -Atc "select pg_size_pretty(pg_total_relation_size('\"IfcElement\"')), (select n_live_tup from pg_stat_user_tables where relname='IfcElement')"`.

Kopie: restic VM 101 03:09 = `pg_dump` całej bazy + `/mnt/minio-data` → nowe tabele i kopie IFC w bucketach
objęte; części OUT-53 / raporty (retencja 7 dni) przejściowe. Przyrost: każdy eksport IFC z pluginu z `link:true`
= kopia w MinIO obok pliku na ZFS (×2 na dysku, ×2 w restic).

RAM: **decyzja Miko 2026-11-19 noc: VM 102 → 32 G** (host 128 G; goście 4+24+32+2+8 G) → ifc-clash `12g` / 1 GiB
(zmierzone: 51 MB IFC → 801 MB RSS; ~8 MB RAM na 1 MB IFC), ifc-extractor `4g` / 400 MB. Suma sufitów 35 g > 32 G
(sufit ≠ rezerwacja; appka nie wyklucza pcp i clash wzajemnie). **Decyzja Miko: `ifc-extractor` wdrażamy razem.**

## 3. Deploy (VM 102 `barvea-app`, po merge `feat/iso19650` → main w APP)
0. ✅ 19.11 noc — host: `qm set 102 --memory 32768 --balloon 32768` + `qm shutdown`/`qm start` (free: 31 G; collab flush przez stop_grace 30 s).
1. ✅ 19.11 noc — `sudo install -d -o 57439 -g 57439 /srv/upload-tmp/clash-scratch /srv/upload-tmp/ifc-extractor-scratch`
2. `IFC_CLASH_TOKEN=$(openssl rand -hex 32)` i `IFC_EXTRACTOR_TOKEN=$(openssl rand -hex 32)` dopisać do
   `~/barvea/.env.production` (chmod 600; bez chatu/repo).
3. `cd ~/barvea && git pull` (compose, Caddyfile, deploy.sh) → `docker compose --env-file .env.production
   run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile` (potrzebuje `/etc/ssl/barvea`).
4. `scripts/deploy.sh` — pre-deploy pg_dump, build app + sidecary (w tym `ifc-clash`), migracje
   `20261119120000_clash_k0`, `20261119230000_plugin_api_full`, `20261119233000_plugin_api_indexes`,
   `20261119235500_plugin_api_review`, recreate collab → app, Caddy reload.
5. Smoke:
   - `docker compose exec app wget -qO- http://ifc-clash:8080/health` → `{"ok":true,"ifcopenshell":"0.8.5","busy":false}`
   - `docker compose exec app wget -qO- http://ifc-extractor:8080/health` → ok; w www zestawienia IFC przestają być „ciemne”
   - logi app: `[clash] worker started (15s interval)`, `[clash-report] worker started (60s interval, 7-day retention)`,
     `[element-analytics] worker started (60s interval)`
   - token pluginu: `GET /api/v1/plugin/me` → `features.clash.version = 2`; `PUT …/element-analytics/{id}/parts/1`
     ~15 MiB → 200 (nie 413); `GET …/clash/runs/{runId}/report?format=pdf` → 202 → 200 z linkiem przez appkę.
6. Jednorazowo po migracji (APP, obraz buildera z `DATABASE_URL` + `MINIO_*`): `npx tsx scripts/ifc-reparse-backfill.ts`
   (sucho) → `--apply` — bez tego stare modele pokazują „przetwórz ponownie”.
7. Po pierwszym teście Miko: `peakRssMb` w `ClashRun.counts.engine` i `ElementAnalyticsUpload.calibration` →
   korekta `mem_limit` / limitów.

Rollback: usunąć `IFC_CLASH_URL` z `app.environment` + recreate app (moduł ciemny), `docker compose stop ifc-clash`.

## 4. Otwarte
- ✅ decyzje 19.11 noc: `ifc-extractor` razem; VM 102 → 32 G; ifc-clash 12g / 1 GiB.
- Dedyk/air-gap: koło `ifcopenshell` (LGPL-3.0, statyczne OCCT/CGAL) → przegląd licencji przed dołączeniem do paczki.
