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
. /etc/vault/storage-approle
TOKEN=$(curl -sk --request POST --data "{\"role_id\":\"$VAULT_ROLE_ID\",\"secret_id\":\"$VAULT_SECRET_ID\"}" "$VADDR/v1/auth/approle/login" | jq -r '.auth.client_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = null ]; then echo "approle login failed"; exit 1; fi
for ct in /etc/zfs/keys/*.ct; do
  [ -e "$ct" ] || continue
  org=$(basename "$ct" .ct); ds="hddpool/orgs/$org"
  if [ "$(zfs get -H -o value keystatus "$ds" 2>/dev/null)" = available ]; then continue; fi
  PT=$(jq -n --arg ct "$(cat "$ct")" '{ciphertext:$ct}' | curl -sk -H "X-Vault-Token: $TOKEN" --data @- "$VADDR/v1/transit/decrypt/per-org-keys" | jq -r '.data.plaintext')
  printf '%s' "$PT" | base64 -d | zfs load-key "$ds"
  zfs mount "$ds" 2>/dev/null || true
  echo "unlocked: $ds"
done
curl -sk -H "X-Vault-Token: $TOKEN" --request POST "$VADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
