# BARVEA Vault — IaC (LXC 200 @10.10.0.50, Vault 2.0.0)

Zrzut konfiguracji z żywego proda **2026-07-10** (read-only). ⚠️ KEEP-IN-SYNC:
każda zmiana polityk/ról/kluczy na żywym → dopisz do `bootstrap-vault.sh`.

## Dwie ścieżki DR — NIE pomylić

| Scenariusz | Ścieżka |
|---|---|
| **Odtworzenie ISTNIEJĄCEJ instancji** (awaria LXC/hosta) | restic-restore `/opt/vault/data` + ten sam binary + `vault.hcl` (template tutaj) + **unseal Shamir 3/5** (klucze: Bitwarden). Stare CA/klucze transit/dane NIETKNIĘTE. |
| **Świeża instalacja** (nowy serwer / dedyk u klienta) | `bootstrap-vault.sh` — tworzy NOWE CA + NOWE klucze transit. Stara zawartość (certy urządzeń, zaszyfrowane dane org) będzie NIEczytelna — to celowe (nowa instancja = nowy świat kluczy). |

## Co pokrywa bootstrap-vault.sh
- engines: `pki` (root, max 10y), `pki_int` (5y), `transit`, `secret` (KV v2)
- Root CA „BARVEA Root CA" (RSA2048/10y) → Intermediate „BARVEA Intermediate CA" (RSA2048/5y)
- role: `internal-server` (serwery `*.barvea.internal`, RSA2048, 1y), `device` (mTLS klienckie, EC P-256, any-name, 1y)
- polityki: `barvea-app-pki-sign` / `-pki-revoke` / `-transit`, `barvea-storage`
- AppRole: `barvea-app` (1h/24h, 3 polityki), `barvea-storage` (1h/4h)
- transit: `per-org-keys` (aes256-gcm96, envelope przez `datakey/plaintext`),
  `audit-anchor` (ed25519), `audit-key-derive` (hmac32), `jwt-signing`
  (ecdsa-p256), `update-manifest-ed25519`, `wdac-policy-ed25519` (ed25519)
- opcje: `GEN_APPROLE_CREDS=1` (role_id+secret_id → OUT_DIR, wpisz do env
  aplikacji i usuń), `ENABLE_AUDIT=1`, `ISSUE_VAULT_TLS=1`

## Czego NIE pokrywa (świadomie)
- **init/unseal** — `vault operator init` robi się RAZ, ręcznie; klucze Shamir
  (5 shares, próg 3) + root token → Bitwarden. Nigdy do git/skryptu.
- sekrety w KV (`secret/`) — prod trzyma tam tylko `test`; realne sekrety idą
  transit+AppRole, nic do odtwarzania.
- `agent-registry/` — builtin Vault 2.0, montuje się sam.

## Znane odstępstwa na prodzie (stan 2026-07-10)
- ✅ **Audit device WŁĄCZONY 2026-07-10**: `file → /opt/vault/audit.log`
  + logrotate `/etc/logrotate.d/vault-audit` (weekly, rotate 12, compress,
  copytruncate). Fresh-install: `ENABLE_AUDIT=1` + odtwórz logrotate
  (uwaga: niedostępny audit = Vault blokuje requesty by design).
- 🚩 **TLS listenera = defaultowy self-signed** (CN=Vault, zero SANs) →
  klienci używają skip-verify/pinowania pliku. Fix: `ISSUE_VAULT_TLS=1`
  po bootstrapie PKI, podmiana `/opt/vault/tls/*`, `systemctl reload vault`
  (**reload, NIE restart** — restart = sealed = unseal 3/5 od nowa).
- `test-key` w transit — artefakt testowy, bootstrap go nie odtwarza.
