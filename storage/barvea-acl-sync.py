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
import grp, json, os, ssl, subprocess, sys, time, urllib.request, urllib.error

CONF = "/etc/barvea/acl-sync.env"
STATE_DIR = "/var/lib/barvea-acl"
ORG_BASE = "/srv/orgs"
FORCE_INTERVAL = 3600
CONTAINERS = ("WIP", "Shared", "Published", "Archive")
# Phantom foldery APP — wystawiane w manifeście, ale puste (nic tam nie trafia).
# NIE materializujemy (mkdir/acl/hidden pomijają), orphan-scan je usuwa. Zdjąć
# gdy APP przestanie je emitować w manifeście (root-cause po ich stronie).
SKIP_FOLDERS = {"Nieprzypisane"}

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


DOSATTRIB = "user.DOSATTRIB"      # Samba `store dos attributes = yes` xattr
HIDDEN_VAL = b"0x2"               # FILE_ATTRIBUTE_HIDDEN (legacy-hex, Samba czyta)


def set_hidden(target, on):
    """DOS-H na katalogu (isHidden z CDE). store dos attributes=yes → Samba
    czyta user.DOSATTRIB; 0x2=HIDDEN → folder ukryty (show-hidden odsłania;
    dostęp wg ACL BEZ zmian — soft cosmetic hide). CDE = źródło prawdy: klient
    nie nadpisze (re-assert co pull). Idempotent (write tylko gdy drift)."""
    try:
        cur = os.getxattr(target, DOSATTRIB)
    except OSError:
        cur = None
    if on:
        if cur != HIDDEN_VAL:
            try:
                os.setxattr(target, DOSATTRIB, HIDDEN_VAL)
                return "hide"
            except OSError as e:
                warn(f"setxattr H {target}: {e}")
    elif cur is not None:
        try:
            os.removexattr(target, DOSATTRIB)
            return "unhide"
        except OSError as e:
            warn(f"rmxattr {target}: {e}")
    return None


def rmdir_empty_tree(path):
    """Usuń dir tree WYŁĄCZNIE gdy CAŁE puste (zero plików gdziekolwiek).
    Najpierw skan na pliki → jeden plik = cały tree zostaje (ZERO utraty).
    Zero plików → rmdir bottom-up (kolaps pustego scaffoldingu)."""
    for _root, _dirs, files in os.walk(path):
        if files:
            return False, "ma pliki"
    for _root, _dirs, _files in os.walk(path, topdown=False):
        try:
            os.rmdir(_root)
        except OSError as e:
            return False, e.strerror
    return True, None


# ── VETO FILES (śmieci Win/mac + malware .exe) — web-konfigurowalny per-org.
# Kontrakt z APP: manifest top-level `shareConfig.vetoFiles={enabled,categories}`.
# Brak pola = OFF (zero footprintu). Applier pisze per-org veto include +
# reload smbd (veto NIE vfs → reload-config OK, bez restartu/zrywania sesji).
PER_ORG_DIR = "/etc/samba/per-org"
VETO_CATEGORY = {
    "windows": ["Thumbs.db", "Thumbs.db:encryptable", "ehthumbs.db",
                "desktop.ini", "$RECYCLE.BIN"],
    "macos": [".DS_Store", "._*", ".Spotlight-V100", ".Trashes",
              ".fseventsd", ".TemporaryItems"],
    "office": ["~$*", ".~lock.*"],
    "executables": ["*.exe", "*.scr", "*.bat", "*.cmd", "*.com", "*.pif",
                    "*.vbs", "*.js", "*.jse", "*.wsf", "*.msi", "*.jar",
                    "*.ps1", "*.lnk"],
}
VETO_ORDER = ["windows", "macos", "office", "executables"]


def ensure_veto_include(share_conf, veto_file):
    """Dopisz `include = <veto_file>` do per-org share conf (raz, idempotent).
    Defensywnie: tylko gdy conf istnieje + ma sekcję [..] + include nieobecny."""
    inc = f"include = {veto_file}"
    try:
        cur = open(share_conf).read()
    except FileNotFoundError:
        warn(f"veto: brak share conf {share_conf} — pomijam")
        return False
    if inc in cur:
        return True
    if "[" not in cur:
        warn(f"veto: {share_conf} bez sekcji [..] — pomijam include")
        return False
    with open(share_conf, "a") as f:
        f.write(f"\n   {inc}\n")
    log(f"veto: +include {os.path.basename(share_conf)}")
    return True


