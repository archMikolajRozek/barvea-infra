# BARVEA — VM 101 barvea-data: Postgres (zrzut żywy 2026-07-13)

⚠️ KEEP-IN-SYNC. Uzupełnia proxmox/README.md (defy VM).

## Jak stoi
- **PGDG apt** (apt.postgresql.org, pakiet `postgresql-18` 18.3-1.pgdg13+1
  + `postgresql-18-jit`), bare-metal (NIE docker). Pozostałość `rc postgresql-17`
  (upgrade 17→18 był).
- Klaster `18/main`, unit **`postgresql@18-main.service`**, port 5432,
  data `/var/lib/postgresql/18/main`.
- `ssl = on` z **certami snakeoil** (self-signed pakietowe) — LAN-only, ale
  przy dedyk/instalatorze: wystawić cert z pki_int (internal-server) — TODO.
- Config prawie STOCK: `shared_buffers = 128MB` (!) przy 24G RAM VM,
  max_connections=100, timezone Europe/Warsaw. **TODO TUNING** (przy okazji,
  nie pilne): shared_buffers ~6GB, effective_cache_size ~16GB, work_mem,
  wal_compression — osobna decyzja, wymaga restartu PG.
- sshd VM: port **2277** (jak host; VM 100 ma domyślny 22).
- Sieć: `/etc/network/interfaces` statyczne `10.10.0.20/24 gw 10.10.0.1`,
  DNS 1.1.1.1/1.0.0.1; `/etc/hosts`: `10.10.0.20 barvea-data`.

## pg_hba.conf (wpisy nie-domyślne, verbatim)
```
host  barvea  barvea_app    10.10.0.0/24   scram-sha-256
host  barvea  barvea_app    10.10.0.30/32  scram-sha-256
host  barvea  barvea_admin  10.10.0.30/32  scram-sha-256
host  all     postgres      10.9.0.0/24    scram-sha-256   # admin przez wg0
host  all     barvea_admin  10.9.0.0/24    scram-sha-256
host  all     postgres      10.10.0.0/24   scram-sha-256
```
DB: `barvea`. Role: `barvea_app` (aplikacja), `barvea_admin`, `postgres`.
Hasła: manager haseł / .env.production (DATABASE_URL). Dostęp: LAN + tunel
admin wg0 (10.9/24). listen_addresses nie w dumpie — sprawdzić przy tuningu
(musi obejmować 10.10.0.20).

## Przepis bootstrap (fresh)
```bash
apt install -y postgresql-common
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
apt install -y postgresql-18 postgresql-18-jit
# pg_hba: dopisz wpisy j.w.; postgresql.conf: listen_addresses='localhost,10.10.0.20'
sudo -u postgres createuser barvea_app -P; sudo -u postgres createuser barvea_admin -P
sudo -u postgres createdb -O barvea_app barvea
systemctl restart postgresql@18-main
# migracje: prisma migrate deploy (z app, przez deploy.sh)
```
Backup: restic barvea-data 03:09 (pg_dump) + pre-deploy pgcustom (deploy.sh).
