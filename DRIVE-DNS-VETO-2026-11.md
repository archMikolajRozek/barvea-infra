# Drive: DNS w tunelu wg-users + poprawki veto — runbook (2026-11-10)

Źródło: prośba czatu Drive (Mac nie rozwiązuje *.barvea.internal; `delete veto files = yes`
grozi utratą danych; kategoria veto „office" psuje Word/Excel na B:).

## 1. dnsmasq na VM 100 (10.67.0.1:53, tylko wg-users, tylko barvea.internal)
Pliki: `network/dnsmasq-wg-users.conf`, PostUp/PostDown INPUT 53 w `network/wg-users.conf.template`,
`bootstrap.sh` (svc_infra). Na żywym VM 100 wg-users.conf nie jest nadpisywany z repo (ma klucze
i [Peer]) — reguły INPUT dopisujemy do żywego pliku ręcznie, 1:1 jak w template.

```bash
# VM 100 (ssh -p 22 miko@10.10.0.10)
sudo apt-get install -y dnsmasq
sudo cp ~/dnsmasq-wg-users.conf /etc/dnsmasq.d/wg-users.conf        # plik ze scp
sudo systemctl enable --now dnsmasq && sudo systemctl restart dnsmasq
ss -lunp | grep ':53 '                                                # 10.67.0.1:53 dnsmasq — i NIC na 10.10.0.10
# INPUT (reguły z template; nie przetrwają restartu wg-quick bez edycji pliku — patrz niżej)
sudo iptables -I INPUT 1 -i wg-users -s 10.67.0.0/16 -d 10.67.0.1/32 -p udp --dport 53 -j ACCEPT
sudo iptables -I INPUT 1 -i wg-users -s 10.67.0.0/16 -d 10.67.0.1/32 -p tcp --dport 53 -j ACCEPT
# trwałość: dopisać 2 PostUp + 2 PostDown z template do /etc/wireguard/wg-users.conf (sed w runbooku)
dig @10.67.0.1 app.barvea.internal +short      # 10.10.0.30  (z VM 100 działa, bo 10.67.0.1 to lokalny adres)
dig @10.67.0.1 google.com +short               # pusto / NXDOMAIN — zero rekursji
```
Test z klienta WG: `nslookup app.barvea.internal 10.67.0.1` → 10.10.0.30.

## 2. Samba veto (LXC 201)
`delete veto files = no` w `barvea-veto.conf` i w per-org veto z acl-sync; kategoria „office"
usunięta z acl-sync (jeśli APP ją jeszcze wysyła — ignorowana). Istniejące `<slug>.veto.conf`
acl-sync przepisze sam przy następnym przebiegu (treść „desired" się zmieniła → rewrite + reload).
```bash
# barvea-app → host (/tmp) → LXC 201, jak zawsze
pct push 201 /tmp/barvea-veto.conf /etc/samba/barvea-veto.conf
pct push 201 /tmp/barvea-acl-sync.py /usr/local/sbin/barvea-acl-sync.py && pct exec 201 -- chmod 755 /usr/local/sbin/barvea-acl-sync.py
pct exec 201 -- bash -c "testparm -s 2>&1 | grep -E 'delete veto'"   # = No
pct exec 201 -- smbcontrol all reload-config
```
