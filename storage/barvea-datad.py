#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# BARVEA — barvea-datad: CDE data-plane (jeden ZFS store). LXC 201, root.
#
# Kontrakt zamrożony z APP (2026-07-06). Layout:
#   /srv/orgs/<org_id>/<project_id>/{WIP,Shared,Published,Archive}/<folders>/<plik>
#
# API (Bearer BARVEA_DATA_TOKEN, LAN bind 10.10.0.40:8723):
#   GET  /healthz
#   POST /project-skeleton {org_id, project_id, request_id?}
#   POST /files?org_id=&path=<rel>   body=raw bytes (Content-Length wymagany)
#        nagłówki: X-Request-Id (origin_request_id do journalu)
#        → 201/200 {size, sha256, mtime}; 423 Locked gdy target zablokowany
#   POST /cde/promote {org_id, src_path, dst_path, read_only, chown_system,
#                      move?, request_id?}
#        → 200 {size, mtime, sha256} | 200 {already:true} | 409 promote_conflict
#   GET  /fs-tree/<org_id>?project=<id>&hash=1
#        → {entries:[{path,kind,size,mtime,owner_smb_username}]}
#   GET  /fs-journal/<org_id>?since=<seq>
#        → {events:[…], latest_seq} | 410 {oldest_seq}
#
# Journal: /var/lib/barvea-data/journal/<org>.jsonl (append, seq monotonic).
# v1: eventy source:"api" (files/promote/skeleton). v1.1: parser Samba
# full_audit dopisze source:"smb" z actorem — ten sam format.
# Event: {seq, ts, op, path, path_to?, kind, size?, mtime?, actor, source,
#         origin_request_id?}
# ═══════════════════════════════════════════════════════════════
import base64, hashlib, hmac, json, os, pwd, re, shutil, sys, threading, time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = "/etc/barvea/barvea-datad.env"
STATE = "/var/lib/barvea-data"
ORG_BASE = "/srv/orgs"
CONTAINERS = ("WIP", "Shared", "Published", "Archive")
MAX_UPLOAD = 2 * 1024 * 1024 * 1024  # 2 GB
CHUNK = 1024 * 1024
LOCK = threading.Lock()      # journal + mutacje
CFG = {}

ORG_ID_RE = re.compile(r"^c[a-z0-9]{20,30}$")


def log(msg):
    print(msg, flush=True)


def load_cfg():
    cfg = {"BIND": "10.10.0.40", "PORT": "8723"}
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"')
    if len(cfg.get("TOKEN", "")) < 24:
        log("FATAL: TOKEN brak/za krótki w " + CONF)
        sys.exit(1)
    # SIGN_KEY: osobny sekret do HMAC tokenów /dl (endpoint publiczny —
    # kompromitacja Bearer API ≠ możliwość podpisywania URL-i)
    if len(cfg.get("SIGN_KEY", "")) < 24:
        log("FATAL: SIGN_KEY brak/za krótki w " + CONF)
        sys.exit(1)
    cfg.setdefault("PUBLIC_DL_BASE", "https://barvea.com")
    cfg.setdefault("DL_TTL", "900")
    return cfg


# ── path safety ────────────────────────────────────────────────
def valid_component(c):
    return bool(c) and c not in (".", "..") and "/" not in c \
        and "\\" not in c and "\x00" not in c \
        and not any(ord(ch) < 32 for ch in c)


def safe_join(org_id, rel):
    """Zwraca (abs_path, rel_parts) albo (None, None). rel MUSI zaczynać się
    kontenerem projektowym: <project_id>/<Container>/…"""
    parts = [p for p in rel.replace("\\", "/").split("/") if p]
    if len(parts) < 2 or not all(valid_component(p) for p in parts):
        return None, None
    if parts[1] not in CONTAINERS:
        return None, None
    base = os.path.join(ORG_BASE, org_id)
    p = os.path.join(base, *parts)
    # realpath obrona przed symlink-escape (sprawdzamy katalog nadrzędny,
    # bo sam plik może jeszcze nie istnieć)
    parent_real = os.path.realpath(os.path.dirname(p))
    if parent_real != os.path.dirname(p) and not parent_real.startswith(
            os.path.realpath(base) + os.sep):
        return None, None
    return p, parts


