// BARVEA — Cloudflare Worker: proxy ścieżek pluginu Revit z barvea.com na app.barvea.com
//
// PO CO (2026-10-23, app/docs/INFRA_REQUEST_PLUGIN_PROXY_2026-10.md): majowe
// instalacje pluginu mają wbudowane https://barvea.com; kanoniczna domena to
// app.barvea.com, a barvea.com = CMS biura na innym hostingu (cutover 2026-07-28).
// Redirect 301/302/308 NIE wystarcza: .NET HttpClient przy cross-host redirect
// zdejmuje Authorization, a multipartu ze strumienia nie da się powtórzyć.
// Worker przepuszcza żądanie 1:1 (metoda, nagłówki, strumień body) na origin
// appki — bez follow-redirect, bez buforowania.
//
// TRASY (Workers → Routes, strefa barvea.com):
//   barvea.com/api/v1/plugin/*
//   barvea.com/api/health
// UWAGA: Cloudflare wykonuje Redirect Rules PRZED Workerami — jeśli istnieje
// reguła 308 barvea.com/api/* → app.barvea.com, ścieżki pluginu trzeba z niej
// wyłączyć (albo ją skasować), inaczej Worker nigdy nie dostanie żądania.
//
// LIMITY: body przez proxy CF podlega limitowi planu strefy (Free/Pro ~100 MB
// na żądanie) — dotyczy app.barvea.com tak samo, Worker nic nie pogarsza.
// WYCOFANIE: skasować trasy, gdy lista urządzeń nie pokazuje już tokenów bez
// X-Plugin-Version (majowy build nie wysyła nagłówka).

const ORIGIN_HOST = 'app.barvea.com';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    url.hostname = ORIGIN_HOST;

    const headers = new Headers(request.headers);
    // Plugin autoryzuje się Bearerem — ciasteczek nie potrzebuje. Nie mieszamy
    // zakresów domen (barvea.com vs app.barvea.com): Cookie w górę OFF.
    headers.delete('cookie');
    // Origin ma wiedzieć, że to shim (diagnostyka w logach appki/Caddy).
    // Tylko diagnostyka — appka NIE MOŻE na tym nagłówku opierać decyzji,
    // bo każdy może go wysłać wprost na app.barvea.com.
    headers.set('X-Barvea-Legacy-Host', 'barvea.com');
    // IP klienta: ŻADNEGO własnego nagłówka (byłby spoofowalny). Zostaje
    // CF-Connecting-IP ustawiany przez Cloudflare → Caddy X-Real-IP. Czy
    // subrequest Workera go zachowuje, sprawdza akceptacja (README).

    const init = {
      method: request.method,
      headers,
      redirect: 'manual',                 // nigdy nie podążaj — plugin dostaje odpowiedź origin 1:1
    };
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      init.body = request.body;           // strumień, bez buforowania (multipart do limitu planu)
    }

    const resp = await fetch(url.toString(), init);
    // Odpowiedź 1:1 (status + strumień), minus nagłówki, które nie mogą się
    // przykleić do domeny CMS-u: Set-Cookie (zakres app.barvea.com) i HSTS
    // appki (includeSubDomains/preload — polityka naszej domeny, nie CMS-u).
    const out = new Headers(resp.headers);
    out.delete('set-cookie');
    out.delete('strict-transport-security');
    return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: out });
  },
};
