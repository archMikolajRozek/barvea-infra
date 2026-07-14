#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — bootstrap-vault.sh: odtwarza KONFIGURACJĘ Vault od zera.
# Zrzut 1:1 z żywego proda (LXC 200, Vault 2.0.0) — zweryfikowane
# read-only 2026-07-10 (secrets/auth/policy/roles/transit/tune/urls).
#
# ⚠️ FRESH INSTALL ONLY. To NIE jest ścieżka odtworzenia ISTNIEJĄCEJ
#    instancji (tam: restic-restore /opt/vault/data + ten sam binary
#    + unseal Shamir 3/5 — patrz README.md). Ten skrypt tworzy NOWE
#    CA i NOWE klucze transit → stare dane/certy będą NIEczytelne.
#
# Wymaga: vault CLI, VAULT_ADDR, VAULT_TOKEN (root), unsealed Vault.
# Idempotentny: istniejące mounty/CA/klucze pomija, resztę dopisuje.
#
# Flagi (env):
#   OUT_DIR=./vault-out       — artefakty (root-ca.crt, approle creds)
#   GEN_APPROLE_CREDS=1       — wygeneruj role_id+secret_id do OUT_DIR
#   ENABLE_AUDIT=1            — włącz file audit (patrz UWAGA niżej)
#   ISSUE_VAULT_TLS=1         — wystaw cert TLS dla samego Vaulta
#   VAULT_TLS_CN=vault.barvea.internal  VAULT_TLS_IP=10.10.0.50
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

OUT_DIR="${OUT_DIR:-./vault-out}"
mkdir -p "$OUT_DIR" && chmod 700 "$OUT_DIR"

say() { echo "── $*"; }

have_mount()  { vault secrets list -format=json | grep -q "\"$1/\""; }
have_auth()   { vault auth list -format=json | grep -q "\"$1/\""; }
have_ca()     { vault read -field=certificate "$1/cert/ca" >/dev/null 2>&1; }
have_key()    { vault read "transit/keys/$1" >/dev/null 2>&1; }

# ── 1. Secrets engines (typy+TTL jak na prodzie) ───────────────────
# (agent-registry/ = builtin Vault 2.0, sam się montuje — nie ruszamy)
say "secrets engines"
have_mount pki     || vault secrets enable pki
have_mount pki_int || vault secrets enable -path=pki_int pki
have_mount transit || vault secrets enable transit
have_mount secret  || vault secrets enable -path=secret -version=2 kv
vault secrets tune -default-lease-ttl=768h -max-lease-ttl=87600h pki
vault secrets tune -default-lease-ttl=768h -max-lease-ttl=43800h pki_int

# ── 2. Root CA (10 lat) + Intermediate (5 lat) ─────────────────────
if have_ca pki; then
    say "root CA istnieje — pomijam"
else
    say "generuję Root CA (BARVEA Root CA, RSA2048, 10y)"
    vault write -field=certificate pki/root/generate/internal \
        common_name="BARVEA Root CA" key_type=rsa key_bits=2048 \
        ttl=87600h > "$OUT_DIR/root-ca.crt"
fi
vault read -field=certificate pki/cert/ca > "$OUT_DIR/root-ca.crt"

if have_ca pki_int; then
    say "intermediate CA istnieje — pomijam"
else
    say "generuję Intermediate CA (CSR → sign root, RSA2048, 5y)"
    vault write -field=csr pki_int/intermediate/generate/internal \
        common_name="BARVEA Intermediate CA" key_type=rsa key_bits=2048 \
        > "$OUT_DIR/pki_int.csr"
    vault write -field=certificate pki/root/sign-intermediate \
        csr=@"$OUT_DIR/pki_int.csr" format=pem_bundle ttl=43800h \
        > "$OUT_DIR/pki_int.crt"
    vault write pki_int/intermediate/set-signed \
        certificate=@"$OUT_DIR/pki_int.crt"
    rm -f "$OUT_DIR/pki_int.csr"
fi

say "config/urls (CRL/issuing pod VAULT_ADDR)"
vault write pki/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/pki/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/pki/crl"
vault write pki_int/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/pki_int/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/pki_int/crl"

# ── 3. Role PKI (pki/ BEZ ról — root tylko podpisuje intermediate) ─
say "pki_int role: internal-server (serwery *.barvea.internal, 1y)"
vault write pki_int/roles/internal-server \
    allowed_domains=barvea.internal \
    allow_subdomains=true allow_bare_domains=true \
    allow_ip_sans=true allow_localhost=true \
    allow_wildcard_certificates=true \
    server_flag=true client_flag=false \
    key_type=rsa key_bits=2048 max_ttl=8760h

say "pki_int role: device (mTLS klienckie, EC P-256, any-name, 1y)"
vault write pki_int/roles/device \
    allow_any_name=true enforce_hostnames=false \
    allow_ip_sans=true allow_localhost=false \
    allow_bare_domains=false allow_subdomains=false \
    server_flag=false client_flag=true \
    key_type=ec key_bits=256 ttl=8760h max_ttl=8760h

# ── 4. Polityki (zrzut z proda; podział app na 3 = jak żywe nazwy;
#      suma uprawnień zweryfikowana identyczna 2026-07-10) ──────────
say "polityki"
vault policy write barvea-app-pki-sign - <<'EOF'
path "pki_int/sign/device" { capabilities = ["update"] }
EOF