def org_gid(org_id):
    import grp
    try:
        return grp.getgrnam(f"org-{org_id}").gr_gid
    except KeyError:
        return None


def is_locked(path):
    """Locked = promowany artefakt: root-owned i bez bitów zapisu."""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return False
    return st.st_uid == 0 and (st.st_mode & 0o222) == 0


def owner_name(uid):
    try:
        n = pwd.getpwuid(uid).pw_name
    except KeyError:
        return None
    return n if n.startswith("u_") else None


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


# ── signed download tokens (self-contained: b64url(json).hmac_hex) ─
# Whitelist MIME dla inline (podgląd w przeglądarce). WSZYSTKO spoza
# listy = attachment+octet-stream niezależnie od flagi — uploadowany
# HTML/SVG nie może się wyrenderować na naszej domenie (XSS).
INLINE_MIME = {".pdf": "application/pdf", ".png": "image/png",
               ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
               ".webp": "image/webp", ".gif": "image/gif"}


def dl_sign(org_id, rel_path, ttl, inline=False):
    payload = json.dumps(
        {"o": org_id, "p": rel_path, "e": int(time.time()) + ttl,
         "d": "i" if inline else "a"},
        separators=(",", ":")).encode()
    b64 = base64.urlsafe_b64encode(payload).decode().rstrip("=")
    sig = hmac.new(CFG["SIGN_KEY"].encode(), b64.encode(),
                   hashlib.sha256).hexdigest()
    return f"{b64}.{sig}"


def dl_verify(token):
    """→ (org_id, rel_path, inline) albo None (zły podpis/format/wygasły)."""
    try:
        b64, sig = token.split(".", 1)
        want = hmac.new(CFG["SIGN_KEY"].encode(), b64.encode(),
                        hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, want):
            return None
        pad = "=" * (-len(b64) % 4)
        d = json.loads(base64.urlsafe_b64decode(b64 + pad))
        if int(d["e"]) < time.time():
            return None
        return d["o"], d["p"], d.get("d") == "i"
    except Exception:
        return None


# ── journal ────────────────────────────────────────────────────
def journal_paths(org_id):
    d = os.path.join(STATE, "journal")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return os.path.join(d, f"{org_id}.jsonl"), \
        os.path.join(d, f"{org_id}.seq")


def journal_append(org_id, ev):
    """Wołać pod LOCK. Nadaje seq, zapisuje event."""
    jf, sf = journal_paths(org_id)
    try:
        with open(sf) as f:
            seq = int(f.read().strip()) + 1
    except (FileNotFoundError, ValueError):
        seq = 1
    ev = {"seq": seq, "ts": int(time.time()), **ev}
    with open(jf, "a") as f:
        f.write(json.dumps(ev, separators=(",", ":")) + "\n")
        f.flush()
        os.fsync(f.fileno())
    with open(sf + ".tmp", "w") as f:
        f.write(str(seq))
    os.replace(sf + ".tmp", sf)
    return seq


def journal_read(org_id, since):
    jf, sf = journal_paths(org_id)
    try:
        with open(sf) as f:
            latest = int(f.read().strip())
    except (FileNotFoundError, ValueError):
        latest = 0
    if since > latest:
        return None, latest, None  # nonsensowny kursor → potraktuj jak gap
    events, oldest = [], None
    try:
        with open(jf) as f:
            for line in f:
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if oldest is None:
                    oldest = ev["seq"]
                if ev["seq"] > since:
                    events.append(ev)
    except FileNotFoundError:
        oldest = None
    if oldest is not None and since and since < oldest - 1:
        return None, latest, oldest  # gap: kursor sprzed retencji
    return events, latest, oldest


