# Aplikacja mobilna — odpowiedź infra na `serwer/INFRA_HANDOFF_MOBILE_2026-10-29.md` (2026-10-28)

Zgoda co do zasady: **telefon = przeglądarka** (HTTPS przez Cloudflare → Caddy → app, bez WG,
bez nowych portów/usług). Poniżej potwierdzenia, korekty i to, co faktycznie trzeba zrobić.

## 1. Prawdziwe IP klienta — POTWIERDZONE, wiarygodny nagłówek = `X-Real-IP`
- Caddy globalnie: `trusted_proxies` = zakresy Cloudflare + `client_ip_headers Cf-Connecting-Ip`
  → `{client_ip}` to użytkownik, nie edge CF. Niespoofowalne: XFF/Cf-Connecting-Ip są honorowane
  wyłącznie, gdy połączenie przyszło z IP Cloudflare; klient wprost na origin dostaje swój własny IP.
- `header_up X-Real-IP {client_ip}` jest na **każdej** trasie do `app:3005` na `app.barvea.com`
  (webhooks, longops, uploads, catch-all, od dziś także `/api/health`) i na `app.barvea.internal`
  (tam `{client_ip}` = adres WG/LAN peera — też prawdziwy, bo bez proxy po drodze).
- `X-Forwarded-For {remote_host}` celowo zostaje IP przeskoku (CF). **App ma czytać `X-Real-IP`**
  i tylko to; XFF nie zmieniamy, żeby nie ruszać semantyki istniejących logów/audytu.

## 2. Cloudflare a klient bez JS/ciasteczek — DO SPRAWDZENIA W PANELU (plan Free)
Ryzyka na Free, których nie da się obejść per-ścieżka:
- **Bot Fight Mode** (Security → Bots): na Free nie ma reguł „skip" — klient okhttp/URLSession
  potrafi dostać challenge. Jeśli włączony → **wyłączyć** (ochronę zostawiamy limitom appki).
- **Security Level / Browser Integrity Check** (Security → Settings): BIC odrzuca „dziwne" UA;
  Security Level challenge'uje IP o złej reputacji — CGNAT operatorów komórkowych często takie są.
  Rozwiązanie na Free: **Configuration Rule** (Rules → Configuration Rules) dla ścieżek
  `/api/v1/mobile/*`, `/api/v1/orgs/*`, `/dl/*`, `/.well-known/*` → Security Level: *Essentially Off*,
  Browser Integrity Check: *Off*. (`crm.barvea.com` ma już jedną taką regułę — wzorzec jest.)
- APP: ustawić w apce czytelny `User-Agent` (`BarveaMobile/<ver> (Android|iOS)`) — ułatwia
  diagnostykę i wyjątki.

## 3. Limit na krawędzi dla `/api/v1/mobile/auth/*` — Z ZASTRZEŻENIEM
Free = **1 reguła Rate Limiting, okno 10 s**. „20/min" nie istnieje; najbliżej: 4 żądania / 10 s
(≈24/min) albo łagodniej 10 / 10 s. **Ryzyko CGNAT**: cała sieć operatora/biura za jednym IP —
limit per IP na logowanie blokuje niewinnych. Rekomendacja: zacząć **bez** reguły CF (app ma
własne limity + blokadę konta), włączyć dopiero po realnym incydencie. Decyzja Miko.

## 4. Upload z telefonu — POTWIERDZONE
Matchery Caddy są per ścieżka, nie per ciasteczko: `@uploads` (1 GB/żądanie, 600 s) i `@longops`
(`/complete`, 7200 s) obowiązują identycznie dla Bearer. Kawałki 32 MB < 100 MB limitu CF.
`/complete` powyżej ~100 s utnie Cloudflare (524) — apka dopytuje o stan, tak jak przeglądarka.

## 5. `/dl/` — bez zmian (TTL 900 s, Range od 2026-08).

## 6. Egress do FCM/APNs — NIC DO ZROBIENIA
VM 102 nie ma firewalla wyjściowego; kontener `app` jest na `barvea_web` z egressem (tak samo
idą Stripe, SMTP, apt). Sieci `internal: true` dotyczą tylko sidecarów. Test potwierdzający w
runbooku niżej. Nic przychodzącego nie otwieramy.

## 7. Sekrety push — jak inne: `.env.production` (chmod 600, env_file appki)
`FCM_SERVICE_ACCOUNT_JSON` (JSON w jednej linii, w cudzysłowach), `APNS_KEY_P8` (PEM w jednej
linii z `\n`, jak COLLAB_JWT_*), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`. Dopisane do
`.env.example` przy M3. Brak = push wyłączony (dedyk/air-gap bez zmian).

## 8. IFC → format mobilny (F2) — wzorzec gotowy
Jak dwg/office/pcp: sieć `barvea_internal`, uid 57439, read_only, mem_limit, Bearer, bez egressu.

## Hardening przy okazji (NIE blokuje mobile, do kolejki)
Origin `178.63.205.222:443` jest osiągalny **z pominięciem Cloudflare** (DNAT na VM 100). Każdy
limit/WAF/challenge w CF da się ominąć, łącząc się wprost z `Host: app.barvea.com`. Zamknięcie:
nftables na VM 100 — 80/443 tylko z zakresów CF (lista jak w `trusted_proxies`). Koszt: przy
zmianie listy IP CF trzeba ją odświeżyć w dwóch miejscach. Osobna decyzja, osobne okno.

## Test egressu (barvea-app)
```bash
for h in fcm.googleapis.com oauth2.googleapis.com api.push.apple.com; do docker exec barvea-app sh -c "wget -q --spider -T 5 https://$h/ 2>&1; echo $h exit=\$?"; done
```
`exit=0` lub `exit=8` (odpowiedź HTTP 4xx = dotarliśmy) — OK; `exit=1`/`4` = brak połączenia.
