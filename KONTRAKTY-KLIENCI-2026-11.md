# Kontrakty infra ↔ klienci (APP, plugin Revit, BARVEA Drive, mobile) — stan 2026-11-19

Zebrane z rundy synchronizacji między sesjami Claude Code (19.11 noc). Jedno miejsce z zasadami,
które muszą się zgadzać między infrą (Caddy, Cloudflare, WireGuard, sidecary) a każdym klientem.
Zmiana po którejkolwiek stronie = aktualizacja tego pliku. Szczegóły techniczne: runbooki obok
(`COLLAB-ROLLOUT-2026-10.md`, `MOBILE-INFRA-2026-10.md`, `DRIVE-DNS-VETO-2026-11.md`,
`KOLIZJE-IFC-CLASH-2026-11.md`, `cloudflare/README.md`, `HARDENING-2026-09.md`).

## 1. Zasady wspólne (obowiązują każdego klienta)
| Zasada | Treść | Dlaczego |
|---|---|---|
| Jeden publiczny host | Tylko `https://app.barvea.com`. `barvea.com` = CMS biura (inny hosting); `*.barvea.internal` tylko przez WireGuard | origin przyjmuje 80/443 wyłącznie z Cloudflare (nftables hosta, 2026-11-19); AAAA apexu usunięty |
| IP klienta | Caddy ustawia `X-Real-IP = {client_ip}` (z `Cf-Connecting-Ip`, ufa tylko zakresom CF). Appka czyta WYŁĄCZNIE `X-Real-IP`. Klient nie wysyła żadnych nagłówków z IP | spoofing XFF; Worker też nie dodaje nagłówka IP |
| Ruch tunelem | Żądania z WireGuard docierają z `10.10.0.10` (VM 100 robi MASQUERADE 10.67.0.0/16). To normalne, nie błąd | hub WG = NAT |
| Rozmiary | Cloudflare Free: 100 MB na żądanie. Większe pliki tylko kawałkami ≤ 64 MB. Multipart ≤ 90 MB | limit planu strefy |
| Limity częstości | Liczy appka w Redis per token/użytkownik, nigdy per IP; per IP tylko trasy bez uwierzytelnienia (`/pair/*`). Caddy i CF: brak rate-limitów, Bot Fight Mode OFF | NAT tunelu i biura |
| Wersja klienta | Plugin: `X-Plugin-Version` + `X-Revit-Version`; Drive i mobile: `X-Barvea-App-Version`; UA `BARVEA-<Klient>/<wersja>`. Na KAŻDYM żądaniu. Infra czyta tylko diagnostycznie | bramka wersji w appce |
| Sekrety | Nigdy przez czat/repo/wiadomości między sesjami. Prod: `.env.production` (600). Sidecary dostają tylko swoje zmienne przez `${VAR:-}` | HARDENING-2026-09 |
| TLS | Zero wyłączeń walidacji w buildach Release. Drive: pin SPKI BARVEA Root CA (Vault, TTL 10 lat → ~2036) tylko dla `app.barvea.internal` | |
| Telemetria | Żaden klient nie wysyła telemetrii ani raportów błędów poza API platformy | |

## 2. Caddy — trasy specjalne (app.barvea.com)
| Matcher | Ścieżki | Limit / timeout | Dla kogo |
|---|---|---|---|
| `@uploads` | `…/documents`, `…/documents/*`, `…/documents/uploads/*`, `…/ifc`, `…/ifc/*`, `…/assets/*/documents`, `…/combined-models*`, `/api/v1/plugin/projects/*/cde/upload`, `…/ifc-upload` | 1 GB, 600 s | www, plugin |
| `@longops` | `…/documents/uploads/*/complete`, `…/volumes/*/build` | 10 MB, 7200 s | www |
| `@pluginAnalytics` | `/api/v1/plugin/projects/*/element-analytics/init`, `…/element-analytics/*/parts/*` | 17 MB, 600 s; body gzip SUROWE (Caddy/CF nie dekodują), sha256 w `X-Content-SHA256` | plugin OUT-53 |
| `@mobileStream` | fragments, documents download/preview, zdjęcia (bim-issues, daily-log, deliveries, work-orders), `…/ifc/*/file` | 1800 s, `flush_interval -1`, Range | mobile, www |
| `/dl/*` | datad 10.10.0.40:8723 (podpisane URL) | 1800 s | wszyscy |
| `/_collab` | WebSocket → collab:1234, bez idle timeout | www |
| `/api/v1/internal*` | 404 na obu vhostach | — |
| catch-all | app:3005, 120 s, BEZ `max_size` (limit = CF 100 MB) | |