# ── operacje ───────────────────────────────────────────────────
def op_skeleton(org_id, project_id, request_id):
    gid = org_gid(org_id)
    if gid is None or not os.path.isdir(os.path.join(ORG_BASE, org_id)):
        return 404, {"error": "org_not_provisioned"}
    if not valid_component(project_id):
        return 400, {"error": "bad_project_id"}
    base = os.path.join(ORG_BASE, org_id, project_id)
    created = []
    for c in CONTAINERS:
        d = os.path.join(base, c)
        if not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
            # SGID dziedziczy grupę (quota/księgowość), ale grupa BEZ bitów
            # dostępu — wejście wyłącznie przez per-user ACL z manifestu
            # (WIP-privacy: grupa=cała org byłaby backdoorem)
            os.chmod(d, 0o2700)
            os.chown(d, 0, gid)
            created.append(c)
            journal_append(org_id, {
                "op": "mkdir", "path": f"{project_id}/{c}", "kind": "dir",
                "actor": None, "source": "api",
                "origin_request_id": request_id})
    if created:
        os.chmod(base, 0o2700)
        os.chown(base, 0, gid)
    return (201 if created else 200), {"created": created}


def op_upload(handler, org_id, rel, request_id):
    gid = org_gid(org_id)
    if gid is None:
        return 404, {"error": "org_not_provisioned"}
    target, parts = safe_join(org_id, rel)
    if target is None:
        return 400, {"error": "bad_path"}
    n = int(handler.headers.get("Content-Length") or -1)
    if n < 0:
        return 411, {"error": "length_required"}
    if n > MAX_UPLOAD:
        return 413, {"error": "too_large"}
    if is_locked(target):
        return 423, {"error": "locked"}
    existed = os.path.exists(target)
    parent = os.path.dirname(target)
    os.makedirs(parent, exist_ok=True)
    tmp = target + ".barvea-tmp"
    h = hashlib.sha256()
    got = 0
    try:
        with open(tmp, "wb") as f:
            while got < n:
                chunk = handler.rfile.read(min(CHUNK, n - got))
                if not chunk:
                    raise IOError("short body")
                f.write(chunk)
                h.update(chunk)
                got += len(chunk)
            f.flush()
            os.fsync(f.fileno())
        # 0600: plik prywatny by-default — czytelność nadaje wyłącznie
        # per-user ACL z manifestu (files[] dla WIP)
        os.chmod(tmp, 0o600)
        os.chown(tmp, 0, gid)
        os.replace(tmp, target)
    except Exception:
        try:
            os.remove(tmp)
        except FileNotFoundError:
            pass
        raise
    st = os.stat(target)
    journal_append(org_id, {
        "op": "modify" if existed else "create", "path": "/".join(parts),
        "kind": "file", "size": st.st_size, "mtime": int(st.st_mtime),
        "actor": None, "source": "api", "origin_request_id": request_id})
    log(f"upload {'modify' if existed else 'create'}: "
        f"{org_id[:10]}…/{'/'.join(parts)} ({st.st_size}B)")
    return (200 if existed else 201), {
        "size": st.st_size, "sha256": h.hexdigest(),
        "mtime": int(st.st_mtime)}


def op_promote(org_id, body):
    gid = org_gid(org_id)
    if gid is None:
        return 404, {"error": "org_not_provisioned"}
    src, src_parts = safe_join(org_id, body.get("src_path", ""))
    dst, dst_parts = safe_join(org_id, body.get("dst_path", ""))
    if src is None or dst is None:
        return 400, {"error": "bad_path"}
    if not os.path.isfile(src):
        return 404, {"error": "src_not_found"}
    move = bool(body.get("move", False))
    read_only = bool(body.get("read_only", True))
    chown_system = bool(body.get("chown_system", True))
    rid = body.get("request_id")
    src_sha = sha256_file(src)
    if os.path.exists(dst):
        dst_sha = sha256_file(dst)
        if dst_sha == src_sha:
            st = os.stat(dst)
            return 200, {"already": True, "size": st.st_size,
                         "sha256": dst_sha, "mtime": int(st.st_mtime)}
        return 409, {"error": "promote_conflict",
                     "src_sha": src_sha, "existing_sha": dst_sha}
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if move:
        os.replace(src, dst)  # ten sam dataset — atomowy rename
    else:
        tmp = dst + ".barvea-tmp"
        try:
            shutil.copyfile(src, tmp)
            with open(tmp, "rb") as f:
                os.fsync(f.fileno())
            os.replace(tmp, dst)
        except Exception:
            try:
                os.remove(tmp)
            except FileNotFoundError:
                pass
            raise
    if read_only:
        os.chmod(dst, 0o400)  # group bez r — dostęp per-user z ACL
    if chown_system:
        os.chown(dst, 0, gid)
    st = os.stat(dst)
    if move:
        journal_append(org_id, {
            "op": "move", "path": "/".join(src_parts),
            "path_to": "/".join(dst_parts), "kind": "file",
            "size": st.st_size, "mtime": int(st.st_mtime),
            "actor": None, "source": "api", "origin_request_id": rid})
    else:
        journal_append(org_id, {
            "op": "create", "path": "/".join(dst_parts), "kind": "file",
            "size": st.st_size, "mtime": int(st.st_mtime),
            "actor": None, "source": "api", "origin_request_id": rid})
    log(f"promote {'move' if move else 'copy'}: {'/'.join(src_parts)} -> "
        f"{'/'.join(dst_parts)}")
    return 200, {"size": st.st_size, "sha256": src_sha,
                 "mtime": int(st.st_mtime)}


