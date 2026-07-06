#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# BARVEA Drive — ACL sync v2 (manifest → POSIX ACL). LXC 201, root,
# systemd timer 60s. Kontrakt v2 z APP (2026-07-07, zamrożony):
#
#   AclProject.acls[]  — FOLDERY, path CONTAINER-prefixed
#                        ("WIP/Architektura", "Shared/Architektura", …)
#   AclProject.files[] — per-PLIK ACL, TYLKO WIP ("WIP/<tree>/<plik>")
#
# Model aplikowania:
#   WIP foldery:   entry na KATALOGU (bez rekursji na pliki, ZERO default
#                  ACL) — folder-grant = wejście/listing/tworzenie; treść
#                  plików wyłącznie z files[] (WIP-privacy per plik;
#                  autor pliku widzi swoje jako POSIX owner).
#   WIP pliki:     wyłącznie z files[]: DOWNLOAD→r--, WRITE/MANAGE→rw-.
#   Shared/Published/Archive: folder-grant rekursywnie + default ACL
#                  (jak v1) — tam nie ma per-file.
#   STRIP:         full-state — wpis nieobecny w manifeście = zdejmowany.
#   skippedFolders/skippedFiles = web-only → traktowane jak nieobecne.
#   Zarządzamy WYŁĄCZNIE wpisami u:u_* (owner/group/mask/other nietykane).
#
# Config: /etc/barvea/acl-sync.env  (DRIVE_ACL_SERVICE_TOKEN, ORG_SLUGS,
#   APP_URL=https://app.barvea.internal, CA_FILE=/etc/barvea/root-ca.crt)
# State:  /var/lib/barvea-acl/<slug>.{etag,manifest.json}
# ═══════════════════════════════════════════════════════════════
import json, os, ssl, subprocess, sys, time, urllib.request, urllib.error

CONF = "/etc/barvea/acl-sync.env"
STATE_DIR = "/var/lib/barvea-acl"
ORG_BASE = "/srv/orgs"
FORCE_INTERVAL = 3600
CONTAINERS = ("WIP", "Shared", "Published", "Archive")

DIR_PERMS = {"DOWNLOAD": "r-x", "WRITE": "rwx", "MANAGE": "rwx"}
FILE_PERMS = {"DOWNLOAD": "r--", "WRITE": "rw-", "MANAGE": "rw-"}
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
    parts = [p for p in path.replace("\\", "/").split("/") if p]
    if not all(valid_component(p) for p in parts):
        return None
    return parts


def dataset_base(dataset_root):
    parts = rel_parts(dataset_root)
    return os.path.join(ORG_BASE, *parts) if parts else None


def entries_map(manifest):
    """manifest → {root: {"folders": {(parts,user):lvl},
                          "files":   {(parts,user):lvl}}}"""
    out = {}
    for proj in manifest.get("projects", []):
        root = proj.get("datasetRoot", "")
        m = out.setdefault(root, {"folders": {}, "files": {}})
        for acl in proj.get("acls", []) or []:
            parts = rel_parts(acl.get("path", ""))
            if parts is None or parts[0] not in CONTAINERS:
                warn(f"manifest: folder path poza kontenerem "
                     f"{acl.get('path')!r} w {root} (skip)")
                continue
            for e in acl.get("entries", []) or []:
                user = e.get("smbUsername") or ""
                lvl = e.get("level") or ""
                if not user.startswith("u_"):
                    continue  # null = user bez konta SMB (jeszcze) — skip
                if lvl not in DIR_PERMS:
                    warn(f"manifest: level {lvl!r} dla {user} (skip)")
                    continue
                m["folders"][(tuple(parts), user)] = lvl
        for fe in proj.get("files", []) or []:
            parts = rel_parts(fe.get("path", ""))
            if parts is None or len(parts) < 2 or parts[0] != "WIP":
                warn(f"manifest: files[] poza WIP {fe.get('path')!r} (skip)")
                continue
            for e in fe.get("entries", []) or []:
                user = e.get("smbUsername") or ""
                lvl = e.get("level") or ""
                if not user.startswith("u_"):
                    continue
                if lvl not in FILE_PERMS:
                    warn(f"manifest: file level {lvl!r} dla {user} (skip)")
                    continue
                m["files"][(tuple(parts), user)] = lvl
    return out


def ancestors_of(base, parts):
    out = [base]
    cur = base
    for p in parts[:-1]:
        cur = os.path.join(cur, p)
        out.append(cur)
    return out


