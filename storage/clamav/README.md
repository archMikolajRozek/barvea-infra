# ClamAV (clamd) — LXC 201 barvea-storage

Jeden daemon, dwa tryby dla appki (`lib/antivirus.ts`):
- **INSTREAM** — uploady web/plugin, appka streamuje bajty po LAN do `10.10.0.40:3310`
- **SCAN `<ścieżka>`** — ingest z Drive: clamd czyta plik wprost z `/srv/orgs/<org>/<ścieżka>`

Dlaczego LXC 201, nie kontener na VM 102: patrz nagłówek `clamd.conf` (ZFS orgów
widoczny tylko tu; pliki 0600 → clamd jako root w nieuprzywilejowanym LXC).

## Instalacja / update (host Proxmox)

```bash
pct set 201 -memory 16384                                  # 8→16 G (live, bez restartu): sygnatury ~1.5 G + zapas, host ma 128 G
pct exec 201 -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y clamav-daemon clamav-freshclam >/dev/null"
pct exec 201 -- systemctl stop clamav-daemon
pct push 201 storage/clamav/clamd.conf /etc/clamav/clamd.conf      # (plik ze scp-owanego repo: app→/tmp na hoście)
pct exec 201 -- bash -c "systemctl enable --now clamav-freshclam; freshclam --quiet || true"   # 1. pobranie baz ~300 MB
# TCP 3310: Debian aktywuje clamd przez systemd socket, wtedy TCPSocket z
# clamd.conf jest IGNOROWANY — port dodajemy override'em socketu:
pct exec 201 -- mkdir -p /etc/systemd/system/clamav-daemon.socket.d
pct push 201 storage/clamav/clamav-daemon.socket-tcp.conf /etc/systemd/system/clamav-daemon.socket.d/tcp.conf
pct exec 201 -- bash -c "systemctl daemon-reload; systemctl restart clamav-daemon.socket clamav-daemon"
pct exec 201 -- bash -c "sleep 20; ps -o user= -C clamd; ss -ltnp | grep 3310"   # root + 10.10.0.40:3310
```
Gotcha z wdrożenia 2026-09-24: `apt-get install` padł na 404 (stary indeks) —
`apt-get update` najpierw. Bez override'u socketu port 3310 nie wstaje mimo
poprawnego clamd.conf.

Test lokalny (EICAR):
```bash
pct exec 201 -- bash -c "printf 'X5O!P%%@AP[4\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*' > /tmp/eicar.txt; clamdscan --fdpass /tmp/eicar.txt; rm -f /tmp/eicar.txt"
```
Oczekiwane: `Eicar-Test-Signature FOUND`.

## Env appki (`~/barvea/.env.production` na barvea-app)

```
AV_CLAMD_HOST=10.10.0.40
AV_CLAMD_PORT=3310
AV_MODE=warn              # tydzień obserwacji w Błędach systemu (kategoria security) → block
AV_REQUIRED=0             # fail-open przy niedostępnym clamd (raport co 10 min); 1 = odrzucaj uploady
AV_MAX_BYTES=2147483648
AV_DRIVE_MOUNT=/srv/orgs
AV_DRIVE_PATH_TEMPLATE={mount}/{orgId}/{path}   # {path} = jak dla datad (<proj>/<Cont>/...)
```
Po dopisaniu: `docker compose --env-file .env.production up -d --no-deps --force-recreate app`.

Test E2E: upload `eicar.txt` przez web → w `warn` wpis „[antywirus] WYKRYTO
Eicar-Test-Signature…" w Błędach systemu; w `block` → 422 MALWARE. To samo przez SMB.

## Pamięć
clamd ~1.5 GB RSS (sygnatury) + skoki przy skanie dużych archiwów. LXC 201 po
zmianie: 16 G (Samba + datad + acl-sync + clamd). `ConcurrentDatabaseReload no`
= reload nie dubluje pamięci.
