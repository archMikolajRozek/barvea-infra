# BARVEA backup — restic → Hetzner Storage Box BX21 (stan 2026-07-13)

Repo restic: `sftp:storagebox:barvea-restic` (alias w /root/.ssh/config per
węzeł; Storage Box u592993, port 23). **Hasło repo: /root/.config/restic/password
— IDENTYCZNE wszędzie, kopia w managerze haseł. Bez hasła repo = zero odzysku.**

## Macierz pokrycia (audyt 2026-07-13)

| Co | Węzeł | Kiedy | Status |
|---|---|---|---|
| Postgres pg_dump + redis + /mnt/minio-data (legacy) + /etc | VM 101 barvea-data | 03:09 | ✅ |
| WG klucze/peery + nftables + network | VM 100 barvea-infra | 03:38 | ✅ |
| ~/barvea (compose/app) + Caddy volumes (LE certy) + /etc | VM 102 barvea-app | 03:45 | ✅ |
| **/hddpool/orgs — CAŁE dane CDE/Drive orgów** | **host** | — | 🔴 **BRAK do 2026-07** → `barvea-host-backup.sh` (04:15) |
| **Vault /opt/vault/data** (PKI, transit, AppRole; bez tego .ct kluczy org NIE odszyfrujesz) | **host** (subvol LXC 200) | — | 🔴 **BRAK** → j.w. (z sanoid-snapshotu = spójny) |
| /etc/zfs/keys/*.ct + /etc/vault + /etc/pve (defy gości) + nftables/sanoid/fail2ban + /usr/local/sbin | **host** | — | 🔴 **BRAK** → j.w. |

Lokalne warstwy (nie zastępują off-site): RAIDZ2 (dyski), sanoid (snapshoty
co 15 min na TYM SAMYM poolu), backup pre-deploy Postgresa (deploy.sh).

## Wzorzec per węzeł (jak VM-ki, host analogicznie)
- `/root/.ssh/storagebox` — dedykowany klucz ed25519 (unikalny per węzeł),
  pub → authorized_keys Storage Boxa
- `/root/.ssh/config` — alias `storagebox`
- `/root/.config/restic/password` (0600)
- `/usr/local/sbin/barvea-<rola>-backup.sh` + unit `barvea-backup.{service,timer}`
- log `/var/log/barvea-backup.log`, lock `/var/lock/barvea-backup.lock`

Harmonogram rozstrzelony (unikanie kolizji na Boxie): 03:09 data → 03:38
infra → 03:45 app → **04:15 host** (+RandomizedDelaySec=15min wszędzie).

Retencja (forget per --host): `--keep-daily 7 --keep-weekly 4
--keep-monthly 12 --keep-yearly 5`.

## Instalacja hosta (jednorazowo, ~30 min)
```bash
apt install restic jq
ssh-keygen -t ed25519 -f /root/.ssh/storagebox -N '' -C barvea-host-storagebox-backup
# pub dodać do authorized_keys Storage Boxa (Robot UI / sftp)
# /root/.ssh/config: Host storagebox → HostName u592993.your-storagebox.de, User u592993, Port 23, IdentityFile /root/.ssh/storagebox
# /root/.config/restic/password ← TO SAMO hasło co na VM-kach (manager haseł)
restic snapshots   # test łączności (widzi wspólne repo)
cp barvea-host-backup.sh /usr/local/sbin/ && chmod 755 /usr/local/sbin/barvea-host-backup.sh
cp barvea-backup.host.service /etc/systemd/system/barvea-backup.service
cp barvea-backup.host.timer   /etc/systemd/system/barvea-backup.timer
systemctl daemon-reload && systemctl enable --now barvea-backup.timer
/usr/local/sbin/barvea-host-backup.sh   # pierwszy run ręcznie, patrz log
```

## Restore quickstart
```bash
restic snapshots                          # z dowolnego węzła (wspólne repo)
restic restore <ID> --target /restore     # pełny snapshot
restic mount /mnt/restic                  # przeglądanie (fuse)
journalctl -u barvea-backup.service --since today   # health
```

## Pojemność
BX21 = 1 TB. Repo ~0.3 GB (2026-05) + orgs ~1 GB (2026-07, dedup+delta).
Orgi mają refquota 2 T każdy — **pilnować `restic stats` / df Boxa; upgrade
BX21→BX31 zanim się zapcha.**

## TODO (z 2026-05-12, wciąż otwarte)
- Test-restore drill na czystej maszynie (backup nietestowany ≠ backup)
- Alert na fail (Telegram/Uptime Kuma z journala)