def op_lock(org_id, body):
    """In-place lock (migracja/adhoc): 0400 + chown root — bez kopii."""
    gid = org_gid(org_id)
    if gid is None:
        return 404, {"error": "org_not_provisioned"}
    target, parts = safe_join(org_id, body.get("path", ""))
    if target is None:
        return 400, {"error": "bad_path"}
    if not os.path.isfile(target):
        return 404, {"error": "not_found"}
    already = is_locked(target)
    sha = sha256_file(target)
    if not already:
        os.chmod(target, 0o400)
        os.chown(target, 0, gid)
        log(f"lock: {'/'.join(parts)}")
    st = os.stat(target)
    return 200, {"locked": True, "already": already, "sha256": sha,
                 "size": st.st_size, "mtime": int(st.st_mtime)}


def op_fs_tree(org_id, project, want_hash):
    base = os.path.join(ORG_BASE, org_id)
    if not os.path.isdir(base):
        return 404, {"error": "org_not_provisioned"}
    root = os.path.join(base, project) if project else base
    if not os.path.realpath(root).startswith(os.path.realpath(base)):
        return 400, {"error": "bad_project"}
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if valid_component(d)]
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            try:
                st = os.stat(p, follow_symlinks=False)
            except OSError:
                continue
            rel = os.path.relpath(p, base).replace(os.sep, "/")
            kind = "dir" if name in dirnames else "file"
            e = {"path": rel, "kind": kind,
                 "size": st.st_size if kind == "file" else 0,
                 "mtime": int(st.st_mtime),
                 "owner_smb_username": owner_name(st.st_uid)}
            if want_hash and kind == "file":
                e["sha256"] = sha256_file(p)
            entries.append(e)
    return 200, {"entries": entries}