vault policy write barvea-app-pki-revoke - <<'EOF'
path "pki_int/revoke"   { capabilities = ["update"] }
path "pki_int/cert/*"   { capabilities = ["read"] }
EOF

vault policy write barvea-app-transit - <<'EOF'
path "transit/sign/*"    { capabilities = ["update"] }
path "transit/verify/*"  { capabilities = ["update"] }
path "transit/hmac/*"    { capabilities = ["update"] }
path "transit/encrypt/*" { capabilities = ["update"] }
path "transit/decrypt/*" { capabilities = ["update"] }
EOF

vault policy write barvea-storage - <<'EOF'
path "transit/decrypt/per-org-keys"            { capabilities = ["update"] }
path "transit/datakey/plaintext/per-org-keys"  { capabilities = ["update"] }
EOF

# ── 5. AppRole (TTL jak prod: app 1h/24h, storage 1h/4h) ───────────
say "approle"
have_auth approle || vault auth enable approle
vault write auth/approle/role/barvea-app \
    token_ttl=1h token_max_ttl=24h \
    token_policies=barvea-app-pki-sign,barvea-app-pki-revoke,barvea-app-transit
vault write auth/approle/role/barvea-storage \
    token_ttl=1h token_max_ttl=4h token_policies=barvea-storage

if [ "${GEN_APPROLE_CREDS:-0}" = "1" ]; then
    say "approle creds → $OUT_DIR (0600; wpisz do env aplikacji i USUŃ)"
    for r in barvea-app barvea-storage; do
        vault read -field=role_id "auth/approle/role/$r/role-id" \
            > "$OUT_DIR/$r.role_id"
        vault write -f -field=secret_id "auth/approle/role/$r/secret-id" \
            > "$OUT_DIR/$r.secret_id"
        chmod 600 "$OUT_DIR/$r.role_id" "$OUT_DIR/$r.secret_id"
    done
fi

# ── 6. Transit keys (typy 1:1 z proda; wszystkie non-exportable) ───
say "transit keys"
have_key per-org-keys            || vault write -f transit/keys/per-org-keys type=aes256-gcm96
have_key audit-anchor            || vault write -f transit/keys/audit-anchor type=ed25519
have_key audit-key-derive        || vault write -f transit/keys/audit-key-derive type=hmac key_size=32
have_key jwt-signing             || vault write -f transit/keys/jwt-signing type=ecdsa-p256
have_key update-manifest-ed25519 || vault write -f transit/keys/update-manifest-ed25519 type=ed25519
have_key wdac-policy-ed25519     || vault write -f transit/keys/wdac-policy-ed25519 type=ed25519
have_key license-ed25519         || vault write -f transit/keys/license-ed25519 type=ed25519
# license-ed25519 (2026-07-14): podpisywanie licencji dedyk (gen-license przez
# transit sign; public key HARDCODE w obrazie APP). Non-exportable jak reszta.
# (test-key z proda pominięty celowo — artefakt testowy)

# ── 7. Audit (prod MA od 2026-07-10: file audit + logrotate
#      /etc/logrotate.d/vault-audit weekly/12/compress/copytruncate;
#      przy fresh-install odpalaj z ENABLE_AUDIT=1 żeby odtworzyć).
# UWAGA: gdy audit device przestanie być zapisywalny (pełny dysk),
# Vault BLOKUJE wszystkie requesty (by design). Zapewnij logrotate.
if [ "${ENABLE_AUDIT:-0}" = "1" ]; then
    say "audit: file → /opt/vault/audit.log"
    vault audit list -format=json 2>/dev/null | grep -q '"file/"' || \
        vault audit enable file file_path=/opt/vault/audit.log
fi

# ── 8. TLS samego Vaulta (OPCJA) — prod ma DEFAULTOWY self-signed
#      bez SANs (CN=Vault) → klienci muszą skip-verify/pinować.
#      Po bootstrapie PKI można wystawić porządny cert z pki_int: ──
if [ "${ISSUE_VAULT_TLS:-0}" = "1" ]; then
    CN="${VAULT_TLS_CN:-vault.barvea.internal}"
    IP="${VAULT_TLS_IP:-10.10.0.50}"
    say "TLS Vaulta: $CN + IP SAN $IP → $OUT_DIR/vault-tls.{crt,key}"
    vault write -format=json pki_int/issue/internal-server \
        common_name="$CN" ip_sans="$IP,127.0.0.1" ttl=8760h \
        > "$OUT_DIR/vault-tls.json"
    python3 - "$OUT_DIR" <<'PYEOF'
import json, os, sys
d = sys.argv[1]
j = json.load(open(os.path.join(d, "vault-tls.json")))["data"]
crt = j["certificate"] + "\n" + "\n".join(j.get("ca_chain", [])) + "\n"
open(os.path.join(d, "vault-tls.crt"), "w").write(crt)
open(os.path.join(d, "vault-tls.key"), "w").write(j["private_key"] + "\n")
os.chmod(os.path.join(d, "vault-tls.key"), 0o600)
os.remove(os.path.join(d, "vault-tls.json"))
PYEOF
    echo "   Instalacja: cp → /opt/vault/tls/tls.{crt,key}; chown vault;"
    echo "   systemctl reload vault   (reload=SIGHUP przeładowuje TLS"
    echo "   BEZ reseal; restart = SEALED = unseal 3/5 od nowa!)"
fi

say "DONE. Artefakty: $OUT_DIR (root-ca.crt → /etc/barvea/root-ca.crt na nodach)"
