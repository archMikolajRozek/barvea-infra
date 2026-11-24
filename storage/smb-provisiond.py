#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# BARVEA — smb-provisiond v2: konta SMB per (użytkownik, organizacja).
# Uruchamiać W LXC 201 (storage) jako root (systemd service).
#
# v2 (2026-11-24, strumień S1, kontrakt APP app/docs/INFRA_HANDOFF_SMB_KONTA_PER_ORGANIZACJA_2026-11-23.md):
#   konto = para (user, org): nazwa u_<10 userId>_<10 orgId> (liczy APP), uid z puli,
#   JEDNA grupa (primary) = org-<orgId>, własne hasło. Konto A nigdy nie dostaje
#   dostępu do udziału org B (valid users=@org-<id>, brak grup wspólnych).
#   Stare konta v1 (u_<6-12>, multi-org przez usermod -aG) są akceptowane tylko do
#   końca migracji: LEGACY_ACCOUNTS=1 w env (po migracji 0 → 400 legacy_disabled).
#
# API (Bearer, LAN-only) — kształty bez zmian wobec v1:
#   POST /smb/user {org_id, smb_username, rotate?}
#     → 201 {created:true,  uid, gid, password}      (nowe konto)
#     → 200 {created:false, uid, gid, password:null} (istnieje; hasła nie znamy)
#     → 200 {created:false, uid, gid, password}      (istnieje + rotate:true — APP woła
#            tylko gdy user nie ma innej żywej sesji w org; sesje SMB zestawione przeżywają)
#     → 400 bad_org_id | bad_smb_username | username_org_mismatch | legacy_disabled
#     → 404 org_not_provisioned (brak /srv/orgs/<org_id> lub grupy org-<id>)
#     → 409 account_belongs_to_other_org (konto per org istnieje w innej grupie — nigdy nie dopisujemy)
#     → 409 account_disabled (konto wyłączone przez rekoncyliację — rotate go nie włącza)
#   DELETE /smb/user/<org_id>/<username> → 200 / 404
#   GET /healthz → {ok:true, version:2}
#
# Rekoncyliacja (timer smb-reconcile.timer, raz dziennie; także `--reconcile` ręcznie, `--dry-run`):
#   konta per org nieobecne w manifestach ACL (/var/lib/barvea-acl/*.manifest.json,
#   lista top-level `smbAccounts` albo wpisy entries[].smbUsername) → smbpasswd -d
#   (wyłączone, zapis daty w STATE_DIR/disabled.json); po RECONCILE_DELETE_DAYS (30)
#   → smbpasswd -x + userdel. Konto, które wróci do manifestu → smbpasswd -e.
#   Bez top-level `smbAccounts` w KAŻDYM manifeście = tryb „tylko raport” (nic nie wyłącza).
#   Konta legacy (v1) rekoncyliacja omija, dopóki LEGACY_ACCOUNTS=1.
#
# uid allocator: /var/lib/barvea-smb/uid-counter (globalny, start UID_START,
# omija zajęte getent-em).
#
# Config: /etc/barvea/smb-provisiond.env
#   TOKEN=<64-hex>  BIND=10.10.0.40  PORT=8722  UID_START=5100
#   LEGACY_ACCOUNTS=1  RECONCILE_DELETE_DAYS=30  ACL_STATE_DIR=/var/lib/barvea-acl
# ═══════════════════════════════════════════════════════════════
import glob, hmac, json, os, re, secrets, string, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = 2
CONF = "/etc/barvea/smb-provisiond.env"
STATE_DIR = "/var/lib/barvea-smb"
ORG_BASE = "/srv/orgs"
LOCK = threading.Lock()
CFG = {}

ORG_ID_RE = re.compile(r"^c[a-z0-9]{20,30}$")
USER_V2_RE = re.compile(r"^u_([a-z0-9]{10})_([a-z0-9]{10})$")   # per (user, org)
USER_V1_RE = re.compile(r"^u_[a-z0-9]{6,12}$")                  # legacy multi-org


def log(msg):
    print(msg, flush=True)


def load_cfg():
    cfg = {"BIND": "10.10.0.40", "PORT": "8722", "UID_START": "5100",
           "LEGACY_ACCOUNTS": "1", "RECONCILE_DELETE_DAYS": "30",
           "ACL_STATE_DIR": "/var/lib/barvea-acl"}
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"')
    if len(cfg.get("TOKEN", "")) < 24:
        log("FATAL: TOKEN brak/za krótki w " + CONF)
        sys.exit(1)
    return cfg


