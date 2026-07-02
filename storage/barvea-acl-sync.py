#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# BARVEA Drive — ACL sync (puller). Uruchamiać na LXC 201 (storage)
# jako root przez systemd timer (60s). Kontrakt: APP commit f19d56f.
#
# Pull GET /api/v1/orgs/{slug}/drive/acl-manifest (Bearer token, ETag/304)
# → reconcile POSIX ACLs na /srv/orgs/<datasetRoot>:
#   - DOWNLOAD → r-x, WRITE/MANAGE → rwx (recursive + default ACL na dirach)
#   - ancestor traverse: --x gdy strictVisibility, r-x gdy nie (browseable)
#   - VIEW/NONE = brak entry (web-only, nic nie robimy)
#   - full-state: entry (path,user) obecne w starym manifeście a nieobecne
#     w nowym → strip. Dataset z acls:[] → strip wszystkich zarządzanych.
#   - zarządzamy WYŁĄCZNIE wpisami u:u_* — owner/group/other/mask nietykane.
#
# Config: /etc/barvea/acl-sync.env
#   DRIVE_ACL_SERVICE_TOKEN=<hex>
#   ORG_SLUGS=test-drive            # spacje lub przecinki
#   APP_URL=https://app.barvea.internal   # /etc/hosts → 10.10.0.30
#   CA_FILE=/etc/barvea/root-ca.crt
# State: /var/lib/barvea-acl/<slug>.etag + <slug>.manifest.json
# 304 → skip; wymuszenie pełnego re-apply (drift heal) co FORCE_INTERVAL.
# ═══════════════════════════════════════════════════════════════
import json, os, ssl, subprocess, sys, time, urllib.request, urllib.error

CONF = "/etc/barvea/acl-sync.env"
STATE_DIR = "/var/lib/barvea-acl"
ORG_BASE = "/srv/orgs"
FORCE_INTERVAL = 3600  # sekundy; pełny re-apply z cache mimo 304

LEVEL_PERMS = {"DOWNLOAD": "r-x", "WRITE": "rwx", "MANAGE": "rwx"}
failures = 0


def log(msg):
    print(msg, flush=True)


def warn(msg):
    global failures
    failures += 1
    print(f"WARN {msg}", flush=True)


def load_conf():
    cfg = {}
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"')
    for req in ("DRIVE_ACL_SERVICE_TOKEN", "ORG_SLUGS"):
        if not cfg.get(req):
            log(f"FATAL brak {req} w {CONF}")
            sys.exit(1)
    cfg.setdefault("APP_URL", "https://app.barvea.internal")
    cfg.setdefault("CA_FILE", "/etc/barvea/root-ca.crt")
    return cfg


