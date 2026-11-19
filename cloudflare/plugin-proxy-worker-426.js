// BARVEA — Cloudflare Worker (ETAP WYCOFANIA proxy pluginu): barvea.com/api/v1/plugin/*
// odpowiada 426 PLUGIN_UPDATE_REQUIRED zamiast proxy na app.barvea.com.
//
// KIEDY: po wydaniu pluginu 1.0.0 (twarda bramka 426 w kliencie, main 2026-11-19)
// i ustawieniu PLUGIN_MIN_VERSION=1.0.0 w .env.production (APP zwraca 426 dla
// buildów starszych). Stare majowe buildy (bez X-Plugin-Version) nadal wołają
// barvea.com — tu dostają to samo ciało co z appki, bez proxy. Po 2–4 tygodniach
// bez ruchu (metryki Workera) skasować trasy i Workera.
//
// KONTRAKT CIAŁA (APP, 2026-11-19, lib bramki pluginu): status 426, JSON jak niżej,
// Cache-Control: no-store. Plugin czyta details.{minPluginVersion, latestPluginVersion,
// updateUrl}; updateUrl musi być https na originie app.barvea.com.
// currentVersion: null = brak X-Plugin-Version (stare buildy). latestPluginVersion
// dojdzie addytywnie po drugim przebiegu APP — Worker może go pominąć.
//
// TRASY: te same co plugin-proxy-worker.js (barvea.com/api/v1/plugin/*, barvea.com/api/health).
// /api/health zostawiamy jako 200 JSON (monitoring starych instalacji nic nie robi).

const MIN_VERSION = '1.0.0';                       // = PLUGIN_MIN_VERSION z .env.production
const UPDATE_URL = 'https://app.barvea.com/pobierz';
const MESSAGE =
  `Ta wersja pluginu BARVEA jest za stara (wymagana co najmniej ${MIN_VERSION}). ` +
  `Zaktualizuj plugin: ${UPDATE_URL}`;

function body426() {
  const details = {
    minPluginVersion: MIN_VERSION,
    currentVersion: null,
    updateUrl: UPDATE_URL,
    hostApp: 'revit',
  };
  return {
    error: { code: 'PLUGIN_UPDATE_REQUIRED', message: MESSAGE, details },
    code: 'PLUGIN_UPDATE_REQUIRED',
    message: MESSAGE,
    ...details,
  };
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/api/health') {
      return new Response(JSON.stringify({ ok: true, legacy: 'barvea.com', see: 'https://app.barvea.com' }), {
        status: 200,
        headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
      });
    }
    return new Response(JSON.stringify(body426()), {
      status: 426,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        'x-barvea-plugin-min-version': MIN_VERSION,
      },
    });
  },
};
