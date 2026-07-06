#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# BARVEA — smb-provisiond: per-user SMB provisioning (odbiornik z APP).
# Uruchamiać W LXC 201 (storage) jako root (systemd service).
#
# Zamyka OSTATNI ręczny element Drive flow: APP przy nadaniu userowi
# Drive-access woła POST → my tworzymy POSIX usera + konto Samba +
# zwracamy wygenerowane hasło → APP seal (Vault per-org-keys) →
# DriveSmbCredential → smb_config w sessions/start → mount bez rąk.
#
# API (Bearer, LAN-only):
#   POST /smb/user {org_id, smb_username, rotate?}
#     → 201 {created:true,  uid, gid, password}      (nowy user)
#     → 200 {created:false, uid, gid, password:null} (istnieje; hasła nie znamy)
#     → 200 {created:false, uid, gid, password}      (istnieje + rotate:true)
#     → 404 org_not_provisioned (brak /srv/orgs/<org_id> lub grupy org-<id>
#            — org-level robi provision-org.sh, to osobny akt)
#   DELETE /smb/user/<org_id>/<username> → 200 / 404
#     (guard: user musi należeć do grupy org-<org_id> — cudzych nie tykamy)
#   GET /healthz → {ok:true}
#
# uid allocator: /var/lib/barvea-smb/uid-counter (globalny, start UID_START,
# omija zajęte getent-em). gid = istniejąca grupa org-<org_id> (z provision).
# Share ma `valid users = @org-<id>` → członkostwo w grupie = dostęp.
#
# Config: /etc/barvea/smb-provisiond.env
#   TOKEN=<64-hex>  BIND=10.10.0.40  PORT=8722  UID_START=5100
# ═══════════════════════════════════════════════════════════════
import hmac, json, os, re, secrets, string, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = "/etc/barvea/smb-provisiond.env"
STATE_DIR = "/var/lib/barvea-smb"
ORG_BASE = "/srv/orgs"
LOCK = threading.Lock()
CFG = {}

ORG_ID_RE = re.compile(r"^c[a-z0-9]{20,30}$")
USER_RE = re.compile(r"^u_[a-z0-9]{6,12}$")


def log(msg):
    print(msg, flush=True)


def load_cfg():
    cfg = {"BIND": "10.10.0.40", "PORT": "8722", "UID_START": "5100"}
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


def group_gid(group):
    r = run(["getent", "group", group])
    if r.returncode != 0:
        return None
    return int(r.stdout.split(":")[2])


def alloc_uid():
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    counter = os.path.join(STATE_DIR, "uid-counter")
    start = int(CFG["UID_START"])
    try:
        with open(counter) as f:
            nxt = max(int(f.read().strip()), start)
    except (FileNotFoundError, ValueError):
        nxt = start
    while getent("passwd", nxt):  # omijaj zajęte (np. ręczne 5011)
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


def provision_user(org_id, username, rotate):
    grp = org_group(org_id)
    gid = group_gid(grp)
    if gid is None or not os.path.isdir(os.path.join(ORG_BASE, org_id)):
        return 404, {"error": "org_not_provisioned",
                     "detail": f"brak {grp} lub /srv/orgs/{org_id} — "
                               "najpierw provision-org.sh"}
    if getent("passwd", username):
        # user istnieje — guard: musi być w TEJ grupie org
        if user_gid(username) != gid:
            return 409, {"error": "user_in_other_org"}
        uid = user_uid(username)
        if rotate:
            pw = gen_password()
            smbpasswd_set(username, pw)
            log(f"rotate: {username} (org {org_id[:10]}…)")
            return 200, {"created": False, "uid": uid, "gid": gid,
                         "password": pw}
        return 200, {"created": False, "uid": uid, "gid": gid,
                     "password": None}
    uid = alloc_uid()
    r = run(["useradd", "-M", "-u", str(uid), "-g", str(gid),
             "-s", "/usr/sbin/nologin", username])
    if r.returncode != 0:
        raise RuntimeError(f"useradd failed: {r.stderr.strip()[:200]}")
    pw = gen_password()
    smbpasswd_set(username, pw)
    log(f"created: {username} uid={uid} gid={gid} (org {org_id[:10]}…)")
    return 201, {"created": True, "uid": uid, "gid": gid, "password": pw}


def deprovision_user(org_id, username):
    grp = org_group(org_id)
    gid = group_gid(grp)
    if gid is None:
        return 404, {"error": "org_not_provisioned"}
    if not getent("passwd", username):
        return 404, {"error": "user_not_found"}
    if user_gid(username) != gid:
        return 409, {"error": "user_in_other_org"}
    run(["smbpasswd", "-x", username])
    r = run(["userdel", username])
    if r.returncode != 0:
        raise RuntimeError(f"userdel failed: {r.stderr.strip()[:200]}")
    log(f"deleted: {username} (org {org_id[:10]}…)")
    return 200, {"applied": True, "action": "deleted"}


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
            return self._send(200, {"ok": True})
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
            if not USER_RE.match(username):
                return self._send(400, {"error": "bad_smb_username",
                                        "detail": "^u_[a-z0-9]{6,12}$"})
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
        if not ORG_ID_RE.match(org_id) or not USER_RE.match(username):
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
    addr = (CFG["BIND"], int(CFG["PORT"]))
    log(f"smb-provisiond start {addr[0]}:{addr[1]}")
    ThreadingHTTPServer(addr, Handler).serve_forever()


if __name__ == "__main__":
    main()
