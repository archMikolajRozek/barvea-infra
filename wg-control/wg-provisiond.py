#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# BARVEA — wg-provisiond: WG peer control-plane (odbiornik push z APP).
# Uruchamiać na barvea-infra (10.10.0.10) jako root (systemd service).
#
# API (Bearer token, LAN-only bind):
#   POST   /wg/peer            {pubkey, preshared_key, allowed_ip}
#                              → idempotentny upsert peera (200 {applied:true})
#   DELETE /wg/peer/<pubkey-urlenc>  → usuń peera (200 / 404)
#   GET    /healthz            → 200 {ok:true, managed:N, total:N}
#
# Twarde reguły:
#   - TYLKO interfejs wg-users (nigdy wg0 admin)
#   - allowed_ip MUSI być pojedynczy /32 w 10.67.0.0/16
#   - pubkey/psk = valid base64, 44 znaki, kończy '='
#   - peery zarządzane oznaczane '# managed: wg-provisiond' — sekcja
#     [Interface] i peery manualne przepisywane VERBATIM
#   - atomic write (tmp+rename) + backup przed każdą zmianą
#   - po zmianie: wg syncconf (hot, bez zrywania innych peerów) + verify
#
# Config: /etc/barvea/wg-provisiond.env
#   TOKEN=<64-hex>            (wymagany, >=24 znaki)
#   BIND=10.10.0.10  PORT=8721  WG_IFACE=wg-users
#   WG_CONF=/etc/wireguard/wg-users.conf
# ═══════════════════════════════════════════════════════════════
import base64, hmac, json, os, re, shutil, subprocess, sys, threading, time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = "/etc/barvea/wg-provisiond.env"
MANAGED_MARK = "# managed: wg-provisiond"
LOCK = threading.Lock()
CFG = {}


def log(msg):
    print(msg, flush=True)


def load_cfg():
    cfg = {"BIND": "10.10.0.10", "PORT": "8721", "WG_IFACE": "wg-users",
           "WG_CONF": "/etc/wireguard/wg-users.conf"}
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"')
    if len(cfg.get("TOKEN", "")) < 24:
        log("FATAL: TOKEN brak/za krótki w " + CONF)
        sys.exit(1)
    if cfg["WG_IFACE"] != "wg-users":
        log("FATAL: WG_IFACE != wg-users — odmowa (admin tunel nietykalny)")
        sys.exit(1)
    return cfg


# ── walidacje ──────────────────────────────────────────────────
def valid_wg_key(s):
    if not isinstance(s, str) or len(s) != 44 or not s.endswith("="):
        return False
    try:
        return len(base64.b64decode(s, validate=True)) == 32
    except Exception:
        return False


ALLOWED_IP_RE = re.compile(r"^10\.67\.(\d{1,3})\.(\d{1,3})/32$")


def valid_allowed_ip(s):
    m = ALLOWED_IP_RE.match(s or "")
    if not m:
        return False
    a, b = int(m.group(1)), int(m.group(2))
    return 0 <= a <= 255 and 0 <= b <= 255 and s != "10.67.0.1/32"  # gw


# ── conf parsing: [prefix, peers[]] — peer = {comment_lines, kv, managed} ──
def parse_conf(path):
    with open(path) as f:
        lines = f.read().splitlines()
    prefix, peers, i = [], [], 0
    # prefix = wszystko do pierwszego [Peer] (Interface + jego komentarze)
    first_peer = next((n for n, l in enumerate(lines)
                       if l.strip() == "[Peer]"), len(lines))
    # komentarze bezpośrednio nad pierwszym [Peer] należą do peera
    cstart = first_peer
    while cstart > 0 and (lines[cstart - 1].strip().startswith("#")
                          or lines[cstart - 1].strip() == ""):
        cstart -= 1
    prefix = lines[:cstart]
    i = cstart
    cur = None
    pending_comments = []
    while i < len(lines):
        s = lines[i].strip()
        if s == "[Peer]":
            cur = {"comments": pending_comments, "kv": {}, "order": []}
            pending_comments = []
            peers.append(cur)
        elif s.startswith("#") or s == "":
            if cur is None or s == "":
                pending_comments.append(lines[i])
            else:
                # komentarz wewnątrz bloku — jak następna linia to [Peer],
                # to nagłówek następnego; inaczej trzymaj w bieżącym
                nxt = next((l.strip() for l in lines[i + 1:] if l.strip()), "")
                if nxt == "[Peer]" or s == "":
                    pending_comments.append(lines[i])
                else:
                    cur["order"].append(("raw", lines[i]))
        elif "=" in s and cur is not None:
            k, v = s.split("=", 1)
            cur["kv"][k.strip()] = v.strip()
            cur["order"].append(("kv", k.strip()))
        else:
            (pending_comments if cur is None else cur.setdefault(
                "order", [])).append(("raw", lines[i]) if cur else lines[i])
        i += 1
    for p in peers:
        p["managed"] = any(MANAGED_MARK in c for c in p["comments"])
    return prefix, peers, pending_comments


def render_conf(prefix, peers, tail):
    out = list(prefix)
    for p in peers:
        if out and out[-1].strip() != "":
            out.append("")
        out.extend(c for c in p["comments"] if c.strip() != "")
        out.append("[Peer]")
        seen = set()
        for typ, val in p["order"]:
            if typ == "kv" and val in p["kv"] and val not in seen:
                out.append(f"{val} = {p['kv'][val]}")
                seen.add(val)
            elif typ == "raw":
                out.append(val)
        for k in ("PublicKey", "PresharedKey", "AllowedIPs"):
            if k in p["kv"] and k not in seen:
                out.append(f"{k} = {p['kv'][k]}")
    out.extend(t for t in tail if isinstance(t, str) and t.strip() != "")
    return "\n".join(out).rstrip() + "\n"


