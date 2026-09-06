# BARVEA — Proxmox guest defs (barvea-host, zrzut `pct/qm config` 2026-07-13)

⚠️ KEEP-IN-SYNC. Żywe pliki: `/etc/pve/lxc/<id>.conf`, `/etc/pve/qemu-server/<id>.conf`.
ZFS/datasety/sanoid: `zfs-layout.md`. Sieć/firewall: `../network/README.md`.

Host: Hetzner SX65 (2×NVMe system + 4×HDD 22T RAIDZ2 `hddpool`),
Debian + Proxmox, mostki: `vmbr0` (publiczny), `vmbr1` (LAN 10.10.0.0/24, gw .1).

## Kolejność startu (startup order + ręczny krok ZFS!)
1. **RĘCZNIE po reboocie: `zfs load-key` org-datasetów** (zfs-layout.md — bez
   tego storage wstaje z pustymi share'ami!)
2. VM 100 barvea-infra (order=1) → 3. VM 101 barvea-data (2) → 4. VM 102
   barvea-app (3); LXC 200/201 `onboot=1` (bez ordera).

## LXC 200 — vault (10.10.0.50)
```
arch: amd64 / ostype: debian / unprivileged: 1 / features: nesting=1 / onboot: 1
cores: 2 / memory: 2048 / swap: 512
rootfs: hdd-pool:subvol-200-disk-0,size=8G
net0: name=eth0,bridge=vmbr1,gw=10.10.0.1,ip=10.10.0.50/24
```

## LXC 201 — barvea-storage (10.10.0.40, Samba+datad)
```
arch: amd64 / ostype: debian / unprivileged: 1 / features: nesting=1 / onboot: 1
cores: 4 / memory: 8192 / swap: 512
rootfs: hdd-pool:subvol-201-disk-0,size=16G
net0: name=eth0,bridge=vmbr1,gw=10.10.0.1,ip=10.10.0.40/24
mp0: /hddpool/orgs/test-org-001,mp=/srv/orgs/test-org-001
mp1: /hddpool/orgs/cmr26ssq20000pf06fre1vy0m,mp=/srv/orgs/cmr26ssq20000pf06fre1vy0m
mp2: /hddpool/orgs/cmoqugczl004fml07iemp8srs,mp=/srv/orgs/cmoqugczl004fml07iemp8srs
mp3: /hddpool/orgs/cmoiknvvz0001o507gke6cq6z,mp=/srv/orgs/cmoiknvvz0001o507gke6cq6z
mp4: /hddpool/orgs/cmpk152ja03z8l90706aew825,mp=/srv/orgs/cmpk152ja03z8l90706aew825
```
- ⚠️ **KAŻDY nowy org = nowy `mpN`** (`pct set 201 -mp<N> …` + restart LXC)
  — część ręcznego org-provision (docelowo org-provision daemon).
- unprivileged → uid-shift +100000 na hoście (smb-userzy uid 5100+ w LXC =
  105100+ na hoście); ACL działają wewnątrz LXC normalnie.

## VM 100 — barvea-infra (10.10.0.10; WG hub + wg/smb-provisiond)
```
q35 / cpu: host / cores: 2 / sockets: 1 / memory: 4096 / agent: 1 / onboot: 1
scsi0: hdd-pool:vm-100-disk-0,cache=writeback,discard=on,iothread=1,size=50G
scsihw: virtio-scsi-single / net0: virtio,bridge=vmbr1 / startup: order=1
```

## VM 101 — barvea-data (10.10.0.20; Postgres 18)
```
q35 / cpu: host / cores: 4 / memory: 24576 balloon=8192 / agent: 1 / onboot: 1
scsi0: …,size=200G   scsi1: …,size=10T   (oba writeback+discard+iothread)
scsihw: virtio-scsi-single / net0: virtio,bridge=vmbr1 / startup: order=2
```

## VM 102 — barvea-app (10.10.0.30; Caddy+Next+konwertery dwg/office/point-cloud)
```
q35 / cpu: host / cores: 8 / memory: 16384 balloon=16384 / agent: 1 / onboot: 1
   (2026-09-07: 4c/8G → 8c/16G — VM liczy PDAL-em chmury, konwertuje
    LibreOffice/DWG i buduje Nexta, czasem naraz; host 12C/24T+128G ma zapas.
    Wcześniej 2026-09-05 balloon 4096→8192: host zabierał połowę RAM,
    build Nexta padał na OOM/heap limit. Balloon trzymać = memory.)
scsi0: hdd-pool:vm-102-disk-0,…,size=80G        (system + docker)
scsi1: hdd-pool:vm-102-disk-1,…,size=1000G      (śluza uploadu, volblocksize=64k)
scsihw: virtio-scsi-single / net0: virtio,bridge=vmbr1 / startup: order=3
```
`scsi1` → w gościu `/dev/sdb`, ext4 (`-m 0 -T largefile4`, `LABEL=upload-tmp`),
montowany na `/srv/upload-tmp` i bind-mountowany do kontenera app jako
`/upload-tmp`. **Właściciel `1001:1001`** — bez tego uploady padają na EACCES.
Podkatalog `pcp-scratch/` = TMPDIR sidecara point-cloud-preview (streamuje
źródło do 20 GB przed decymacją PDAL) — właściciel wg uid MAMBA_USER obrazu.
Dodany 2026-08-31: wcześniej śluza siedziała na named volume na dysku root
i biła się o miejsce z build cachem dockera (rośnie ~37 GB na deploy).
Szczegóły i trasa pliku: README repo, sekcja „Śluza uploadu".

## Noty
- **volblocksize nowych zvoli:** pula to `raidz2` na 4 dyskach. Domyślne 8k ze
  storage daje efektywność ~33% (blok 8 KiB zajmuje 24 KiB — stąd `vm-102-disk-0`
  o rozmiarze 80 G zajmujący w puli 331 G). Nowe dyski twórz ręcznie:
  `zfs create -V <size> -b 64k hddpool/vm-<id>-disk-<n>` i dopiero podepnij
  przez `qm set`, bo `qm set` z samym rozmiarem bierze 8k ze storage.
- Wszystkie VM mają wciąż podpięte ISO `debian-13.4.0-netinst` (ide2) —
  nieszkodliwe; kandydat do `qm set <id> -ide2 none` przy porządkach.
- IP VM-ek konfigurowane W GOŚCIU (statyczne, /etc/network/interfaces), nie
  w defach Proxmoxa (poza LXC, gdzie ip= w net0).
- Odtworzenie gościa: `pct create`/`qm create` wg powyższych parametrów →
  restore usług per README danego komponentu (storage/, vault/, wg-control/).
