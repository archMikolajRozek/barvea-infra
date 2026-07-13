# BARVEA — OS-basics gości (zrzut żywy 2026-07-13)

⚠️ KEEP-IN-SYNC. Rzeczy „oczywiste", bez których fresh-build nie wstanie.

## SSH porty
| Węzeł | Port |
|---|---|
| barvea-host | **2277** (+fail2ban) |
| VM 100 barvea-infra | **22** (jedyny wyjątek — ujednolicić przy okazji?) |
| VM 101 barvea-data | 2277 |
| VM 102 barvea-app | 2277 |

Klucz `miko@barvea-app` jest w `/root/.ssh/authorized_keys` HOSTA →
kanał deploy: `scp -P 2277 <pliki> root@10.10.0.1:...` (app→host;
odwrotnie NIE działa — firewall app dropuje SSH od hosta).

## Sieć gości — wzorzec /etc/network/interfaces (identyczny na VM)
```
allow-hotplug ens18
iface ens18 inet static
    address 10.10.0.<X>/24     # 10=infra, 20=data, 30=app
    gateway 10.10.0.1
    dns-nameservers 1.1.1.1 1.0.0.1
```
`/etc/hosts` per VM: tylko własny wpis (`10.10.0.X <hostname>`).
Host: publiczny IPv4 178.63.205.222 + IPv6 2a01:4f8:2240:13d5::2
(barvea-host.local barvea-host).

## Nazwy internal — gdzie resolve
`app.barvea.internal` (Caddy internal vhost, cert pki_int) i
`drive.barvea.internal` (Samba) NIE są w hosts VM-ek — resolve żyje:
- LXC 201: /etc/hosts (acl-sync → app.barvea.internal) — [potwierdzić wpis]
- klienty Windows (Drive): wpis hosts stawiany przez klienta/instalację
- fresh-build: dopisać do hosts LXC 201 + dokumentacji klienta

## Docker
Tylko VM 102: Docker 29.4.1 (repo dockera, nie debianowy). Compose v2
(`docker compose`). VM 101 = Postgres bare-metal (patrz vm101-postgres.md),
VM 100 = bez dockera.

## Gotcha heredoc (lekcja z tworzenia per-org confów)
Pliki tworzone heredokiem przez PuTTY z WCIĘTYM terminatorem `EOF` →
terminator nie łapie → kolejne komendy lądują W PLIKU (archbimcloud.conf
miał w ogonie `EOF`+`grep`+`smbcontrol`; Samba ignorowała śmieć — działało,
wyczyszczone 2026-07-13 sedem `/directory mask = 0700/q`). Przy ręcznych
heredokach: terminator ZAWSZE od kolumny 0 + weryfikuj `tail` po zapisie.
