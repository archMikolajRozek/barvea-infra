# Hardening obsługi plików — runbook wdrożenia (audyt 2026-09-24)

Źródło: `app/docs/INFRA_SECURITY_REQUEST_2026-09.md`. Strona APP zamknięta na
branchu `fix/mtls-serial-normalization` (klient ClamAV ciemny do czasu env,
CSP Report-Only). Poniżej TYLKO to, co po stronie infra. Kolejność ma znaczenie:
najpierw storage (niezależne od appki), potem VM 102, na końcu env appki.

| # | Co | Gdzie | Ręcznie? |
|---|---|---|---|
| 1 | Samba `veto files` (global) | LXC 201 | TAK — push + include + reload |
| 2 | Sidecary: non-root, read-only, tmpfs, cap_drop, mem_limit, sieć bez egressu | VM 102 (compose) | TAK — pull + `up -d` + testy konwersji |
| 3 | ClamAV (clamd) | LXC 201 (NIE kontener na VM 102 — patrz `storage/clamav/clamd.conf`) | TAK — apt + config + freshclam |
| 4 | CSP w Caddy | — | NIC. Caddyfile nie ustawia CSP (zweryfikowane grep). |
| 5 | env `AV_*` appki + recreate | VM 102 | TAK — po potwierdzeniu, że clamd żyje |

`ifc-extractor` z prośby APP **nie jest wdrożony** (brak serwisu w compose,
brak `IFC_EXTRACTOR_URL` w env) — hardening dotyczy trzech działających sidecarów.

## Krok 1 — Samba veto (LXC 201, ~5 min)

Plik `storage/samba/barvea-veto.conf` (lista = `BLOCKED_EXTENSIONS` appki).
Kanał jak zawsze: barvea-app → scp → host → pct push.

```bash
# barvea-app
scp -P 2277 ~/barvea/storage/samba/barvea-veto.conf ~/barvea/storage/clamav/clamd.conf ~/barvea/storage/barvea-acl-sync.py root@10.10.0.1:/tmp/
# host
pct push 201 /tmp/barvea-veto.conf /etc/samba/barvea-veto.conf
pct exec 201 -- grep -c "barvea-veto" /etc/samba/smb.conf        # 0 = trzeba dopisać include
pct exec 201 -- sed -i '/^\[global\]/a \   include = /etc/samba/barvea-veto.conf' /etc/samba/smb.conf
pct exec 201 -- testparm -s 2>&1 | grep -iE "veto|error|unknown"  # ma pokazać veto files, zero błędów
pct exec 201 -- smbcontrol all reload-config                        # veto ≠ vfs → bez restartu
# acl-sync (per-org veto = SECURITY ∪ kategorie, inaczej share-level nadpisałby global):
pct push 201 /tmp/barvea-acl-sync.py /usr/local/sbin/barvea-acl-sync.py
pct exec 201 -- chmod 755 /usr/local/sbin/barvea-acl-sync.py
```
Test: z Windowsa przez udział skopiuj `test.exe`/`acad.lsp` → „odmowa dostępu"
albo plik znika z listingu. Efekt uboczny: istniejące pliki z listy znikają
z widoku SMB (nie są kasowane, web je widzi).

## Krok 2 — sidecary (VM 102, ~15 min + testy)

```bash
cd ~/barvea && git pull --ff-only origin main
docker compose --env-file .env.production config >/dev/null && echo CONFIG-OK
docker compose --env-file .env.production up -d --no-deps dwg-converter office-converter point-cloud-preview
docker compose --env-file .env.production ps
docker exec barvea-dwg-converter id -u        # 57439
docker exec barvea-office-converter sh -c 'touch /app/x 2>&1 | head -1; touch /tmp/x && echo TMP-OK'   # /app: Read-only, /tmp OK
```
Testy funkcjonalne (to jest to, o co prosił APP — `user:` bez testu = wiara):
podgląd DWG, konwersja DOCX→PDF, podgląd chmury punktów. Przy failu: logi
kontenera; typowe: brak zapisu poza /tmp (dodać tmpfs), za mały mem_limit
(OOM-kill widoczny w `docker inspect --format '{{.State.OOMKilled}}'`).

Uwaga na deploy.sh: od tej zmiany konwertery idą przez zwykłe `up -d` —
compose sam wykrywa zmianę obrazu LUB konfiguracji.

## Krok 3 — ClamAV (LXC 201, ~15 min, freshclam ciągnie ~300 MB)

Pełny przepis: `storage/clamav/README.md`. Skrót:
```bash
pct set 201 -memory 12288
pct exec 201 -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y clamav-daemon clamav-freshclam >/dev/null; systemctl stop clamav-daemon"
pct push 201 /tmp/clamd.conf /etc/clamav/clamd.conf
pct exec 201 -- bash -c "systemctl enable --now clamav-freshclam; freshclam --quiet || true; systemctl restart clamav-daemon; sleep 20; ps -o user= -C clamd; ss -ltnp | grep 3310"
```
Ma być: `root` i `10.10.0.40:3310`. Potem test EICAR z README.

## Krok 4 — env appki + recreate (VM 102)

Dopisz blok `AV_*` z `storage/clamav/README.md` do `~/barvea/.env.production`
(`AV_MODE=warn`), potem:
```bash
docker compose --env-file .env.production up -d --no-deps --force-recreate app
docker exec barvea-app sh -c 'printenv AV_CLAMD_HOST AV_MODE'
```
Test E2E: `eicar.txt` przez web → wpis w Błędach systemu (kategoria security).
Po tygodniu bez fałszywych alarmów: `AV_MODE=block` + recreate app.

## Kolejność względem deployu appki
Kroki 1–3 nie zależą od kodu appki — robić PRZED merge'em. Deploy branchu
(`./scripts/deploy.sh` po merge) — kiedykolwiek. Krok 4 dopiero, gdy clamd
odpowiada (inaczej appka co 10 min raportuje „clamd niedostępny").
