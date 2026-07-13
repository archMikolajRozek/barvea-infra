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
# passphrase: wygenerowana → zawinąć Vault transit per-org-keys →
#   zapisz ciphertext do /etc/zfs/keys/<orgId>.ct (patrz zfs-load-org.sh)
# bind-mount do LXC 201 (KAŻDY nowy org = nowy mpN — patrz README.md):
pct set 201 -mp<N> /hddpool/orgs/<orgId>,mp=/srv/orgs/<orgId>
# w LXC 201: groupadd org-<orgId> (gid 50xx), chown root:org-<gid> +
#   2770 na kontenerach WIP/Shared/Published/Archive, share [<slug>] w
#   /etc/samba/per-org/ + include, ORG_SLUGS w acl-sync.env.
# ⚠️ provision-org.sh NIE ISTNIEJE (find po hoście: brak) — org-provision
#   to dziś RĘCZNA procedura (powyższe kroki); skrypt = backlog.
```

## 🔴 DR — szyfrowanie org-datasetów (KRYTYCZNE, kolejność po reboocie)

`keylocation=prompt`, ale klucze NIE są wpisywane ręcznie — **envelope
przez Vault**: passphrase per-org zawinięta transitem `per-org-keys`
leży jako ciphertext w `/etc/zfs/keys/<orgId>.ct` (host). Odblokowuje
`/usr/local/sbin/zfs-load-org.sh` (kopia: `zfs-load-org.sh` obok;
AppRole creds: `/etc/vault/storage-approle` — NIE w git).

**Po reboocie hosta (ręczna sekwencja — nic tego nie automatyzuje):**
```bash
# 1. Vault UP + UNSEAL (LXC 200 wstaje sam, ale SEALED — Shamir 3/5)
pct enter 200   # vault operator unseal ×3
# 2. odblokuj org-datasety (host)
/usr/local/sbin/zfs-load-org.sh
# 3. restart storage, żeby bind-mounty złapały zamontowane datasety
pct stop 201 && pct start 201
```

LXC 201 `onboot=1` wstaje PRZED odblokowaniem → Samba pokazuje **puste
share'y po cichu** (nie błąd!) dopóki nie zrobisz kroków 1-3. Łańcuch
zależności: **unseal → zfs-load-org.sh → restart 201**. Nowy org =
nowy `/etc/zfs/keys/<orgId>.ct` (passphrase wrap transitem przy
tworzeniu datasetu).

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
