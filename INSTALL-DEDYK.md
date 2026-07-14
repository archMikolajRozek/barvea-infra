# BARVEA — instalacja dedyk / DR (runbook)

Od gołego serwera do działającej instancji. Ten sam flow = nowy dedyk u
klienta **i** odtworzenie/drugi serwer. ⚠️ Stan 2026-07-14: bootstrap+vault
DOWIEDZIONE na stagingu; wizard/compact/deploy-app/offline = NAPISANE, test
po dowiezieniu bundla APP (na stagingu z migawki `czysty-bootstrap`).

## 0. Przygotowanie (ręczne, jedyne klik-klik)
1. Serwer fizyczny → **Debian + Proxmox VE** z ISO (~30 min; u klienta ich IT
   wg tej strony). Sieć zarządzania, dysk systemowy.
2. Dyski na dane (pool ZFS) — NIE partycjonować, zostawić surowe.
3. **Air-gap:** zbuduj nośnik na maszynie z netem: `./build-offline-assets.sh
   /media/barvea-assets` → wrzuć `bundle/` od APP → przenieś na serwer klienta.

## 1. Kreator → konfiguracja
```bash
git clone <barvea-infra> /root/barvea-infra   # albo z nośnika (air-gap)
cd /root/barvea-infra
./wizard.sh                                    # whiptail: tryb, pool, sieć, WG,
                                               # air-gap/FQDN, backup, licencja
```
Wynik: `bootstrap.conf`. (Bez kreatora: `cp bootstrap.conf.example bootstrap.conf`
+ edytuj ręcznie.)

## 2. Bootstrap infry
```bash
./bootstrap.sh                                 # pool→goście→usługi→verify
```
- Idempotentny (checkpointy `/var/lib/barvea-bootstrap`; przerwiesz→wznowi).
- Tworzy WSZYSTKICH gości sam (LXC+VM cloud-init) — zero klikania w Proxmoxie.
- Hasła/tokeny → `/root/barvea-bootstrap-creds.txt` (0600).

## 3. Ceremonia Vault (jedyny ręczny krok w środku)
```bash
pct enter 200
export VAULT_ADDR=https://<LAN>.50:8200 VAULT_SKIP_VERIFY=1
vault operator init            # ZAPISZ 5 kluczy Shamir + root token!
vault operator unseal          # ×3 (trzy różne klucze)
export VAULT_TOKEN=<root>
/root/bootstrap-vault.sh        # PKI/CA/role/polityki/AppRole/transit
# root-ca.crt (./vault-out) → /etc/barvea/root-ca.crt na LXC 201
unset VAULT_TOKEN; exit
```
**Opcja „podział kluczy" (klient na żądanie):** rozdaj 5 udziałów Shamira wg
umowy (np. klient 3 / my 2) zamiast trzymać komplet. Domyślnie: komplet u
operatora instancji. **Po reboocie hosta:** unseal → `zfs-load-org.sh` →
`pct restart 201` (patrz proxmox/zfs-layout.md).

## 4. Aplikacja + licencja + superadmin (dedyk)
```bash
# BUNDLE_DIR z nośnika/od APP (images.tar, compose.dedicated.yml, env.template, scripts/)
BUNDLE_DIR=/media/barvea-assets/bundle \
  ADMIN_EMAIL=admin@klient.pl ADMIN_ORG="Klient" \
  BOOTSTRAP_ADMIN_PASSWORD='...' \
  LICENSE_FILE=/root/klient.license \
  ./deploy-app.dedicated.sh
```
Robi: docker load → .env.production (DEPLOYMENT_MODE=dedicated ×2 env) →
compose up (migracje w entrypoincie) → health → superadmin (2FA) →
apply-license. Bez LICENSE_FILE → instancja UNLICENSED (read-only, wgrasz
licencję w panelu platform-admin).

**Licencja generowana U NAS** (nie u klienta): na naszym Vaulcie
`python3 vault/gen-license.py --org "Klient" --type STANDARD --days 365
--modules cde,cmms,drive --max-users 20` → plik → klientowi. Odnowienie:
nowy token → panel klienta (POST /api/v1/admin/license) albo LICENSE_FILE+re-run.

## 5. Backup off-site
`backup/README.md` — klucz SSH→Storage Box (lub SFTP klienta), hasło repo,
instal host-backup + timer. Air-gap: backup na lokalny NAS/dysk klienta.

## 6. Pierwszy projekt / org-provision
`proxmox/zfs-layout.md` — dataset org (aes-256-gcm + .ct) + mpN na LXC 201 +
share per-org + ORG_SLUGS. (Dziś ręczne; org-provision daemon = backlog.)

---
## Mapa plików installera
| Plik | Rola |
|---|---|
| `wizard.sh` | kreator whiptail → bootstrap.conf (faza 0) |
| `bootstrap.sh` + `bootstrap.conf.example` | infra: host+goście+usługi (fazy 1-3) |
| `vault/bootstrap-vault.sh` | Vault: PKI/role/transit (ceremonia) |
| `vault/gen-license.py` | generator licencji (U NAS) |
| `deploy-app.dedicated.sh` | app+licencja+superadmin (fazy 4-5) |
| `build-offline-assets.sh` | nośnik air-gap (templates+apt-mirror) |
| `backup/`, `proxmox/`, `network/`, `storage/`, `vault/` | źródła prawdy per komponent |

## Presety (bootstrap.conf: PRESET=)
- `prod` — 5 gości, layout jak nasz serwer (default)
- `staging` — mali goście, VM-w-VM (test)
- `compact` — 1 VM all-in-one (mały dedyk; DB/redis/minio=kontenery bundla;
  bez Vault/Samba/WG — moduł drive niedostępny)