# ── HTTP ───────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    server_version = "barvea-datad"
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        if code >= 400:
            # ścieżki błędów mogły nie skonsumować request-body — zamknij
            # połączenie, inaczej resztki kleją się z następnym requestem
            self.close_connection = True
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
        pass

    def _json_body(self, limit=65536):
        n = int(self.headers.get("Content-Length", 0))
        if n > limit:
            raise ValueError("too_large")
        return json.loads(self.rfile.read(n))

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path.startswith("/dl/"):
            # PUBLICZNY (przez Caddy /dl/*) — auth = HMAC token z TTL
            v = dl_verify(u.path[4:])
            if v is None:
                return self._send(403, {"error": "bad_or_expired_token"})
            org, rel, inline = v
            target, _ = safe_join(org, rel) if ORG_ID_RE.match(org) \
                else (None, None)
            if target is None or not os.path.isfile(target):
                return self._send(404, {"error": "not_found"})
            try:
                st = os.stat(target)
                safe_name = re.sub(r"[^A-Za-z0-9._ -]", "_",
                                   os.path.basename(target)) or "file"
                ext = os.path.splitext(target)[1].lower()
                if inline and ext in INLINE_MIME:
                    ctype, disp = INLINE_MIME[ext], "inline"
                else:
                    ctype, disp = "application/octet-stream", "attachment"
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(st.st_size))
                self.send_header("Content-Disposition",
                                 f'{disp}; filename="{safe_name}"')
                self.send_header("Cache-Control", "private, no-store")
                self.end_headers()
                with open(target, "rb") as f:
                    shutil.copyfileobj(f, self.wfile, CHUNK)
            except BrokenPipeError:
                self.close_connection = True
            except Exception as e:
                log(f"ERROR dl stream: {e}")
                self.close_connection = True
            return
        if u.path == "/signed-download":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            org = q.get("org_id", [""])[0]
            rel = q.get("path", [""])[0]
            if not ORG_ID_RE.match(org):
                return self._send(400, {"error": "bad_org_id"})
            target, parts = safe_join(org, rel)
            if target is None:
                return self._send(400, {"error": "bad_path"})
            if not os.path.isfile(target):
                return self._send(404, {"error": "not_found"})
            disp = q.get("disposition", ["attachment"])[0]
            if disp not in ("attachment", "inline"):
                return self._send(400, {"error": "bad_disposition"})
            ttl = int(CFG["DL_TTL"])
            tok = dl_sign(org, "/".join(parts), ttl, inline=(disp == "inline"))
            return self._send(200, {
                "url": f"{CFG['PUBLIC_DL_BASE']}/dl/{tok}",
                "expires_at": int(time.time()) + ttl})
        if u.path == "/healthz":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"ok": True})
        m = re.match(r"^/fs-journal/([^/]+)$", u.path)
        if m:
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            org = m.group(1)
            if not ORG_ID_RE.match(org):
                return self._send(400, {"error": "bad_org_id"})
            try:
                since = int(q.get("since", ["0"])[0])
            except ValueError:
                return self._send(400, {"error": "bad_since"})
            events, latest, oldest = journal_read(org, since)
            if events is None:
                return self._send(410, {"error": "gone",
                                        "oldest_seq": oldest,
                                        "latest_seq": latest})
            return self._send(200, {"events": events, "latest_seq": latest})
        m = re.match(r"^/fs-tree/([^/]+)$", u.path)
        if m:
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            org = m.group(1)
            if not ORG_ID_RE.match(org):
                return self._send(400, {"error": "bad_org_id"})
            project = q.get("project", [""])[0]
            if project and not valid_component(project):
                return self._send(400, {"error": "bad_project"})
            try:
                code, resp = op_fs_tree(org, project,
                                        q.get("hash", ["0"])[0] == "1")
                return self._send(code, resp)
            except Exception as e:
                log(f"ERROR fs-tree: {e}")
                return self._send(500, {"error": "internal"})
        self._send(404, {"error": "not_found"})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        try:
            if u.path == "/project-skeleton":
                b = self._json_body()
                org = b.get("org_id", "")
                if not ORG_ID_RE.match(org):
                    return self._send(400, {"error": "bad_org_id"})
                with LOCK:
                    code, resp = op_skeleton(org, b.get("project_id", ""),
                                             b.get("request_id"))
                return self._send(code, resp)
            if u.path == "/files":
                org = q.get("org_id", [""])[0]
                rel = q.get("path", [""])[0]
                if not ORG_ID_RE.match(org):
                    return self._send(400, {"error": "bad_org_id"})
                rid = self.headers.get("X-Request-Id")
                with LOCK:
                    code, resp = op_upload(self, org, rel, rid)
                return self._send(code, resp)
            if u.path == "/cde/promote":
                b = self._json_body()
                org = b.get("org_id", "")
                if not ORG_ID_RE.match(org):
                    return self._send(400, {"error": "bad_org_id"})
                with LOCK:
                    code, resp = op_promote(org, b)
                return self._send(code, resp)
            if u.path == "/cde/lock":
                b = self._json_body()
                org = b.get("org_id", "")
                if not ORG_ID_RE.match(org):
                    return self._send(400, {"error": "bad_org_id"})
                with LOCK:
                    code, resp = op_lock(org, b)
                return self._send(code, resp)
            return self._send(404, {"error": "not_found"})
        except json.JSONDecodeError:
            return self._send(400, {"error": "bad_json"})
        except ValueError as e:
            return self._send(400, {"error": str(e)[:80]})
        except Exception as e:
            log(f"ERROR POST {u.path}: {e}")
            return self._send(500, {"error": "internal",
                                    "detail": str(e)[:200]})


