#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BARVEA — build-offline-assets.sh: pakuje artefakty do instalacji
# AIR-GAP (dedyk bez internetu). Uruchamiać na maszynie Z INTERNETEM
# + dockerem (np. barvea-app). Wynik → katalog ASSETS przenoszony
# na nośnik → bootstrap.sh z ASSETS_DIR=<ten katalog>.
#
# Produkuje:
#   templates/  — LXC template (tar.zst) + Debian cloud qcow2
#   apt-mirror/ — flat repo: .deb wszystkich pakietów instalowanych przez
#                 bootstrap (+ third-party: PGDG, HashiCorp, Docker) + deps
#                 + Packages.gz (dpkg-scanpackages). Budowany w kontenerze
#                 debian:trixie (apt-get install --download-only).
#   bundle/     — TU wrzuć release-bundle APP (images.tar, compose.dedicated.yml,
#                 env.template, scripts/) — poza tym skryptem (od APP #4).
#
# ⚠️ EXPERIMENTAL/NIETESTOWANE (2026-07-14). Air-gap apt = trudny:
#    pozostaje INTEGRACJA — bootstrap w trybie air-gap musi wskazać
#    sources.list gości na apt-mirror (serwowany lokalnie z hosta albo
#    skopiowany do gości). To osobny TODO (patrz README na końcu).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail
OUT="${1:-./barvea-assets}"
CODENAME="${CODENAME:-trixie}"        # Debian 13
CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/${CODENAME}/latest/debian-13-genericcloud-amd64.qcow2"

log() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$OUT/templates" "$OUT/apt-mirror" "$OUT/bundle"

# ── 1. LXC template + cloud image ──────────────────────────────────
log "LXC template (debian-13-standard)"
if command -v pveam >/dev/null; then
    pveam update >/dev/null || true
    T=$(pveam available --section system | awk '/debian-13-standard/{print $2; exit}')
    [ -n "$T" ] && { pveam download local "$T" >/dev/null 2>&1 || true; \
        cp "/var/lib/vz/template/cache/$T" "$OUT/templates/" 2>/dev/null || true; }
else
    echo "  ⚠️ brak pveam (nie-Proxmox host) — LXC template pobierz na hoście PVE:"
    echo "     pveam download local debian-13-standard_*.tar.zst → skopiuj do templates/"
fi

log "Debian cloud qcow2"
if [ ! -f "$OUT/templates/$(basename "$CLOUD_IMG_URL")" ]; then
    curl -fSL -o "$OUT/templates/$(basename "$CLOUD_IMG_URL")" "$CLOUD_IMG_URL"
fi

# ── 2. apt-mirror (flat repo w kontenerze debian:trixie) ───────────
log "apt-mirror: .deb + deps w kontenerze debian:$CODENAME"
command -v docker >/dev/null || die "docker wymagany do budowy apt-mirror"

# Lista pakietów = suma wszystkich apt-get install z bootstrap.sh
PKGS="fail2ban sanoid jq restic \
      wireguard iptables nftables python3 \
      postgresql-common postgresql-18 postgresql-18-jit \
      vault \
      samba acl attr \
      docker-ce docker-ce-cli containerd.io docker-compose-plugin"

docker run --rm -v "$(cd "$OUT/apt-mirror" && pwd):/mirror" "debian:$CODENAME" bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg dpkg-dev >/dev/null
  # third-party repo keys+lists (jak bootstrap: PGDG, HashiCorp, Docker)
  install -d /usr/share/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg
  echo 'deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt $CODENAME-pgdg main' > /etc/apt/sources.list.d/pgdg.list
  curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
  echo 'deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $CODENAME main' > /etc/apt/sources.list.d/hashicorp.list
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo 'deb [signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable' > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  # download-only = ściąga pakiety+zależności do cache bez instalacji
  apt-get install -y --download-only $PKGS
  cp -n /var/cache/apt/archives/*.deb /mirror/ 2>/dev/null || true
  cd /mirror && dpkg-scanpackages -m . > Packages && gzip -kf Packages
  echo \"debs: \$(ls /mirror/*.deb | wc -l)\"
"

# ── 3. manifest + README ────────────────────────────────────────────
log "manifest"
{
  echo "# BARVEA offline assets — $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo build)"
  echo "codename=$CODENAME"
  echo "templates:"; ls -1 "$OUT/templates" 2>/dev/null | sed 's/^/  /'
  echo "apt debs: $(ls "$OUT/apt-mirror"/*.deb 2>/dev/null | wc -l)"
  echo "bundle (od APP): $(ls "$OUT/bundle" 2>/dev/null | wc -l) plików"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"

cat > "$OUT/README.md" <<'RD'
# BARVEA offline assets (air-gap)

Zbudowane przez `build-offline-assets.sh`. Przenieś CAŁY katalog na nośnik →
na air-gap hoście: `ASSETS_DIR=/sciezka/do/tego ./bootstrap.sh`.

## Zawartość
- `templates/` — LXC template + Debian cloud qcow2 (bootstrap fetch() bierze stąd)
- `apt-mirror/` — flat repo .deb + Packages.gz (wszystkie pakiety bootstrapa + deps)
- `bundle/` — release aplikacji OD APP (images.tar, compose.dedicated.yml,
  env.template, scripts/) — deploy-app.dedicated.sh

## 🔴 POZOSTAŁA INTEGRACJA (air-gap apt — TODO, nie zrobione w v1)
bootstrap.sh w trybie air-gap musi przekierować `apt` gości na `apt-mirror/`:
opcje (do wyboru przy realnym air-gap):
1. Host serwuje apt-mirror (mini http/file://) → sources.list gości = ten URL.
2. Kopiować apt-mirror do każdego gościa → `deb [trusted=yes] file:///.../apt-mirror ./`.
Trzeba: (a) dodać do bootstrap.sh (gdy AIRGAP=1) podmianę sources.list na
`deb [trusted=yes] <mirror> ./` PRZED każdym apt-get, (b) usunąć third-party
repo-adding (PGDG/HashiCorp/Docker) bo wszystko już w mirrorze. To osobny
kawałek — przetestować na stagingu z ODCIĘTĄ siecią (qm set 999 -net0 ...link_down).
RD

log "DONE → $OUT (przenieś na nośnik; wrzuć bundle APP do bundle/)"
