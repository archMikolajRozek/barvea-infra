# BARVEA — ZFS layout (barvea-host, zrzut 2026-07-13)

⚠️ KEEP-IN-SYNC. Autorytatywne: żywy `zpool`/`zfs get` na hoście.

## Pool

```
hddpool: RAIDZ2 z 4× WDC WUH722222ALE6L1 (22T HDD), ashift=12, autotrim=off
scrub: cotygodniowy (nd ~01:00, ~45 min) — Debian domyślny zfsutils timer
```

Właściwości pool-level (`zfs get -s local all hddpool`):
```
compression=lz4   atime=off   xattr=sa   acltype=posix
```

## Drzewo datasetów

```
hddpool/orgs                      compression=zstd (nadpisuje lz4), mountpoint=/hddpool/orgs
hddpool/orgs/<orgId>              per-org CDE store (przepis niżej)
hddpool/orgs/test-org-001         testowy, BEZ szyfrowania/refquota
hddpool/subvol-200-disk-0         LXC 200 vault rootfs (8G)
hddpool/subvol-201-disk-0         LXC 201 storage rootfs (16G)
hddpool/vm-100/101/102-disk-*     dyski VM (zvole Proxmoxa)
```

## Przepis: nowy org-dataset (rekonstrukcja z żywych właściwości)

Właściwości LOCAL na org-datasecie (wzorzec `cmoiknvvz…`):
`compression=zstd, xattr=sa, acltype=posix, refquota=2T, keylocation=prompt`
+ `encryption=aes-256-gcm` (tylko przy create — niezmienialne później).

```bash
zfs create -o encryption=aes-256-gcm -o keyformat=passphrase \
  -o keylocation=prompt -o compression=zstd -o xattr=sa \
  -o acltype=posix -o refquota=2T hddpool/orgs/<orgId>
# passphrase → Bitwarden (per-org!)
# bind-mount do LXC 201 (KAŻDY nowy org = nowy mpN — patrz README.md):
pct set 201 -mp<N> /hddpool/orgs/<orgId>,mp=/srv/orgs/<orgId>
# w LXC: grupa org-<orgId>, chown root:org-<gid> + 2770 na kontenerach —
# robi provision-org.sh (⚠️ TODO: żyje na hoście, NIE w repo — wciągnąć).
```

## 🔴 DR — szyfrowanie z keylocation=prompt (KRYTYCZNE)

Po **reboocie hosta** org-datasety są LOCKED (klucz nie jest nigdzie na
dysku). Kolejność ręczna ZANIM storage wstanie:

```bash
zfs load-key hddpool/orgs/<orgId>     # per dataset, passphrase z Bitwarden
zfs mount -a
pct start 201                          # dopiero teraz Samba widzi dane
```

LXC 201 ma `onboot=1` — wstanie z PUSTYMI mountpointami jeśli klucze
niezaładowane → Samba pokaże puste share'y (nie błąd, cisza!). Po
load-key + mount → `pct stop 201 && pct start 201` (żeby bind-mounty
złapały zamontowane datasety).

## Snapshoty — sanoid (host, `/etc/sanoid/sanoid.conf` → kopia obok)

```
[hddpool] use_template=production, recursive=yes, process_children_only=yes
[template_production] hourly=24 daily=7 weekly=4 monthly=6 yearly=0
                      autosnap=yes autoprune=yes frequent_period=0
```
Timer: `sanoid.timer` co 15 min. Nazwy `autosnap_YYYY-MM-DD_HH:MM:SS_hourly`
= dokładnie to, co czyta `shadow_copy2` w Sambie (Previous Versions na B:)
— **zmiana formatu/prefixu sanoida ZEPSUJE Previous Versions** (patrz
`storage/samba/smb.conf.global.template` shadow:format).