Uwaga Caddy: `*` w `path` łapie JEDEN segment. `/foo/*` nie łapie gołego `/foo`.

## 3. Plugin Revit (stan main 2026-11-19, wersja 0.9.0-dev → 1.0.0)
- Adres: stała `https://app.barvea.com`; stare `barvea.com` mapowane przy wczytaniu; własny serwer (dedyk) z listy w `%APPDATA%\BARVEA\servers.json`; `http://` tylko localhost (poza localhost wyłącznie w trybie dev, Release odrzuca).
- Token `fos_plugin_…` w DPAPI (`credentials.enc`), redaktor logów maskuje tokeny/Bearer/sygnatury. Zrzuty CER Autodesku poza kontrolą.
- **426 `PLUGIN_UPDATE_REQUIRED`** (twarda bramka w kliencie od 19.11): zapamiętane per serwer, wszystkie wywołania blokowane lokalnie do aktualizacji, bez pętli; baner z `details.updateUrl` (https, origin app.barvea.com). Ciało (APP):
  `{ error:{code,message,details:{minPluginVersion,currentVersion,updateUrl,hostApp}}, code, message, minPluginVersion, currentVersion, updateUrl, hostApp }`, `Cache-Control: no-store`; później addytywnie `details.latestPluginVersion`.
- Upload kawałkowy: chunk z `init` (32 MB, 1–64 MB), sekwencyjnie, wznawianie ze stanu lokalnego, backoff 3^n, 413 bez ponowień, 429 z Retry-After ≤ 10 s = jedno ponowienie.
- OUT-53 (plan): części gzip ≤ 16 MiB, ≤ 4 równolegle, 202 → odpytywanie co 3–5 s.
- Instalator: bez podpisu do certyfikatu OV (decyzja Miko); obok `.sha256`; pobieranie tylko z app.barvea.com; plugin nie pobiera paczek sam.
- Wycofanie Workera `barvea.com/api/v1/plugin/*`: plugin 1.0.0 wydany → `PLUGIN_MIN_VERSION=1.0.0` + recreate app → Worker = `cloudflare/plugin-proxy-worker-426.js` → po 2–4 tyg. bez ruchu kasacja tras.