def legacy_allowed():
    return CFG.get("LEGACY_ACCOUNTS", "1") == "1"


def run(cmd, input_text=None):
    return subprocess.run(cmd, capture_output=True, text=True,
                          input=input_text)


def getent(db, key):
    return run(["getent", db, str(key)]).returncode == 0


def user_gid(username):
    r = run(["id", "-g", username])
    return int(r.stdout.strip()) if r.returncode == 0 else None


def user_uid(username):
    r = run(["id", "-u", username])
    return int(r.stdout.strip()) if r.returncode == 0 else None


def org_group(org_id):
    return f"org-{org_id}"


def user_groups(username):
    """Wszystkie grupy usera (primary + supplementary), po nazwie."""
    r = run(["id", "-nG", username])
    return r.stdout.split() if r.returncode == 0 else []


def user_org_groups(username):
    return [g for g in user_groups(username) if g.startswith("org-")]


def group_gid(group):
    r = run(["getent", "group", group])
    if r.returncode != 0:
        return None
    return int(r.stdout.split(":")[2])


def username_kind(username):
    """'v2' (per org), 'v1' (legacy) albo None."""
    if USER_V2_RE.match(username):
        return "v2"
    if USER_V1_RE.match(username):
        return "v1"
    return None


def v2_matches_org(username, org_id):
    m = USER_V2_RE.match(username)
    return bool(m) and m.group(2) == org_id[-10:]


def alloc_uid():
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    counter = os.path.join(STATE_DIR, "uid-counter")
    start = int(CFG["UID_START"])
    try:
        with open(counter) as f:
            nxt = max(int(f.read().strip()), start)
    except (FileNotFoundError, ValueError):
        nxt = start
    while getent("passwd", nxt):
        nxt += 1
    with open(counter + ".tmp", "w") as f:
        f.write(str(nxt + 1))
    os.replace(counter + ".tmp", counter)
    return nxt


def gen_password():
    alphabet = string.ascii_letters + string.digits + "!#%+,-./:=@_"
    return "".join(secrets.choice(alphabet) for _ in range(24))


def smbpasswd_set(username, password):
    r = run(["smbpasswd", "-s", "-a", username],
            input_text=f"{password}\n{password}\n")
    if r.returncode != 0:
        raise RuntimeError(f"smbpasswd failed: {r.stderr.strip()[:200]}")
    run(["smbpasswd", "-e", username])  # enable (idempotent)


# ── provisioning ──────────────────────────────────────────────────

def provision_user(org_id, username, rotate):
    grp = org_group(org_id)
    gid = group_gid(grp)
    if gid is None or not os.path.isdir(os.path.join(ORG_BASE, org_id)):
        return 404, {"error": "org_not_provisioned",
                     "detail": f"brak {grp} lub /srv/orgs/{org_id} — "
                               "najpierw provision-org.sh"}
    kind = username_kind(username)
    if kind == "v2" and not v2_matches_org(username, org_id):
        return 400, {"error": "username_org_mismatch",
                     "detail": "sufiks nazwy != ostatnie 10 znaków org_id"}
    if kind == "v1" and not legacy_allowed():
        return 400, {"error": "legacy_disabled",
                     "detail": "konta v1 wyłączone po migracji (LEGACY_ACCOUNTS=0)"}

    if getent("passwd", username):
        uid = user_uid(username)
        if username in _load_disabled():
            # Wyłączone przez rekoncyliację (poza smbAccounts manifestu) — rotate NIE może
            # go włączyć; włącza tylko powrót do manifestu (reconcile → smbpasswd -e).
            return 409, {"error": "account_disabled",
                         "detail": "konto wyłączone przez rekoncyliację (poza manifestem ACL)"}
        if kind == "v2":
            # Konto per org: dokładnie jedna grupa org. Inna grupa = cudze konto.
            if user_gid(username) != gid or grp not in user_groups(username):
                return 409, {"error": "account_belongs_to_other_org",
                             "detail": "konto per org istnieje w innej grupie"}
        else:
            # LEGACY v1 (multi-org): zachowanie v1 do końca migracji.
            if grp not in user_groups(username):
                r = run(["usermod", "-aG", grp, username])
                if r.returncode != 0:
                    raise RuntimeError(
                        f"usermod -aG failed: {r.stderr.strip()[:200]}")
                log(f"legacy multi-org: {username} +group {grp}")
        if rotate:
            pw = gen_password()
            smbpasswd_set(username, pw)
            _reconcile_mark_enabled(username)
            log(f"rotate: {username}")
            return 200, {"created": False, "uid": uid, "gid": gid,
                         "password": pw}
        return 200, {"created": False, "uid": uid, "gid": gid,
                     "password": None}

    uid = alloc_uid()
    # -N: bez grupy prywatnej; -g gid: primary = org; -G "": zero grup dodatkowych.
    r = run(["useradd", "-M", "-N", "-u", str(uid), "-g", str(gid), "-G", "",
             "-s", "/usr/sbin/nologin", username])
    if r.returncode != 0:
        raise RuntimeError(f"useradd failed: {r.stderr.strip()[:200]}")
    pw = gen_password()
    smbpasswd_set(username, pw)
    log(f"created({kind}): {username} uid={uid} gid={gid} (org {org_id[:10]}…)")
    return 201, {"created": True, "uid": uid, "gid": gid, "password": pw}