# ── Samba full_audit → journal (source:"smb", actor z prefixu) ─────
# journald tag smbd_audit, -o cat: "u_xxx|10.67.0.4|mkdirat|ok|/srv/…"
# Wymaga w smb.conf: full_audit:success = mkdirat renameat unlinkat
# pwrite write (mutacje; bez open/close/read = bez spamu).
AUDIT_LINE_RE = re.compile(
    r"^(?P<user>u_[a-z0-9]+)\|(?P<ip>[0-9a-fA-F.:]+)\|"
    r"(?P<op>[a-z_]+)\|ok\|(?P<rest>.*)$")
MODIFY_COALESCE = 30  # s — max 1 event modify per plik w oknie
_last_modify = {}


def audit_rel(abs_path):
    """'/srv/orgs/<org>/<proj>/<Cont>/…' → (org_id, '<proj>/<Cont>/…')."""
    if not abs_path.startswith(ORG_BASE + "/"):
        return None
    parts = [x for x in abs_path[len(ORG_BASE) + 1:].split("/")
             if x and x != "."]
    if len(parts) < 3 or not ORG_ID_RE.match(parts[0]) \
            or parts[2] not in CONTAINERS:
        return None
    return parts[0], "/".join(parts[1:])


def audit_emit(org, ev):
    with LOCK:
        journal_append(org, ev)


def audit_handle(line):
    m = AUDIT_LINE_RE.match(line.strip())
    if not m:
        return
    user, op, rest = m.group("user"), m.group("op"), m.group("rest")
    fields = rest.split("|")
    if op == "mkdirat":
        v = audit_rel(fields[0])
        if v:
            audit_emit(v[0], {"op": "mkdir", "path": v[1], "kind": "dir",
                              "actor": user, "source": "smb"})
    elif op == "unlinkat":
        v = audit_rel(fields[0])
        if v:
            audit_emit(v[0], {"op": "unlink", "path": v[1], "kind": "file",
                              "actor": user, "source": "smb"})
    elif op == "renameat" and len(fields) >= 2:
        vs, vd = audit_rel(fields[0]), audit_rel(fields[1])
        if vs and vd and vs[0] == vd[0]:
            audit_emit(vs[0], {"op": "move", "path": vs[1],
                               "path_to": vd[1], "kind": "file",
                               "actor": user, "source": "smb"})
    elif op in ("pwrite", "write"):
        v = audit_rel(fields[0])
        if not v:
            return
        key = (v[0], v[1])
        now = time.time()
        if now - _last_modify.get(key, 0) < MODIFY_COALESCE:
            return
        _last_modify[key] = now
        abs_p = os.path.join(ORG_BASE, v[0], *v[1].split("/"))
        try:
            st = os.stat(abs_p)
            size, mtime = st.st_size, int(st.st_mtime)
        except OSError:
            size, mtime = None, None
        audit_emit(v[0], {"op": "modify", "path": v[1], "kind": "file",
                          "size": size, "mtime": mtime,
                          "actor": user, "source": "smb"})


def audit_thread():
    import subprocess
    cursor = os.path.join(STATE, "audit.cursor")
    while True:
        try:
            proc = subprocess.Popen(
                ["journalctl", "-t", "smbd_audit", "-f", "-o", "cat",
                 "--cursor-file", cursor],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            log("audit: tailing journald (smbd_audit)")
            for line in proc.stdout:
                try:
                    audit_handle(line)
                except Exception as e:
                    log(f"WARN audit line: {e}")
        except Exception as e:
            log(f"WARN audit thread: {e}")
        time.sleep(3)  # respawn po padzie journalctl


def main():
    global CFG
    CFG = load_cfg()
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    if CFG.get("AUDIT", "1") != "0":
        threading.Thread(target=audit_thread, daemon=True).start()
    addr = (CFG["BIND"], int(CFG["PORT"]))
    log(f"barvea-datad start {addr[0]}:{addr[1]}")
    ThreadingHTTPServer(addr, Handler).serve_forever()


if __name__ == "__main__":
    main()