## 4. BARVEA Drive (Windows 0.1.8-alpha → 0.1.9-alpha; Mac analogicznie)
- Publicznie tylko parowanie (`app.barvea.com`); reszta przez WG: `app.barvea.internal` 10.10.0.30 (mTLS + pin), `drive.barvea.internal` 10.10.0.40 (SMB), DNS `10.67.0.1` (dnsmasq, tylko `*.barvea.internal`). Endpoint WG `178.63.205.222:51821/udp` otwarty dla wszystkich IP (blokada CF dotyczy tylko 80/443).
- Udział = `COALESCE(driveShareName, slug)`; zmiana nazwy = procedura 3 kroków (`DRIVE-DNS-VETO-2026-11.md §3`). `archbimcloud` → `barvea` zakończone 19.11.
- `wg_config` (APP 58a10bc4): `POST /api/v1/sessions/start` zwraca `wg_config{interface{address,dns}, peer{public_key,endpoint,allowed_ips,persistent_keepalive}}` bez PSK; klient nadpisuje AllowedIPs/DNS przy każdej sesji (0.1.9) i zdejmuje fallbacki hosts/`InternalDialAddress` (dziś są PIERWSZYM wyborem — do usunięcia).
- Sekrety: klucz mTLS w TPM; klucz WG + PSK w DPAPI (świadomy rozjazd: TPM bez ECDH); tokeny sesji tylko RAM; hasło SMB z `smb_config` tylko RAM.
- Odwołanie (kontrakt APP↔Drive, czeka na OK Miko): `403 {error:"device_revoked", wipe:true}`, `{device_lost, wipe:true}`, `{device_not_active, wipe:false}`; `org_access_revoked` = tylko odmontowanie. Heartbeat 60 s, teardown ≤ 90 s, bez pętli.
- Zaufanie urządzenia per org (decyzja Miko 2026-11-20): urządzenie łączy się z wieloma org bez zatwierdzania przez admina obcej org — osobne 2FA przy pierwszym połączeniu z każdą org + zaufanie 30 dni per org. Widok floty: Ustawienia org → BARVEA Drive → Urządzenia (OWNER/ADMIN); APP dorabia widoczność urządzeń obcych z sesjami do org + panel admina platformy.
- Peery WG kasuje APP przez unieważnienie urządzenia (wg-provisiond DELETE). Infra ręcznie tylko sieroty spoza bazy. Peery z lipca (F24B3yTVoSH9…, tuikdCgY49ek…) → skrypt APP `drive-devices-before.ts` po deployu → Miko unieważnia w panelu.
- Do 0.1.9: ACL logów `%PROGRAMDATA%\BarveaDrive\logs` (SYSTEM+Admins), brak tolerancji niezgodności nazwy hosta, fail-closed przy braku pinów (placeholdery już odrzucane). Klient działa jako user z `requireAdministrator` (zadanie Harmonogramu); usługa SYSTEM = post-beta. Auto-update brak (SHA256SUMS ze strony).

## 5. Mobile (BARVEA-Mobile)
- Tylko `app.barvea.com`; Configuration Rule CF `mobile-api-no-challenge` (BIC off dla `/api/`, `/dl/`, `/.well-known/`); `@mobileStream` dla dużych pobrań; UA `BARVEA-Mobile/`, `X-Barvea-Client: mobile`, `X-Barvea-App-Version`. FCM na prodzie (`FCM_SERVICE_ACCOUNT_JSON`); APNs odłożone (iOS nie ruszył). Staging `staging.app.barvea.com` — decyzja: robimy (listopad 2026).

## 6. APP (serwer) — ustalenia z infrą
- MinIO (10.10.0.20:9000) NIE jest publiczne i nie będzie; `MINIO_PUBLIC_ENDPOINT` nieustawione. Każdy plik do przeglądarki idzie przez appkę (`/api`, `/dl/`), np. raporty kolizji `GET /api/v1/clash-reports/{id}/download?t=<HMAC 15 min>` (≤ kilka MB, catch-all wystarcza).
- Kontener `app` bez `mem_limit`; VM 102 = 32 G; sufity sidecarów: dwg 3g, office 3g, pcp 12g, collab 1g, ifc-clash 12g, ifc-extractor 4g.
- Migracje: `prisma migrate deploy` w transakcji → `CREATE INDEX CONCURRENTLY` niemożliwe w migracji; duże indeksy = krok ręczny. Deploy wieczorem, pre-deploy pg_dump (retencja 30).
- Kopie: restic VM 101 (pg_dump całej bazy + /mnt/minio-data), host 04:15 (`/hddpool/orgs`, Vault); snapshoty sanoid lokalnie.
- Sidecary bez egressu (wyjątek pcp: pobiera podpisany URL), token przez interpolację, scratch na dysku 1 TB (`/srv/upload-tmp/*-scratch`, uid 57439).