def apply_dataset(base, new_m, old_m, traverse):
    nf, nfi = new_m["folders"], new_m["files"]
    of = old_m.get("folders", {})
    ofi = old_m.get("files", {})

    # ── strip: foldery ──
    for (parts, user) in set(of) - set(nf):
        target = os.path.join(base, *parts)
        if os.path.isdir(target):
            if parts[0] == "WIP":
                setfacl(["-x", f"u:{user}", target])
            else:
                setfacl(["-R", "-x", f"u:{user}", target])
                setfacl(["-R", "-d", "-x", f"u:{user}", target])
        log(f"  strip-folder u:{user} {'/'.join(parts)}")
    # ── strip: pliki WIP ──
    for (parts, user) in set(ofi) - set(nfi):
        target = os.path.join(base, *parts)
        if os.path.isfile(target):
            setfacl(["-x", f"u:{user}", target])
        log(f"  strip-file u:{user} {'/'.join(parts)}")

    # ── apply: foldery ──
    for (parts, user), lvl in nf.items():
        target = os.path.join(base, *parts)
        for d in ancestors_of(base, parts):
            if os.path.isdir(d):
                setfacl(["-m", f"u:{user}:{traverse}", d])
        if not os.path.isdir(target):
            warn(f"brak katalogu {target} (retry przy następnym pullu)")
            continue
        if parts[0] == "WIP":
            # TYLKO katalog: wejście/listing/tworzenie. ZERO -R, ZERO -d —
            # pliki WIP dostają ACL wyłącznie z files[] (privacy per plik).
            setfacl(["-m", f"u:{user}:{DIR_PERMS[lvl]}", target])
        else:
            setfacl(["-R", "-m", f"u:{user}:{DIR_PERMS[lvl]}", target])
            setfacl(["-R", "-d", "-m", f"u:{user}:{DIR_PERMS[lvl]}", target])
    # ── apply: pliki WIP (wyłącznie files[]) ──
    for (parts, user), lvl in nfi.items():
        target = os.path.join(base, *parts)
        for d in ancestors_of(base, parts):
            if os.path.isdir(d):
                setfacl(["-m", f"u:{user}:{traverse}", d])
        if not os.path.isfile(target):
            warn(f"brak pliku {target} (retry przy następnym pullu)")
            continue
        setfacl(["-m", f"u:{user}:{FILE_PERMS[lvl]}", target])

    # ── traverse cleanup: user bez ŻADNYCH wpisów w datasecie ──
    old_users = {u for (_, u) in of} | {u for (_, u) in ofi}
    new_users = {u for (_, u) in nf} | {u for (_, u) in nfi}
    for user in old_users - new_users:
        anc = set()
        for (parts, u) in list(of) + list(ofi):
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
            manifest = json.loads(resp.read())
            new_etag = resp.headers.get("ETag", "")
    except urllib.error.HTTPError as e:
        if e.code == 304:
            fresh = os.path.exists(man_f) and \
                (time.time() - os.path.getmtime(man_f)) < FORCE_INTERVAL
            if fresh:
                log(f"{slug}: 304, świeże — skip")
                return
            if not os.path.exists(man_f):
                os.path.exists(etag_f) and os.remove(etag_f)
                return
            log(f"{slug}: 304, drift-heal re-apply z cache")
            with open(man_f) as f:
                manifest = json.load(f)
            new_etag = None
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
            warn(f"{slug}: zepsuty cache manifestu ({e}) — pusty")
    new = entries_map(manifest)
    traverse = "--x" if manifest.get("strictVisibility") else "r-x"

    for root in set(old) | set(new):
        base = dataset_base(root)
        if base is None:
            warn(f"{slug}: zły datasetRoot {root!r} (skip)")
            continue
        empty = {"folders": {}, "files": {}}
        n = new.get(root, empty)
        o = old.get(root, empty)
        if not os.path.isdir(base):
            if n["folders"] or n["files"]:
                warn(f"{slug}: brak datasetu {base} (retry next)")
            continue
        log(f"{slug}: reconcile {root} (dirs {len(n['folders'])}/"
            f"{len(o.get('folders', {}))} files {len(n['files'])}/"
            f"{len(o.get('files', {}))} traverse={traverse})")
        apply_dataset(base, n, o, traverse)

    for sk in (manifest.get("skippedFolders") or []) + \
              (manifest.get("skippedFiles") or []):
        log(f"{slug}: skipped {sk}")

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
    for slug in [s for s in cfg["ORG_SLUGS"].replace(",", " ").split() if s]:
        sync_org(cfg, slug)
    if failures:
        log(f"DONE z {failures} warn(ami)")
        sys.exit(2)
    log("DONE clean")


if __name__ == "__main__":
    main()
