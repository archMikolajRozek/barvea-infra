# Cloudflare — rzeczy, które NIE żyją na naszym Proxmoxie

Strefa `barvea.com` jest na Cloudflare (NS `kaiser`/`sloan.ns.cloudflare.com`);
`app.barvea.com`, `barvea.com`, `www` — wszystkie przez proxy (pomarańczowa chmurka).
`barvea.com`/`www` → zewnętrzny CMS biura (cutover 2026-07-28); `app.barvea.com` → nasz Caddy.

## plugin-proxy-worker.js — majowe instalacje pluginu Revit (2026-10-23)

Problem i kontrakt: `app/docs/INFRA_REQUEST_PLUGIN_PROXY_2026-10.md`. Stan przed:
`barvea.com/api/v1/plugin/me` → **308** na app.barvea.com (reguła redirect w CF),
`barvea.com/api/health` → 404 z CMS. Redirect nie wystarcza (.NET gubi Authorization,
multipart nie do powtórzenia) → Worker przepuszcza żądania 1:1 na origin appki.

### Wdrożenie (dashboard Cloudflare, ~10 min)
1. **Rules → Redirect Rules** (strefa barvea.com): regułę, która robi 308 z `/api/*`,
   ograniczyć tak, żeby NIE łapała `/api/v1/plugin/*` ani `/api/health`
   (np. warunek `not starts_with(http.request.uri.path, "/api/v1/plugin/")`),
   albo skasować, jeśli dotyczyła tylko tych ścieżek. Redirecty wykonują się
   PRZED Workerami.
2. **Workers & Pages → Create → Worker** „barvea-plugin-proxy" → wklej
   `plugin-proxy-worker.js` → Deploy.
3. Worker → **Settings → Domains & Routes → Add route**, zone `barvea.com`:
   - `barvea.com/api/v1/plugin/*`
   - `barvea.com/api/health`
4. Caddy/appka: **bez zmian**. Origin widzi `Host: app.barvea.com` + nagłówek
   `X-Barvea-Legacy-Host: barvea.com` (diagnostyka).

### Akceptacja (z PC)
```powershell
curl.exe -s -D - -o NUL https://barvea.com/api/health            # 200, JSON healthy, BEZ Location
curl.exe -s -D - -o NUL https://barvea.com/api/v1/plugin/me       # 401 (bez tokenu) — nie 308
# z ważnym tokenem pluginu: identyczny JSON jak z app.barvea.com; parowanie
# initiate → zatwierdzenie → status; multipart POST cde/upload → 201.
```
Kontrola IP (żeby rate-limit nie zlał legacy w jeden adres): w logu Caddy/appki
dla żądania przez barvea.com `X-Real-IP` ma być IP klienta, nie IP Cloudflare;
Worker dokłada `X-Barvea-Client-IP` z `cf-connecting-ip` jako źródło prawdy.
Worker zdejmuje `Cookie` (w górę) oraz `Set-Cookie` i `Strict-Transport-Security`
(w dół) — plugin to Bearer, a polityki domeny appki nie mają dotyczyć CMS-u.

### Limity i wycofanie
- Body przez proxy CF = limit planu strefy (Free/Pro ~100 MB na żądanie) —
  dotyczy app.barvea.com identycznie; Worker nic nie pogarsza. Free: 100k req/dzień.
- Wycofać (skasować trasy), gdy Ustawienia → Urządzenia nie pokazują już tokenów
  bez `X-Plugin-Version`. Worker może zostać nieaktywny — koszt zero.
