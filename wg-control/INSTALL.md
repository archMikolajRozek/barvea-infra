# wg-provisiond — instalka (barvea-infra, ~15 min stepwise)

Odbiornik push peerów WG z APP. Po instalce: enroll → APP POST → peer sam
wskakuje → koniec ręcznych PSK. Reconciler (pull wg-manifest, self-heal)
dojdzie osobno po potwierdzeniu JSON-shape przez APP.

## 1. Transfer pliku (Windows → barvea-infra)
Wzorzec jak przy ACL pullerze: push do repo → pull na barvea-app →
`python3 -m http.server 8099 --bind 10.10.0.30` (+ `nft insert rule inet
filter input ip saddr 10.10.0.0/24 tcp dport 8099 accept` — po transferze
zdjąć!) → na barvea-infra:
```bash
curl -fso /tmp/wg-provisiond.py http://10.10.0.30:8099/wg-control/wg-provisiond.py && echo GOT
python3 -c "import py_compile; py_compile.compile('/tmp/wg-provisiond.py', doraise=True); print('py OK')"
sudo install -m 750 -o root -g root /tmp/wg-provisiond.py /usr/local/sbin/wg-provisiond.py
rm -f /tmp/wg-provisiond.py
```
(barvea-infra ma dostęp do 10.10.0.30? sprawdzić — jak nie, ta sama zabawa
z nft na VM; barvea-infra→VM LAN powinno przejść.)

## 2. Token + config (barvea-infra)
```bash
sudo install -d -m 700 /etc/barvea
T=$(openssl rand -hex 32)
sudo bash -c "umask 077; printf 'TOKEN=%s\nBIND=10.10.0.10\nPORT=8721\nWG_IFACE=wg-users\nWG_CONF=/etc/wireguard/wg-users.conf\n' '$T' > /etc/barvea/wg-provisiond.env"
echo "TOKEN (skopiuj do .env.production na barvea-app jako DRIVE_WG_PROVISION_TOKEN): $T"
unset T
```

## 3. Firewall barvea-infra: allow 10.10.0.30 → :8721
Sprawdzić mechanizm (iptables INPUT policy?):
```bash
sudo iptables -L INPUT -n --line-numbers | head -10
```
Jak policy ACCEPT bez restrykcji → nic. Jak DROP → insert allow:
```bash
sudo iptables -I INPUT -p tcp -s 10.10.0.30 --dport 8721 -j ACCEPT
# + persist wg lokalnego mechanizmu (netfilter-persistent / rules.v4)
```

## 4. Unit + start
```bash
sudo tee /etc/systemd/system/wg-provisiond.service > /dev/null <<'EOF'
[tu wkleić zawartość wg-provisiond.service z repo]
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now wg-provisiond
sudo systemctl status wg-provisiond --no-pager | head -8
```

## 5. Test (barvea-infra, lokalnie)
```bash
T=$(sudo grep '^TOKEN=' /etc/barvea/wg-provisiond.env | cut -d= -f2)
curl -s -H "Authorization: Bearer $T" http://10.10.0.10:8721/healthz
# → {"ok": true, "total": N, "managed": M}
# test upsert+delete na DUMMY pubkey (wygeneruj: wg genkey | wg pubkey):
DK=$(wg genkey); DP=$(printf '%s' "$DK" | wg pubkey); PS=$(wg genpsk)
curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d "{\"pubkey\":\"$DP\",\"preshared_key\":\"$PS\",\"allowed_ip\":\"10.67.255.250/32\"}" \
  http://10.10.0.10:8721/wg/peer
sudo wg show wg-users | grep -A1 "$DP" | head -2   # peer w kernelu
curl -s -X DELETE -H "Authorization: Bearer $T" \
  "http://10.10.0.10:8721/wg/peer/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$DP")"
sudo wg show wg-users | grep -c "$DP"   # 0
unset T DK DP PS
```

## 6. Spięcie z APP (barvea-app)
```bash
cd ~/barvea
printf 'DRIVE_WG_PROVISION_URL=http://10.10.0.10:8721\nDRIVE_WG_PROVISION_TOKEN=<token z kroku 2>\n' >> .env.production
docker compose --env-file .env.production up -d --force-recreate app
```
Test E2E: re-enroll z Drive → peer pojawia się sam (wg show) → Connect.

## Twarde reguły (wbudowane w kod)
- tylko `wg-users` (fail-fast przy innym IFACE w configu)
- allowed_ip: wyłącznie pojedynczy /32 w 10.67.0.0/16, nigdy 10.67.0.1 (gw)
- pubkey/psk: valid base64 44 znaki
- 409 ip_conflict gdy IP zajęty przez inny pubkey
- manual peery (miko-laptop) nietykane; upsert po pubkey przejmuje
  drive-dev-001 jako managed przy pierwszym pushu
- backup conf przy każdej zmianie: wg-users.conf.bak-provisiond
- syncconf hot (bez zrywania sesji innych peerów) + verify w kernelu

## TODO (po potwierdzeniu shape przez APP)
- wg-reconcile.py: GET APP /api/v1/drive/wg-manifest (Bearer
  DRIVE_WG_MANIFEST_TOKEN, ETag) → full-state diff → usuwa managed peery
  spoza manifestu, dosypuje brakujące. Timer 60s. Wzorzec = ACL puller.
  Wymaga na barvea-infra: hosts entry app.barvea.internal + Root CA.
