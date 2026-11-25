#!/usr/bin/env bash
# BARVEA — /usr/local/sbin/barvea-compose (VM aplikacji, instalacja dedykowana).
# Jedno wejście do docker compose instancji: zawsze ten sam plik compose, ten sam
# .env.production i profile z COMPOSE_PROFILES w nim. Instaluje deploy-app.dedicated.sh.
#   barvea-compose ps | logs -f app | up -d | exec -T app sh -c '...' | down
# Katalog: BARVEA_APP_DIR (domyślnie /home/<użytkownik instalacji>/barvea — zapisane przy instalacji).
set -euo pipefail
APP_DIR="${BARVEA_APP_DIR:-__APP_DIR__}"
cd "$APP_DIR" || { echo "brak katalogu instancji: $APP_DIR" >&2; exit 1; }
[ -f .env.production ] || { echo "brak $APP_DIR/.env.production" >&2; exit 1; }
# COMPOSE_PROFILES z .env.production (compose czyta go tylko z .env katalogu, nie z --env-file w każdej wersji)
PROFILES="$(grep -oP '(?<=^COMPOSE_PROFILES=).*' .env.production | tr -d '"'"'" || true)"
export COMPOSE_PROFILES="${COMPOSE_PROFILES:-$PROFILES}"
exec docker compose -f compose.dedicated.yml --env-file .env.production "$@"