def setfacl(args):
    r = subprocess.run(["setfacl"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        warn(f"setfacl {' '.join(args)} :: {r.stderr.strip()[:200]}")
    return r.returncode == 0


def valid_component(c):
    return bool(c) and c not in (".", "..") and "/" not in c and "\\" not in c \
        and "\x00" not in c and not any(ord(ch) < 32 for ch in c)


def rel_parts(path):
    """Zwaliduj i rozbij ścieżkę względną manifestu; None gdy podejrzana."""
    parts = [p for p in path.replace("\\", "/").split("/") if p]
    if not all(valid_component(p) for p in parts):
        return None
    return parts


def dataset_base(dataset_root):
    parts = rel_parts(dataset_root)
    if not parts:
        return None
    return os.path.join(ORG_BASE, *parts)


def entries_map(manifest):
    """manifest → {datasetRoot: {(path_tuple, user): level}} (tylko u_*)."""
    out = {}
    for proj in manifest.get("projects", []):
        root = proj.get("datasetRoot", "")
        m = out.setdefault(root, {})
        for acl in proj.get("acls", []) or []:
            parts = rel_parts(acl.get("path", ""))
            if parts is None:
                warn(f"manifest: zła ścieżka {acl.get('path')!r} w {root} (skip)")
                continue
            for e in acl.get("entries", []) or []:
                user = e.get("smbUsername") or ""
                lvl = e.get("level") or ""
                if not user.startswith("u_"):
                    warn(f"manifest: nie-zarządzany user {user!r} (skip)")
                    continue
                if lvl not in LEVEL_PERMS:
                    warn(f"manifest: nieznany level {lvl!r} dla {user} (skip)")
                    continue
                m[(tuple(parts), user)] = lvl
    return out


def ancestors_of(base, parts):
    """Katalogi pośrednie od base (włącznie) do rodzica celu (włącznie)."""
    out = [base]
    cur = base
    for p in parts[:-1]:
        cur = os.path.join(cur, p)
        out.append(cur)
    return out


def apply_dataset(base, new_m, old_m, traverse):
    # 1. strip: wpisy które zniknęły
    for (parts, user) in set(old_m) - set(new_m):
        target = os.path.join(base, *parts)
        if os.path.exists(target):
            setfacl(["-R", "-x", f"u:{user}", target])
            if os.path.isdir(target):
                setfacl(["-R", "-d", "-x", f"u:{user}", target])
        log(f"  strip u:{user} {target}")
    # 2. apply: wszystkie z nowego (idempotentne, łapie też zmiany levelu)
    for (parts, user), lvl in new_m.items():
        perms = LEVEL_PERMS[lvl]
        for d in ancestors_of(base, parts):
            if os.path.isdir(d):
                setfacl(["-m", f"u:{user}:{traverse}", d])
        target = os.path.join(base, *parts)
        if not os.path.exists(target):
            warn(f"brak ścieżki {target} (retry przy następnym pullu)")
            continue
        setfacl(["-R", "-m", f"u:{user}:{perms}", target])
        if os.path.isdir(target):
            setfacl(["-R", "-d", "-m", f"u:{user}:{perms}", target])
    # 3. traverse cleanup: user stracił WSZYSTKIE wpisy w datasecie →
    #    zdejmij jego wpisy z ancestorów starych ścieżek (non-recursive)
    old_users = {u for (_, u) in old_m}
    new_users = {u for (_, u) in new_m}
    for user in old_users - new_users:
        anc = set()
        for (parts, u) in old_m:
            if u == user:
                anc.update(ancestors_of(base, parts))
        for d in sorted(anc):
            if os.path.isdir(d):
                setfacl(["-x", f"u:{user}", d])
        log(f"  traverse-cleanup u:{user} ({len(anc)} dirs)")


def sync_org(cfg, slug):
    etag_f = os.path.join(STATE_DIR, f"{slug}.etag")
    man_f = os.path.join(STATE_DIR, f"{slug}.manifest.json")
    url = f"{cfg['APP_URL']}/api/v1/orgs/{slug}/drive/acl-manifest"
    ctx = ssl.create_default_context(cafile=cfg["CA_FILE"])
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {cfg['DRIVE_ACL_SERVICE_TOKEN']}"})
    if os.path.exists(etag_f):
        with open(etag_f) as f:
            et = f.read().strip()
        if et:
            req.add_header("If-None-Match", et)
    try:
        with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
            body = resp.read()
            new_etag = resp.headers.get("ETag", "")
            manifest = json.loads(body)
    except urllib.error.HTTPError as e:
        if e.code == 304:
            # bez zmian — okresowy pełny re-apply z cache (drift heal)
            fresh = os.path.exists(man_f) and \
                (time.time() - os.path.getmtime(man_f)) < FORCE_INTERVAL
            if fresh:
                log(f"{slug}: 304, świeże — skip")
                return
            if not os.path.exists(man_f):
                log(f"{slug}: 304 ale brak cache — czyszczę etag, retry next")
                os.path.exists(etag_f) and os.remove(etag_f)
                return
            log(f"{slug}: 304, drift-heal re-apply z cache")
            with open(man_f) as f:
                manifest = json.load(f)
            new_etag = None  # nie ruszaj etaga
        else:
            warn(f"{slug}: HTTP {e.code} {e.read()[:200]!r}")
            return
    except Exception as e:
        warn(f"{slug}: fetch fail {e}")
        return

    old = {}
    if os.path.exists(man_f):
        try:
            with open(man_f) as f:
                old = entries_map(json.load(f))
        except Exception as e:
            warn(f"{slug}: zepsuty cache manifestu ({e}) — traktuję jako pusty")
    new = entries_map(manifest)
    traverse = "--x" if manifest.get("strictVisibility") else "r-x"

    for root in set(old) | set(new):
        base = dataset_base(root)
        if base is None:
            warn(f"{slug}: zły datasetRoot {root!r} (skip)")
            continue
        if not os.path.isdir(base):
            if new.get(root):
                warn(f"{slug}: brak datasetu {base} (retry next)")
            continue
        log(f"{slug}: reconcile {root} (new={len(new.get(root, {}))} "
            f"old={len(old.get(root, {}))} traverse={traverse})")
        apply_dataset(base, new.get(root, {}), old.get(root, {}), traverse)

    for sk in manifest.get("skippedFolders", []) or []:
        log(f"{slug}: skippedFolder {sk}")

    # zapis stanu: manifest zawsze (intencja), etag tylko przy zero błędów
    # (missing-path/setfacl fail → następny run znów 200 → retry)
    with open(man_f + ".tmp", "w") as f:
        json.dump(manifest, f)
    os.replace(man_f + ".tmp", man_f)
    if new_etag is not None:
        if failures == 0 and new_etag:
            with open(etag_f, "w") as f:
                f.write(new_etag)
        elif os.path.exists(etag_f):
            os.remove(etag_f)


def main():
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    cfg = load_conf()
    slugs = [s for s in cfg["ORG_SLUGS"].replace(",", " ").split() if s]
    for slug in slugs:
        sync_org(cfg, slug)
    if failures:
        log(f"DONE z {failures} warn(ami)")
        sys.exit(2)
    log("DONE clean")


if __name__ == "__main__":
    main()
