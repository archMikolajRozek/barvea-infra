#!/usr/bin/env bash
# BARVEA — barvea-host /usr/local/sbin/zfs-load-org.sh (IaC copy 2026-07-13).
# Odblokowuje org-datasety po reboocie: AppRole barvea-storage → Vault
# transit decrypt per-org-keys → /etc/zfs/keys/<orgId>.ct (ciphertext
# wrapped kluczy) → zfs load-key + mount. Wymaga: Vault UP+UNSEALED,
# /etc/vault/storage-approle (VAULT_ROLE_ID/VAULT_SECRET_ID — NIE w git),
# jq. Po skrypcie: pct stop 201 && pct start 201 (bind-mounty!).
# KEEP-IN-SYNC z żywym plikiem.
set -euo pipefail
VADDR="https://10.10.0.50:8200"
ORGS_DS="hddpool/orgs"
# bootstrap v2 (2026-11-24): pula orgów i adres Vaulta z konfiguracji (dedyk: pula bulk, inny LAN)
[ -f /etc/barvea/zfs-load-org.conf ] && . /etc/barvea/zfs-load-org.conf
. /etc/vault/storage-approle
# (2026-11-25) TLS Vaulta: PRZYPIĘCIE KLUCZA PUBLICZNEGO listenera (--pinnedpubkey z certu VAULT_CACERT) —
# cert Vaulta to self-signed CN=Vault bez IP w SAN, więc --cacert odpada (name mismatch); pin działa z nim i z certem
# z pki_int. Rotacja certu Vaulta = pct pull 200 /opt/vault/tls/tls.crt /etc/barvea/vault-tls.crt. Bez pliku = -k jak dotąd.
# AppRole JSON przez stdin, nie argv. PROD: wgrane 25.11 (sed na żywym pliku, kopia .bak-20261125).
if [ -n "${VAULT_CACERT:-}" ] && [ -f "$VAULT_CACERT" ]; then PIN=$(openssl x509 -in "$VAULT_CACERT" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64); CURL_TLS=(-k --pinnedpubkey "sha256//$PIN"); else CURL_TLS=(-k); fi
TOKEN=$(jq -n --arg r "$VAULT_ROLE_ID" --arg s "$VAULT_SECRET_ID" '{role_id:$r,secret_id:$s}' | curl -sS "${CURL_TLS[@]}" --request POST --data @- "$VADDR/v1/auth/approle/login" | jq -r '.auth.client_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = null ]; then echo "approle login failed"; exit 1; fi
for ct in /etc/zfs/keys/*.ct; do
  [ -e "$ct" ] || continue
  org=$(basename "$ct" .ct); ds="$ORGS_DS/$org"
  if [ "$(zfs get -H -o value keystatus "$ds" 2>/dev/null)" = available ]; then continue; fi
  PT=$(jq -n --arg ct "$(cat "$ct")" '{ciphertext:$ct}' | curl -sS "${CURL_TLS[@]}" -H "X-Vault-Token: $TOKEN" --data @- "$VADDR/v1/transit/decrypt/per-org-keys" | jq -r '.data.plaintext')
  printf '%s' "$PT" | base64 -d | zfs load-key "$ds"
  zfs mount "$ds" 2>/dev/null || true
  echo "unlocked: $ds"
done
curl -sS "${CURL_TLS[@]}" -H "X-Vault-Token: $TOKEN" --request POST "$VADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