def deprovision_user(org_id, username):
    grp = org_group(org_id)
    gid = group_gid(grp)
    if gid is None:
        return 404, {"error": "org_not_provisioned"}
    if not getent("passwd", username):
        return 404, {"error": "user_not_found"}
    if grp not in user_org_groups(username):
        return 404, {"error": "user_not_in_org"}
    kind = username_kind(username)
    remaining = [g for g in user_org_groups(username) if g != grp]
    if kind == "v1" and remaining:
        # LEGACY multi-org: zdejmij tylko członkostwo w tej grupie.
        r = run(["gpasswd", "-d", username, grp])
        if r.returncode != 0 and user_gid(username) == gid:
            run(["usermod", "-g", remaining[0], username])
            run(["gpasswd", "-d", username, grp])
        log(f"legacy multi-org: {username} -group {grp} ({len(remaining)} left)")
        return 200, {"applied": True, "action": "removed_from_org",
                     "orgs_left": len(remaining)}
    run(["smbpasswd", "-x", username])
    r = run(["userdel", username])
    if r.returncode != 0:
        raise RuntimeError(f"userdel failed: {r.stderr.strip()[:200]}")
    _reconcile_forget(username)
    log(f"deleted({kind}): {username} (org {org_id[:10]}…)")
    return 200, {"applied": True, "action": "deleted"}


# ── rekoncyliacja z manifestami ACL ───────────────────────────────

def _disabled_path():
    return os.path.join(STATE_DIR, "disabled.json")


def _load_disabled():
    try:
        with open(_disabled_path()) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def _save_disabled(d):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = _disabled_path() + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f)
    os.replace(tmp, _disabled_path())


def _reconcile_mark_enabled(username):
    d = _load_disabled()
    if username in d:
        del d[username]
        _save_disabled(d)


def _reconcile_forget(username):
    _reconcile_mark_enabled(username)


def manifest_accounts():
    """Zbiór nazw kont SMB ze wszystkich manifestów ACL (per org).
    Zwraca (accounts, explicit): explicit=True gdy KAŻDY manifest ma listę
    top-level `smbAccounts` (pełna lista osób z dostępem Drive w org). Bez niej
    bierzemy entries[].smbUsername — niepełne (osoba bez wpisów folderowych
    zniknęłaby) → wtedy rekoncyliacja NIE wyłącza, tylko raportuje."""
    accounts, explicit, n = set(), True, 0
    for path in glob.glob(os.path.join(CFG["ACL_STATE_DIR"], "*.manifest.json")):
        try:
            with open(path) as f:
                m = json.load(f)
        except (OSError, ValueError) as e:
            log(f"reconcile: manifest {path} nieczytelny: {e}")
            explicit = False
            continue
        n += 1
        lst = m.get("smbAccounts")
        if isinstance(lst, list):
            for a in lst:
                name = a.get("smbUsername") if isinstance(a, dict) else a
                if isinstance(name, str):
                    accounts.add(name)
        else:
            explicit = False
        for proj in m.get("projects", []) or []:
            for fo in proj.get("folders", []) or []:
                for e in (fo.get("acl") or {}).get("entries", []) or []:
                    if e.get("smbUsername"):
                        accounts.add(e["smbUsername"])
                for fe in fo.get("files", []) or []:
                    for e in fe.get("entries", []) or []:
                        if e.get("smbUsername"):
                            accounts.add(e["smbUsername"])
    return accounts, (explicit and n > 0)


def local_accounts():
    """Konta u_* z uid >= UID_START (nasze), z rodzajem."""
    start = int(CFG["UID_START"])
    out = []
    with open("/etc/passwd") as f:
        for line in f:
            p = line.split(":")
            if len(p) < 3:
                continue
            name, uid = p[0], int(p[2])
            kind = username_kind(name)
            if kind and uid >= start:
                out.append((name, kind))
    return out