def apply_veto(slug, manifest):
    """shareConfig.vetoFiles → per-org veto include + reload smbd. Brak pola =
    OFF, NIE tykamy share conf. Idempotent: reload TYLKO gdy veto-file zmieniony.
    testparm-guard przed reload (zły config → NIE reload, live nietknięty)."""
    sc = (manifest.get("shareConfig") or {}).get("vetoFiles")
    if sc is None:
        return                        # pole absent = OFF, zero footprintu
    veto_file = os.path.join(PER_ORG_DIR, f"{slug}.veto.conf")
    share_conf = os.path.join(PER_ORG_DIR, f"{slug}.conf")
    enabled = bool(sc.get("enabled"))
    cats = [c for c in VETO_ORDER if c in (sc.get("categories") or [])]
    if enabled and cats:
        pats = [p for c in cats for p in VETO_CATEGORY[c]]
        veto = "/" + "/".join(pats) + "/"
        desired = ("# BARVEA veto — zarządzane przez acl-sync, NIE edytuj\n"
                   f"   veto files = {veto}\n"
                   "   delete veto files = yes\n")
    else:
        desired = "# BARVEA veto: OFF (disabled / brak kategorii)\n"
    try:
        cur = open(veto_file).read()
    except FileNotFoundError:
        cur = None
    if cur == desired:
        return                        # bez zmian = bez reload (idempotent)
    with open(veto_file + ".tmp", "w") as f:
        f.write(desired)
    os.replace(veto_file + ".tmp", veto_file)   # target istnieje przed include
    if not ensure_veto_include(share_conf, veto_file):
        return
    tp = subprocess.run(["testparm", "-s"], capture_output=True, text=True)
    if tp.returncode != 0:
        warn(f"veto: testparm FAIL {slug} — NIE reload, live nietknięty "
             f"({tp.stderr.strip()[:150]})")
        return
    subprocess.run(["smbcontrol", "smbd", "reload-config"],
                   capture_output=True)
    state = "ON " + ",".join(cats) if (enabled and cats) else "OFF"
    log(f"{slug}: veto {state} → smbd reload")


def valid_component(c):
    return bool(c) and c not in (".", "..") and "/" not in c and "\\" not in c \
        and "\x00" not in c and not any(ord(ch) < 32 for ch in c)


def rel_parts(path):
    parts = [p for p in path.replace("\\", "/").split("/") if p]
    if not all(valid_component(p) for p in parts):
        return None
    return parts


def dataset_base(org_id, dataset_root):
    # datasetRoot = project-relative (driveFolderName, może mieć spacje);
    # org_id z top-level manifestu (org = dataset/mount, nie segment path).
    # Legacy fallback: gdy datasetRoot już niesie org-prefix (<org>/<cuid>).
    if not org_id or not valid_component(org_id):
        return None
    parts = rel_parts(dataset_root)
    if parts is None:
        return None
    if parts and parts[0] == org_id:      # legacy <org>/<cuid>
        return os.path.join(ORG_BASE, *parts)
    return os.path.join(ORG_BASE, org_id, *parts)


def entries_map(manifest):
    """manifest → {root: {"folders": {(parts,user):lvl},
                          "files":   {(parts,user):lvl}}}"""
    out = {}
    for proj in manifest.get("projects", []):
        root = proj.get("datasetRoot", "")
        m = out.setdefault(root, {"folders": {}, "files": {}, "hidden": set()})
        for acl in proj.get("acls", []) or []:
            parts = rel_parts(acl.get("path", ""))
            if parts is None or parts[0] not in CONTAINERS:
                warn(f"manifest: folder path poza kontenerem "
                     f"{acl.get('path')!r} w {root} (skip)")
                continue
            if acl.get("hidden"):        # isHidden z CDE → DOS-H na FS
                m["hidden"].add(tuple(parts))
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


