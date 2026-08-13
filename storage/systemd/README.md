# BARVEA systemd units (IaC — dla appliance/bootstrap)

Wszystkie service/timer instancji. Docelowo `bootstrap.sh` kopiuje je do
`/etc/systemd/system/` na odpowiedniej maszynie + `daemon-reload` + `enable --now`.

| Unit | Gdzie żyje | Rola |
|---|---|---|
| `barvea-datad.service` (../barvea-datad.service) | LXC 201 storage | CDE data-plane :8723 (files/promote/fs-journal/fs-tree/dl/lock/rename) + full_audit→journal thread |
| `smb-provisiond.service` (../smb-provisiond.service) | LXC 201 storage | SMB user provisioning :8722 |
| `barvea-acl-sync.service` + `.timer` | LXC 201 storage | ACL manifest→POSIX ACL puller (timer 60s) |
| `../../wg-control/wg-provisiond.service` | barvea-infra VM | WG peer control-plane :8721 |
| restic backup timers (3 VM) | 100/101/102 | nightly → Hetzner Storage Box (patrz [[project_barvea_backup_setup]]) — DO wyeksportowania |

## Config zależności (env/pliki na maszynie, NIE w git — sekrety):
- `/etc/barvea/barvea-datad.env` (TOKEN, SIGN_KEY, PUBLIC_DL_BASE, DL_TTL)
- `/etc/barvea/smb-provisiond.env` (TOKEN, UID_START)
- `/etc/barvea/wg-provisiond.env` (TOKEN, BIND, WG_IFACE, WG_CONF)
- `/etc/barvea/acl-sync.env` (DRIVE_ACL_SERVICE_TOKEN, ORG_SLUGS, APP_URL, CA_FILE)
- `/etc/barvea/root-ca.crt` (z Vault pki/ca/pem)
- hosts: `10.10.0.30 app.barvea.internal` (LXC 201)

## Update usługi w LXC 201 (barvea-datad / smb-provisiond / barvea-acl-sync)

Repo **nie jest** sklonowane ani na barvea-host, ani na barvea-infra —
jedyny checkout to `~/barvea` na **barvea-app (10.10.0.30, ssh port 2277)**.
LXC 201 siedzi na Proxmoxie, więc plik idzie okrężnie: app → scp → host → `pct push`
(host→app SSH nie działa, firewall appki dropuje — patrz `proxmox/os-basics.md`).

```bash
# 1. barvea-app (10.10.0.30:2277)
git -C ~/barvea pull --ff-only origin main
md5sum ~/barvea/storage/barvea-datad.py
scp -P 2277 ~/barvea/storage/barvea-datad.py root@10.10.0.1:/tmp/

# 2. barvea-host (178.63.205.222:2277)
pct push 201 /tmp/barvea-datad.py /usr/local/sbin/barvea-datad.py
pct exec 201 -- chmod 755 /usr/local/sbin/barvea-datad.py
pct exec 201 -- md5sum /usr/local/sbin/barvea-datad.py    # MUSI zgadzać się z krokiem 1
pct exec 201 -- systemctl restart barvea-datad            # ubija data-plane na ~1s
pct exec 201 -- journalctl -u barvea-datad -n 15 --no-pager
```

Restart przerywa trwające uploady/downloady i operacje Drive — nie rób w trakcie
wrzucania dużego pliku. Weryfikacja md5 przed restartem jest obowiązkowa
(analogia do wtopy z bind-mountem Caddy — „push się udał" ≠ „plik doszedł").

Smoke test `/dl/` po zmianach w datad (link świeży, HMAC TTL 900 s):
```powershell
curl.exe -s -r 0-9 -D - -o NUL "https://app.barvea.com/dl/..."   # → 206 + content-range
```
`curl -I` NIE nadaje się — wysyła HEAD, na którym datad ignoruje Range i zwraca 200.

## TODO IaC (do wyeksportowania do repo — read-only z proda):
- [ ] Vault bootstrap (PKI Root+Intermediate, transit per-org-keys, AppRole barvea-app/barvea-storage, role device/internal-server) → `vault/bootstrap-vault.sh` idempotentny
- [ ] iptables BARVEA_USER_IN + nftables host → `network/*.rules`
- [ ] WireGuard wg-users.conf template (BEZ kluczy) + wg0 admin
- [ ] ZFS pool+dataset layout (properties: acltype=posixacl xattr=sa encryption)
- [ ] .env.production → .env.example (nazwy zmiennych, bez wartości)
- [ ] restic timers 3× VM
- [ ] master `bootstrap.sh` orkiestrujący