def reconcile(apply=True):
    accounts, explicit = manifest_accounts()
    disabled = _load_disabled()
    now = int(time.time())
    keep_days = int(CFG.get("RECONCILE_DELETE_DAYS", "30"))
    stats = {"seen": 0, "disabled": 0, "reenabled": 0, "deleted": 0,
             "skipped_legacy": 0, "orphans": []}
    for name, kind in local_accounts():
        stats["seen"] += 1
        if kind == "v1" and legacy_allowed():
            stats["skipped_legacy"] += 1
            continue
        if name in accounts:
            if name in disabled:
                if apply:
                    run(["smbpasswd", "-e", name])
                    _reconcile_mark_enabled(name)
                    disabled = _load_disabled()
                stats["reenabled"] += 1
            continue
        stats["orphans"].append(name)
        if not explicit:
            continue  # brak pełnej listy w manifestach → tylko raport
        since = disabled.get(name)
        if since is None:
            if apply:
                run(["smbpasswd", "-d", name])
                disabled[name] = now
                _save_disabled(disabled)
            stats["disabled"] += 1
            log(f"reconcile: disabled {name} (poza manifestami)")
        elif now - since >= keep_days * 86400:
            if apply:
                run(["smbpasswd", "-x", name])
                r = run(["userdel", name])
                if r.returncode != 0:
                    log(f"reconcile: userdel {name} failed: {r.stderr.strip()[:120]}")
                    continue
                del disabled[name]
                _save_disabled(disabled)
            stats["deleted"] += 1
            log(f"reconcile: deleted {name} (wyłączone > {keep_days} dni)")
    mode = "APPLY" if apply else "DRY"
    if not explicit:
        log("reconcile: manifesty bez top-level smbAccounts — tylko raport, nic nie wyłączam")
    log(f"reconcile[{mode}]: {json.dumps(stats)}")
    return stats


# ── HTTP ──────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    server_version = "smb-provisiond"
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        h = self.headers.get("Authorization", "")
        return h.startswith("Bearer ") and hmac.compare_digest(
            h[7:], CFG["TOKEN"])

    def log_message(self, fmt, *args):
        pass  # własne logi (nigdy nie logujemy haseł)

    def do_GET(self):
        if self.path == "/healthz":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"ok": True, "version": VERSION,
                                    "legacy_accounts": legacy_allowed()})
        self._send(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/smb/user":
            return self._send(404, {"error": "not_found"})
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            if n > 4096:
                return self._send(413, {"error": "too_large"})
            body = json.loads(self.rfile.read(n))
            org_id = body.get("org_id", "")
            username = body.get("smb_username", "")
            rotate = bool(body.get("rotate", False))
            if not ORG_ID_RE.match(org_id):
                return self._send(400, {"error": "bad_org_id"})
            if username_kind(username) is None:
                return self._send(400, {"error": "bad_smb_username",
                                        "detail": "^u_[a-z0-9]{10}_[a-z0-9]{10}$"})
            with LOCK:
                code, resp = provision_user(org_id, username, rotate)
            return self._send(code, resp)
        except json.JSONDecodeError:
            return self._send(400, {"error": "bad_json"})
        except Exception as e:
            log(f"ERROR POST: {e}")
            return self._send(500, {"error": "internal",
                                    "detail": str(e)[:200]})

    def do_DELETE(self):
        m = re.match(r"^/smb/user/([^/]+)/([^/]+)$", self.path)
        if not m:
            return self._send(404, {"error": "not_found"})
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        org_id, username = m.group(1), m.group(2)
        if not ORG_ID_RE.match(org_id) or username_kind(username) is None:
            return self._send(400, {"error": "bad_params"})
        try:
            with LOCK:
                code, resp = deprovision_user(org_id, username)
            return self._send(code, resp)
        except Exception as e:
            log(f"ERROR DELETE: {e}")
            return self._send(500, {"error": "internal",
                                    "detail": str(e)[:200]})


def main():
    global CFG
    CFG = load_cfg()
    if "--reconcile" in sys.argv:
        with LOCK:
            reconcile(apply="--dry-run" not in sys.argv)
        return
    addr = (CFG["BIND"], int(CFG["PORT"]))
    log(f"smb-provisiond v{VERSION} start {addr[0]}:{addr[1]} legacy={legacy_allowed()}")
    ThreadingHTTPServer(addr, Handler).serve_forever()


if __name__ == "__main__":
    main()
