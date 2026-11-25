#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — provision-org.sh (barvea-host, root): warstwa plików dla NOWEJ
# organizacji = przepis proxmox/zfs-layout.md zautomatyzowany (2026-11-25, D4).
#   1. dataset <ORGS_DS>/<orgId> szyfrowany (klucz z Vault transit datakey
#      per-org-keys; ciphertext → /etc/zfs/keys/<orgId>.ct — zfs-load-org.sh
#      odblokuje po reboocie),
#   2. bind-mount do LXC 201 (następny wolny mpN → /srv/orgs/<orgId>),
#   3. w LXC 201: grupa org-<orgId> (gid 5000-5099), kontenery ISO
#      WIP/Shared/Published/Archive (root:org, 2770), udział Samby [<slug>]
#      z per-org.conf.template + include w smb.conf + reload, slug → ORG_SLUGS
#      w acl-sync.env + pierwszy przebieg acl-sync.
# Idempotentny: każdy krok sprawdza stan (można powtórzyć po błędzie).
#
# Użycie: provision-org.sh <orgId> <slug>
#   orgId = Organization.id z bazy (cuid), slug = Organization.slug (= nazwa udziału)
# Wymaga: Vault UP+UNSEALED, /etc/vault/storage-approle, /etc/barvea/zfs-load-org.conf
#   (bootstrap v2) albo domyślne prod (hddpool/orgs, 10.10.0.50), jq, LXC 201 uruchomiony.
# Wywołuje: deploy-app.dedicated.sh (pierwsza org) albo operator (kolejne orgi).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
ORG_ID="${1:?podaj orgId (Organization.id)}"
SLUG="${2:?podaj slug organizacji (= nazwa udziału)}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CT="${CT_ID:-201}"
VADDR="https://10.10.0.50:8200"; ORGS_DS="hddpool/orgs"
[ -f /etc/barvea/zfs-load-org.conf ] && . /etc/barvea/zfs-load-org.conf
[ -f /etc/vault/storage-approle ] || { echo "FATAL: brak /etc/vault/storage-approle"; exit 1; }
. /etc/vault/storage-approle
TEMPLATE="${TEMPLATE:-$REPO_DIR/storage/samba/per-org.conf.template}"
[ -f "$TEMPLATE" ] || { echo "FATAL: brak $TEMPLATE"; exit 1; }
[[ "$ORG_ID" =~ ^[a-z0-9]{20,32}$ ]] || { echo "FATAL: orgId nie wygląda na cuid: $ORG_ID"; exit 1; }
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { echo "FATAL: slug [a-z0-9-]: $SLUG"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq wymagany"; exit 1; }
pct status "$CT" | grep -q running || { echo "FATAL: LXC $CT nie działa"; exit 1; }
DS="$ORGS_DS/$ORG_ID"; KEYDIR=/etc/zfs/keys; CTF="$KEYDIR/$ORG_ID.ct"; MP="/srv/orgs/$ORG_ID"
log() { printf '\033[1;36m── %s\033[0m\n' "$*"; }

# ── 1. Dataset + klucz (Vault transit datakey: plaintext → klucz, ciphertext → .ct) ─
if zfs list -H "$DS" >/dev/null 2>&1; then
  log "dataset $DS istnieje — pomijam create"
  [ -f "$CTF" ] || { echo "FATAL: $DS istnieje, ale brak $CTF — nie da się odblokować po reboocie; napraw ręcznie"; exit 1; }
else
  log "dataset $DS (klucz z Vault per-org-keys)"
  TOKEN=$(curl -sk --request POST --data "{\"role_id\":\"$VAULT_ROLE_ID\",\"secret_id\":\"$VAULT_SECRET_ID\"}" "$VADDR/v1/auth/approle/login" | jq -r '.auth.client_token')
  [ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "FATAL: approle login (Vault sealed?)"; exit 1; }
  DK=$(curl -sk -H "X-Vault-Token: $TOKEN" --request POST "$VADDR/v1/transit/datakey/plaintext/per-org-keys")
  curl -sk -H "X-Vault-Token: $TOKEN" --request POST "$VADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
  PT=$(printf '%s' "$DK" | jq -r '.data.plaintext'); CTX=$(printf '%s' "$DK" | jq -r '.data.ciphertext')
  [ -n "$PT" ] && [ "$PT" != null ] && [ -n "$CTX" ] && [ "$CTX" != null ] || { echo "FATAL: datakey per-org-keys (polityka barvea-storage?)"; exit 1; }
  mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
  # keyformat=raw: dokładnie 32 bajty klucza (passphrase ucinałby na pierwszym 0x0a).
  # zfs-load-org.sh ładuje tak samo: base64 -d | zfs load-key — format jest obojętny.
  printf '%s' "$PT" | base64 -d | zfs create -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=prompt \
      -o compression=zstd -o xattr=sa -o acltype=posix -o refquota="${ORG_REFQUOTA:-2T}" "$DS"
  ( umask 077; printf '%s' "$CTX" > "$CTF" )
  unset PT DK
  echo "  ✓ $DS (keystatus: $(zfs get -H -o value keystatus "$DS")), klucz → $CTF"
fi
HOSTMP="$(zfs get -H -o value mountpoint "$DS")"
[ "$(zfs get -H -o value mounted "$DS")" = yes ] || zfs mount "$DS"

# ── 2. Bind-mount do LXC: następny wolny mpN ──────────────────────
if pct config "$CT" | grep -qE "^mp[0-9]+: .*,mp=$MP(,|$)"; then
  log "bind-mount $MP już w konfiguracji LXC $CT"
else
  N=0; while pct config "$CT" | grep -q "^mp$N:"; do N=$((N+1)); done
  log "pct set $CT -mp$N $HOSTMP,mp=$MP"
  pct set "$CT" -mp"$N" "$HOSTMP,mp=$MP"
fi
if ! pct exec "$CT" -- mountpoint -q "$MP"; then
  echo "  ⚠️  $MP nie jest zamontowany w LXC $CT (mp dodany na gorąco nie wszedł) → restart kontenera"
  pct reboot "$CT"; sleep 5
  pct exec "$CT" -- mountpoint -q "$MP" || { echo "FATAL: $MP nadal niezamontowany w LXC $CT"; exit 1; }
fi

# ── 3. W LXC 201: grupa, kontenery ISO, udział, include, ORG_SLUGS ─
log "LXC $CT: grupa org-$ORG_ID + kontenery + udział [$SLUG]"
# pliki do LXC przez pct push (stdin pct exec nie jest gwarantowany): udział + skrypt kroku
TMPD=$(mktemp -d); chmod 700 "$TMPD"; trap 'rm -rf "$TMPD"' EXIT
sed -e "s|__ORG_SLUG__|$SLUG|g" -e "s|__ORG_ID__|$ORG_ID|g" "$TEMPLATE" > "$TMPD/share.conf"
pct exec "$CT" -- mkdir -p /etc/samba/per-org
pct push "$CT" "$TMPD/share.conf" "/etc/samba/per-org/$SLUG.conf"
cat > "$TMPD/step.sh" <<'EOS'
set -euo pipefail
ORG_ID="$1"; SLUG="$2"; MP="$3"; G="org-$ORG_ID"
if ! getent group "$G" >/dev/null; then
  GID=5000; while getent group "$GID" >/dev/null; do GID=$((GID+1)); [ "$GID" -le 5099 ] || { echo "FATAL: brak wolnego gid 5000-5099"; exit 1; }; done
  groupadd -g "$GID" "$G"
fi
chown root:"$G" "$MP"; chmod 2770 "$MP"
for c in WIP Shared Published Archive; do install -d -o root -g "$G" -m 2770 "$MP/$c"; done
grep -qxF "include = /etc/samba/per-org/$SLUG.conf" /etc/samba/smb.conf || printf '\ninclude = /etc/samba/per-org/%s.conf\n' "$SLUG" >> /etc/samba/smb.conf
testparm -s >/dev/null 2>&1 || { echo "FATAL: testparm odrzuca smb.conf po dodaniu include"; exit 1; }
smbcontrol smbd reload-config >/dev/null 2>&1 || systemctl reload smbd || true
if ! grep -E '^ORG_SLUGS=' /etc/barvea/acl-sync.env | tr ', ' '\n\n' | grep -qx "$SLUG"; then
  CUR=$(grep -oP '(?<=^ORG_SLUGS=).*' /etc/barvea/acl-sync.env || true)
  sed -i "s|^ORG_SLUGS=.*|ORG_SLUGS=${CUR:+$CUR,}$SLUG|" /etc/barvea/acl-sync.env
fi
systemctl start barvea-acl-sync.service 2>/dev/null || true   # pierwszy przebieg (manifest ACL org)
echo "  ✓ grupa $G ($(getent group "$G" | cut -d: -f3)), udział [$SLUG] → $MP, ORG_SLUGS=$(grep -oP '(?<=^ORG_SLUGS=).*' /etc/barvea/acl-sync.env)"
EOS
pct push "$CT" "$TMPD/step.sh" /root/.barvea-provision-org-step.sh
pct exec "$CT" -- bash /root/.barvea-provision-org-step.sh "$ORG_ID" "$SLUG" "$MP"
pct exec "$CT" -- rm -f /root/.barvea-provision-org-step.sh
log "DONE org $SLUG ($ORG_ID): $DS → LXC $CT:$MP, udział [$SLUG]"
echo "  Konta SMB zakłada aplikacja (smb-provisiond, per użytkownik+org). Po reboocie hosta: zfs-load-org.sh."
