# BARVEA network — firewall + WireGuard (IaC, zrzut z proda 2026-07-13)

⚠️ KEEP-IN-SYNC: każda zmiana reguł/WG na żywym → dopisz tutaj.

## Topologia

```
Internet (publiczny IP, vmbr0)
  │
┌─▼─ barvea-host (Proxmox; nft drop-default: host-nftables.conf) ─────┐
│ INPUT:  lo, est/rel, icmp, 2277/tcp (SSH+fail2ban), 51820-1/udp,    │
│         8006 tylko z vmbr1 (Proxmox UI niepubliczne)                │
│ DNAT:   51820,51821/udp → 10.10.0.10 (WG hub na VM 100)             │
│         80,443/tcp + 443/udp (HTTP/3) → 10.10.0.30 (Caddy)          │
│ FWD:    drop-default; vmbr1→out OK; vmbr0→vmbr1 tylko j.w.;         │
│         vmbr1↔vmbr1 accept; masquerade 10.10.0.0/24 → vmbr0         │
└──────────────────────────────────────────────────────────────────────┘
   vmbr1 = LAN 10.10.0.0/24
   ├─ VM 100 barvea-infra 10.10.0.10 — WG HUB (oba tunele + firewall):
   │    wg-users :51821, 10.67.0.0/16, MTU 1420 (users/devices/Drive)
   │      → BARVEA_USER_IN (PostUp; wg-users.conf.template):
   │        est/rel ✓ · intra-10.67 DROP (hub-spoke) ·
   │        →10.10.0.40:445/tcp (Samba) ✓ · →10.10.0.30:443/tcp (app) ✓ ·
   │        reszta LOG "BARVEA_USER_DROP "+DROP · masq 10.67→ens18
   │    wg0 :51820, 10.9.0.0/24 (ADMIN, pełny LAN; wg0.conf.template)
   ├─ VM 101 barvea-data 10.10.0.20 (Postgres — tylko LAN)
   ├─ VM 102 barvea-app 10.10.0.30 (Caddy+app; publiczne 80/443)
   ├─ LXC 200 vault 10.10.0.50 (Vault :8200 — tylko LAN)
   └─ LXC 201 storage 10.10.0.40 (Samba :445, datad :8723 — tylko LAN)
```

## Persistence (gdzie co żyje) — KRYTYCZNE dla DR

| Węzeł | Mechanizm | Plik |
|---|---|---|
| barvea-host | `nftables.service` (enabled) | `/etc/nftables.conf` = `host-nftables.conf` |
| barvea-host | fail2ban (dynamiczny f2b-sshd w legacy iptables) | `host-fail2ban-jail.local` |
| VM 100 | `wg-quick@wg-users` (enabled) — **cały firewall users w PostUp** | `wg-users.conf.template` |
| VM 100 | `wg-quick@wg0` (enabled) | `wg0.conf.template` |

Na VM 100: `nftables.service` DISABLED, `netfilter-persistent` BRAK — **to
poprawne**: reguły odtwarza PostUp przy każdym podniesieniu tunelu. Nie
„naprawiać" włączaniem nftables na VM 100.

Na hoście legacy iptables zawiera f2b-sshd (fail2ban, dynamiczne) + stary
duplikat MASQUERADE 10.10.0.0/24 (artefakt; nft autorytatywny; przy fresh
install nie odtwarzać).

## Uwagi
- **h3/QUIC**: publiczny edge forwarduje 443/udp do Caddy → przeglądarki
  mogą h3. Tunel wg-users przepuszcza **tylko TCP** do app (BARVEA_USER_IN)
  → klient Drive przez WG = h2 (celowe).
- Sekrety NIE w repo: `/etc/wireguard/*_private.key`, `*_psk.key`
  (VM 100; kopie restic + Bitwarden). Template'y mają placeholdery.
- [Peer] w wg-users.conf zarządza `wg-control/wg-provisiond.py` (enroll
  z APP); wg0 peery — ręcznie.
- SSH hosta na porcie **2277** (fail2ban banuje 5 prób/10 min → 1 h).