def apply_dataset(base, new_m, old_m, traverse, allow_rmdir=True):
    nf, nfi = new_m["folders"], new_m["files"]
    of = old_m.get("folders", {})
    ofi = old_m.get("files", {})
    # phantom filter: zdejmij foldery z SKIP_FOLDERS ze WSZYSTKICH ścieżek
    # (mkdir/acl/hidden je pominą; nieobecne w new_present → orphan-scan usunie).
    nf = {k: v for k, v in nf.items()
          if not any(p in SKIP_FOLDERS for p in k[0])}
    nfi = {k: v for k, v in nfi.items()
           if not any(p in SKIP_FOLDERS for p in k[0])}
    nf_dirs = {p for (p, _) in nf}

    # ── strip: foldery (recursive dla wszystkich — grant też recursive) ──
    for (parts, user) in set(of) - set(nf):
        target = os.path.join(base, *parts)
        if os.path.isdir(target):
            setfacl(["-R", "-x", f"u:{user}", target])
            setfacl(["-R", "-d", "-x", f"u:{user}", target])
        log(f"  strip-folder u:{user} {'/'.join(parts)}")
    # ── strip: pliki WIP ──
    for (parts, user) in set(ofi) - set(nfi):
        target = os.path.join(base, *parts)
        if os.path.isfile(target):
            setfacl(["-x", f"u:{user}", target])
        log(f"  strip-file u:{user} {'/'.join(parts)}")

    # ── apply (plan-then-apply): traverse NIGDY nie nadpisuje grantu ──
    org_id = os.path.relpath(base, ORG_BASE).split(os.sep)[0]
    try:
        gid = grp.getgrnam(f"org-{org_id}").gr_gid
    except KeyError:
        gid = None
    # 0. mkdir-from-manifest: manifest = źródło prawdy struktury (foldery
    #    z web-UI/backfill mogą nie istnieć na FS) — 02700 root:gid
    for (parts, user), lvl in nf.items():
        target = os.path.join(base, *parts)
        if not os.path.isdir(target) and gid is not None:
            try:
                os.makedirs(target, exist_ok=True)
                os.chmod(target, 0o2700)
                os.chown(target, 0, gid)
                log(f"  mkdir-from-manifest {'/'.join(parts)}")
            except OSError as e:
                warn(f"mkdir {target}: {e}")
    # 1. plan: najpierw traverse na ancestory (foldery+pliki), potem
    #    granty targetów NADPISUJĄ (są zawsze >= traverse)
    dir_want = {}
    for (parts, user) in list(nf) + list(nfi):
        for d in ancestors_of(base, parts):
            dir_want.setdefault((d, user), traverse)
    recursive = []
    for (parts, user), lvl in nf.items():
        target = os.path.join(base, *parts)
        if not os.path.isdir(target):
            warn(f"brak katalogu {target} (retry przy następnym pullu)")
            continue
        dir_want[(target, user)] = DIR_PERMS[lvl]
        # DZIEDZICZENIE Z FOLDERU (wszystkie kontenery, WIP też): członek
        # folderu widzi jego zawartość + nowe pliki dziedziczą (default ACL).
        # Model intuicyjny jak NAS. Prywatność per-folder = przyszły wariant
        # (strip default). files[] zostaje na override/wyjątki per-plik.
        recursive.append((target, user, DIR_PERMS[lvl]))
    # 2. aplikacja: traverse na ancestorach (dir_want) + recursive grant +
    #    default ACL (dziedziczenie nowych plików) na każdym folderze-target
    for (d, user), perms in dir_want.items():
        if os.path.isdir(d):
            setfacl(["-m", f"u:{user}:{perms}", d])
    for (target, user, perms) in recursive:
        setfacl(["-R", "-m", f"u:{user}:{perms}", target])
        setfacl(["-R", "-d", "-m", f"u:{user}:{perms}", target])
    # 3. pliki WIP (wyłącznie files[])
    for (parts, user), lvl in nfi.items():
        target = os.path.join(base, *parts)
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

    # ── DOS-H (isHidden z CDE) full-state: manifest hidden→0x2, zdjęte→clear.
    # Osobno od ACL: hidden = kosmetyka widoczności, nie uprawnienia. Folder
    # hidden DALEJ dostępny wg ACL (soft hide, show-hidden odsłania). ──
    new_hidden = {p for p in new_m.get("hidden", set())
                  if not any(x in SKIP_FOLDERS for x in p)}
    old_hidden = old_m.get("hidden", set())
    new_present = nf_dirs | new_hidden
    for parts in new_hidden:
        target = os.path.join(base, *parts)
        if os.path.isdir(target) and set_hidden(target, True):
            log(f"  hide {'/'.join(parts)}")
    # unhide TYLKO foldery DALEJ obecne w manifeście (usunięte z manifestu →
    # rmdir niżej, nie unhide — inaczej pusty ukryty folder znów widoczny).
    for parts in (old_hidden - new_hidden) & new_present:
        target = os.path.join(base, *parts)
        if os.path.isdir(target) and set_hidden(target, False):
            log(f"  unhide {'/'.join(parts)}")

    # ── orphan cleanup (FS-scan full-state): dir na FS w kontenerze, BRAK w
    # manifeście → rmdir. FS-scan (nie manifest-diff) bo stare sieroty nie ma
    # w ŻADNYM manifeście — diff by je przegapił. Pasuje do APP content-gate:
    # empty RO foldery dropowane z manifestu = mają zniknąć z B:. BEZPIECZEŃSTWO:
    # rmdir_empty_tree usuwa TYLKO całkowicie puste drzewo (jeden plik gdziekolwiek
    # → cały tree zostaje, ZERO utraty). Guard: tylko gdy manifest NIEPUSTY
    # (new_present) — chroni przed mass-delete przy transientnym pustym manifeście.
    # Depth-1 pod kontenerem; głębsze dropy łapie następny pull. ──
    if allow_rmdir and new_present:
        for c in CONTAINERS:
            cdir = os.path.join(base, c)
            if not os.path.isdir(cdir):
                continue
            allowed = {p[1] for p in new_present if len(p) >= 2 and p[0] == c}
            if not allowed:
                continue          # kontener bez folderów w manifeście = APP go
                #  NIE zarządza (np. Archive) → NIE ruszamy (bez tego cały
                #  kontener = orphany → puste by zniknęły). Prune tylko tam gdzie
                #  manifest realnie definiuje strukturę.
            try:
                children = list(os.scandir(cdir))
            except OSError:
                continue
            for e in children:
                if not e.is_dir(follow_symlinks=False) or e.name in allowed:
                    continue
                ok, why = rmdir_empty_tree(e.path)
                if ok:
                    log(f"  rmdir-orphan {c}/{e.name}")
                else:
                    warn(f"rmdir-orphan {c}/{e.name}: zostaje ({why})")


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
    manifest_org_id = manifest.get("orgId") or manifest.get("org_id")
    # traverse ZAWSZE r-x: prywatność na SMB gwarantuje hide-unreadable
    # (Samba filtruje z listingu wpisy bez prawa odczytu) + brak entries;
    # --x nie dodawał ochrony, a łamał nawigację Explorera (POSIX: named
    # entry ma pierwszeństwo przed group, mask tnie do --x → brak listingu).
    # strictVisibility w manifeście = informacyjne (steruje treścią entries).
    traverse = "r-x"

    for root in set(old) | set(new):
        base = dataset_base(manifest_org_id, root)
        if base is None:
            warn(f"{slug}: zły datasetRoot {root!r} / orgId "
                 f"{manifest_org_id!r} (skip)")
            continue
        empty = {"folders": {}, "files": {}, "hidden": set()}
        n = new.get(root, empty)
        o = old.get(root, empty)
        if not os.path.isdir(base):
            if n["folders"] or n["files"]:
                warn(f"{slug}: brak datasetu {base} (retry next)")
            continue
        log(f"{slug}: reconcile {root} (dirs {len(n['folders'])}/"
            f"{len(o.get('folders', {}))} files {len(n['files'])}/"
            f"{len(o.get('files', {}))} hidden {len(n.get('hidden', set()))} "
            f"traverse={traverse})")
        apply_dataset(base, n, o, traverse, allow_rmdir=(root in new))

    apply_veto(slug, manifest)

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