def write_conf(path, content):
    shutil.copy2(path, path + ".bak-provisiond")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def syncconf(iface):
    r = subprocess.run(
        ["bash", "-c", f"wg syncconf {iface} <(wg-quick strip {iface})"],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"syncconf failed: {r.stderr.strip()[:300]}")


def peer_in_kernel(iface, pubkey):
    r = subprocess.run(["wg", "show", iface, "peers"],
                       capture_output=True, text=True)
    return pubkey in r.stdout.split()


# ── operacje ───────────────────────────────────────────────────
def upsert_peer(pubkey, psk, allowed_ip):
    path, iface = CFG["WG_CONF"], CFG["WG_IFACE"]
    prefix, peers, tail = parse_conf(path)
    # kolizja IP z INNYM peerem → konflikt
    for p in peers:
        if p["kv"].get("AllowedIPs") == allowed_ip \
                and p["kv"].get("PublicKey") != pubkey:
            return 409, {"error": "ip_conflict",
                         "detail": f"{allowed_ip} zajęty przez innego peera"}
    target = next((p for p in peers if p["kv"].get("PublicKey") == pubkey), None)
    if target is None:
        target = {"comments": [MANAGED_MARK], "kv": {}, "managed": True,
                  "order": [("kv", "PublicKey"), ("kv", "PresharedKey"),
                            ("kv", "AllowedIPs")]}
        peers.append(target)
        action = "added"
    else:
        if not target["managed"]:
            target["comments"] = target["comments"] + [MANAGED_MARK]
            target["managed"] = True
        action = "updated"
    target["kv"]["PublicKey"] = pubkey
    target["kv"]["PresharedKey"] = psk
    target["kv"]["AllowedIPs"] = allowed_ip
    write_conf(path, render_conf(prefix, peers, tail))
    syncconf(iface)
    if not peer_in_kernel(iface, pubkey):
        raise RuntimeError("peer nie widoczny w kernelu po syncconf")
    log(f"upsert {action}: {pubkey[:12]}… -> {allowed_ip}")
    return 200, {"applied": True, "action": action}


def delete_peer(pubkey):
    path, iface = CFG["WG_CONF"], CFG["WG_IFACE"]
    prefix, peers, tail = parse_conf(path)
    keep = [p for p in peers if p["kv"].get("PublicKey") != pubkey]
    if len(keep) == len(peers):
        return 404, {"error": "peer_not_found"}
    write_conf(path, render_conf(prefix, keep, tail))
    syncconf(iface)
    if peer_in_kernel(iface, pubkey):
        raise RuntimeError("peer dalej w kernelu po delete+syncconf")
    log(f"delete: {pubkey[:12]}…")
    return 200, {"applied": True, "action": "deleted"}


def stats():
    _, peers, _ = parse_conf(CFG["WG_CONF"])
    return {"ok": True, "total": len(peers),
            "managed": sum(1 for p in peers if p["managed"])}


# ── HTTP ───────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    server_version = "wg-provisiond"
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

    def log_message(self, fmt, *args):  # ciszej: własne logi wyżej
        pass

    def do_GET(self):
        if self.path == "/healthz":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            try:
                return self._send(200, stats())
            except Exception as e:
                return self._send(500, {"error": str(e)[:200]})
        self._send(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/wg/peer":
            return self._send(404, {"error": "not_found"})
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            if n > 4096:
                return self._send(413, {"error": "too_large"})
            body = json.loads(self.rfile.read(n))
            pubkey = body.get("pubkey", "")
            psk = body.get("preshared_key", "")
            aip = body.get("allowed_ip", "")
            if not valid_wg_key(pubkey):
                return self._send(400, {"error": "bad_pubkey"})
            if not valid_wg_key(psk):
                return self._send(400, {"error": "bad_preshared_key"})
            if not valid_allowed_ip(aip):
                return self._send(400, {"error": "bad_allowed_ip",
                                        "detail": "wymagany /32 w 10.67.0.0/16"})
            with LOCK:
                code, resp = upsert_peer(pubkey, psk, aip)
            return self._send(code, resp)
        except json.JSONDecodeError:
            return self._send(400, {"error": "bad_json"})
        except Exception as e:
            log(f"ERROR POST: {e}")
            return self._send(500, {"error": "internal", "detail": str(e)[:200]})

    def do_DELETE(self):
        if not self.path.startswith("/wg/peer/"):
            return self._send(404, {"error": "not_found"})
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        pubkey = urllib.parse.unquote(self.path[len("/wg/peer/"):])
        if not valid_wg_key(pubkey):
            return self._send(400, {"error": "bad_pubkey"})
        try:
            with LOCK:
                code, resp = delete_peer(pubkey)
            return self._send(code, resp)
        except Exception as e:
            log(f"ERROR DELETE: {e}")
            return self._send(500, {"error": "internal", "detail": str(e)[:200]})


def main():
    global CFG
    CFG = load_cfg()
    addr = (CFG["BIND"], int(CFG["PORT"]))
    log(f"wg-provisiond start {addr[0]}:{addr[1]} iface={CFG['WG_IFACE']}")
    stats()  # fail-fast: conf parsowalny przy starcie
    ThreadingHTTPServer(addr, Handler).serve_forever()


if __name__ == "__main__":
    main()
