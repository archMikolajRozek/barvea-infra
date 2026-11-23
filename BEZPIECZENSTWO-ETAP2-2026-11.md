# Bezpieczeństwo — Etap 2 (stan 2026-11-23, prod)

Co jest włączone, gdzie leży przełącznik, jak wycofać. Źródła: handoffy APP `serwer/INFRA_HANDOFF_ETAP2_PRZELACZNIKI_2026-11-23.md`,
`serwer/INFRA_HANDOFF_PANEL_ADMINA_2026-11-23.md`, runda bezpieczeństwa 19–20.11 (`KONTRAKTY-KLIENCI-2026-11.md`).
Wszystkie zmienne w `~/barvea/.env.production` na VM 102 (600; w restic VM 102 razem z katalogiem `~/barvea`).

| Mechanizm | Stan prod | Przełącznik | Wycofanie | Zależności |
|---|---|---|---|---|
| CSP (Content Security Policy) | `report` (domyślne; brak linii) | `CSP_MODE=enforce` + recreate app | `CSP_MODE=report` + recreate | 2 dni czystych raportów w panelu Błędy systemu → csp po fixie `483c196c` (prod od 22.11) → najwcześniej 24.11 wieczorem |
| Antywirus uploadów | `AV_MODE=block` od 2026-10-23, `AV_REQUIRED=0` | `AV_REQUIRED=1` = fail-closed | `AV_MODE=warn`/`off` | clamd natywnie na LXC 201 (10.10.0.40:3310, socket systemd); `AV_REQUIRED=1` dopiero z monitoringiem clamd (brak) |
| Sekrety 2FA zaszyfrowane w bazie | ✅ 23.11: 3/3 zaszyfrowane | `TOTP_ENCRYPTION_KEY` (base64, 32 B, generowany na serwerze) | brak — UTRATA KLUCZA = reset 2FA wszystkim | kolejność: klucz → recreate app → pg_dump → `scripts/encrypt-totp-secrets.ts --dry-run` → apply (obraz barvea-diag, env-file tylko DATABASE_URL+klucz); kopia `backups/20261123_211135_pre_totp.dump` |
| Dowód mTLS Caddy → app | ✅ 23.11 | `MTLS_PROXY_SECRET` w `.env.production`: caddy (compose `environment`, interpolacja) dokłada `X-Barvea-Mtls-Proof` tylko w catch-allu app.barvea.com i na app.barvea.internal; app (`lib/mtls.ts`) przyjmuje `X-Client-Cert-*` wyłącznie z dowodem | usunąć zmienną z app + recreate app (NIE z caddy osobno: app ze zmienną bez nagłówka = odrzuca Drive) | na 7 trasach bez TLS (@uploads, @longops, @mobileStream, @pluginAnalytics, webhooks, /api/health, admin) Caddy zdejmuje `X-Client-Cert-*` i dowód. Powód: przegląd 23.11 — nagłówki tożsamości certyfikatu Drive dało się podrobić na trasach, gdzie Caddy ich nie nadpisywał |
| Panel admina na osobnym hoście | ✅ 23.11 `admin.barvea.com` | `ADMIN_HOST=admin.barvea.com`, `ADMIN_SESSION_IDLE_MIN=30` + recreate app | usunąć `ADMIN_HOST` + recreate (panel wraca pod app.barvea.com/admin) | DNS A 178.63.205.222 proxied; vhost Caddy = ten sam `app:3005`, ALLOWLISTA ścieżek (lista APP), 20 MB, GET stron spoza listy → 302 na app, API → 404; logowanie tylko role platformy + 2FA za każdym razem, osobna sesja (ciasteczko host-only), 30 min bezczynności w Redisie (bez Redisa panel zamknięty), max 8 h; Turnstile: domena admin w kluczu |
| Zaufane przeglądarki 2FA | ✅ w kodzie c42952b2 | — | — | „Wyloguj i przestań ufać” + lista w Ustawienia konta → Bezpieczeństwo (odwołaj / wszystkie), audyt. Drive: jedno zaufanie per urządzenie (`Device.trustGrantedAt`), per org — do decyzji Miko |
| Bramka wersji pluginu | `PLUGIN_LATEST_VERSION_REVIT/AUTOCAD=1.0.0-beta.1` (23.11), MIN nieustawione | `PLUGIN_MIN_VERSION_REVIT=1.0.0-beta.1` gdy testerzy zejdą z 0.9.0-dev → potem Worker 426 (`cloudflare/plugin-proxy-worker-426.js`) | usunąć zmienne + recreate | `MOBILE_MIN_VERSION` dopiero po „go” Mobile po teście ISO (0.3.0) |
| Origin tylko z Cloudflare | ✅ 19.11 | nftables hosta `set cloudflare_v4` | `nft -f /root/nftables.conf.bak-2026-11-19` | przy zmianie listy IP CF: set + Caddy `trusted_proxies` |
| Orgi testowe | ✅ usunięte 20.11 (`test-drive`, `test-org-001`) | — | restic hosta (04:15) | procedura `DRIVE-DNS-VETO-2026-11.md §4`; LXC 201 = tylko `[barvea]` + 3 realne orgi |

## Sekrety wygenerowane na serwerze (nigdy przez czat) — gdzie żyją
`TOTP_ENCRYPTION_KEY`, `MTLS_PROXY_SECRET`, `IFC_CLASH_TOKEN`, `IFC_EXTRACTOR_TOKEN`, `DRIVE_ACL_SERVICE_TOKEN` (zrotowany 20.11 po
wycieku na zrzut ekranu; procedura: app `.env.production` → scp host → `pct push 201` → `/etc/barvea/acl-sync.env`),
`POINTCLOUD_PREVIEW_TOKEN`, `COLLAB_SERVICE_TOKEN`. Wszystkie w `~/barvea/.env.production` (VM 102) → restic nocny.
Sidecary i caddy dostają TYLKO swoją zmienną przez interpolację w compose, nigdy `env_file`.

## Gotchas tej rundy
- `docker --env-file` NIE zdejmuje cudzysłowów (compose zdejmuje) → skrypty diag z filtrem `grep … | sed` zdejmującym `"`/`'`.
- `pg_dump` na VM 102 = 17, Postgres 18.3 → zawsze `docker run --rm --network host postgres:18-alpine pg_dump` (jak deploy.sh).
- Caddy `{env.X}` nieustawiony = pusty nagłówek; zmiana env kontenera caddy = `up -d --force-recreate --no-deps caddy` (kilka s przerwy całego ruchu), reload nie wystarczy.
- Caddy `path`: trailing `*` = prefiks dowolnej głębokości, `*` w środku = jeden segment.
- Nie wypisywać plików env w komendach dla Miko (zrzut ekranu → czat). Tylko nazwy kluczy / liczniki.
- Nazwy sesji Claude Code mylą: „BARVEA APP” = mobile, „cde-cleanup-discipline-packages” = APP web.
