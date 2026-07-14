#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════
# BARVEA — gen-license.py: generuje podpisaną licencję dedyk.
# Uruchamiać na LXC 200 (vault) — podpis przez Vault transit
# `license-ed25519` (klucz NIGDY nie opuszcza Vaulta, pełny audit).
#
# Format (kontrakt z APP 2026-07-14):
#   BARVEA-LICENSE.v1.<b64url(canonical-JSON)>.<b64url(raw-64B-ed25519-sig)>
#   Podpis liczony po BAJTACH ASCII segmentu b64url(payload) (styl JWS).
#   Weryfikator (APP) NIE re-kanonizuje — canonical tylko tu, przy gen.
#
# Env: VAULT_ADDR (https://10.10.0.50:8200), VAULT_TOKEN. Self-signed → -k.
# Przykład (token testowy TRIAL na 2 dni):
#   python3 gen-license.py --org "Test Klient" --type TRIAL --days 2 \
#       --grace-days 1 --modules cde,cmms --max-users 5 --max-projects 2
# ═══════════════════════════════════════════════════════════════════
import argparse, base64, json, os, ssl, sys, urllib.request, uuid
from datetime import datetime, timedelta, timezone

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

def iso(dt) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

p = argparse.ArgumentParser()
p.add_argument("--org", required=True)
p.add_argument("--type", default="STANDARD", choices=["TRIAL", "STANDARD", "PERPETUAL"])
p.add_argument("--modules", default="cde,cmms", help="csv, np. cde,cmms,bim,drive")
p.add_argument("--max-users", type=int, default=-1)
p.add_argument("--max-projects", type=int, default=-1)
p.add_argument("--max-assets", type=int, default=-1)
p.add_argument("--max-storage-gb", type=int, default=-1)
p.add_argument("--days", type=int, help="expiry za N dni (pomiń przy PERPETUAL)")
p.add_argument("--grace-days", type=int, default=14)
p.add_argument("--updates-days", type=int, help="updatesUntil za N dni (default=expiry)")
a = p.parse_args()

now = datetime.now(timezone.utc)
if a.type != "PERPETUAL" and not a.days:
    sys.exit("FATAL: --days wymagane dla TRIAL/STANDARD")
expires = iso(now + timedelta(days=a.days)) if a.days else None
payload = {
    "schemaVersion": 1,
    "licenseId": str(uuid.uuid4()),
    "licenseType": a.type,
    "orgName": a.org,
    "modules": [m.strip() for m in a.modules.split(",") if m.strip()],
    "maxActiveUsers": a.max_users,
    "maxProjects": a.max_projects,
    "maxAssets": a.max_assets,
    "maxStorageBytes": a.max_storage_gb * 2**30 if a.max_storage_gb > 0 else -1,
    "issuedAt": iso(now),
    "notBefore": iso(now),
    "expiresAt": expires,
    "graceDays": a.grace_days,
    "updatesUntil": iso(now + timedelta(days=a.updates_days)) if a.updates_days else expires,
    "instanceBinding": None,
}
# canonical: sort_keys + zwarte separatory (deterministyczne; verify = surowe bajty)
seg = b64url(json.dumps(payload, sort_keys=True, separators=(",", ":"),
                        ensure_ascii=False).encode())

addr = os.environ.get("VAULT_ADDR", "https://10.10.0.50:8200")
tok = os.environ.get("VAULT_TOKEN") or sys.exit("FATAL: brak VAULT_TOKEN w env")
# TLS: PIN certu serwera (skrypt biegnie na LXC 200 — /opt/vault/tls/tls.crt
# to lokalny cert TEGO Vaulta; chain weryfikowany, MITM wymagałby klucza).
# check_hostname=False WYŁĄCZNIE bo prod-cert = self-signed BEZ SANs (znany
# gotcha, vault/README.md) — po ISSUE_VAULT_TLS przywrócić True.
cafile = os.environ.get("VAULT_CACERT", "/opt/vault/tls/tls.crt")
ctx = ssl.create_default_context(cafile=cafile)
ctx.check_hostname = False
req = urllib.request.Request(
    f"{addr}/v1/transit/sign/license-ed25519",
    data=json.dumps({"input": base64.b64encode(seg.encode()).decode()}).encode(),
    headers={"X-Vault-Token": tok, "Content-Type": "application/json"})
sig_vault = json.loads(urllib.request.urlopen(req, context=ctx).read()) \
    ["data"]["signature"]                        # vault:v1:<b64std(64B)>
raw = base64.b64decode(sig_vault.split(":", 2)[2])
assert len(raw) == 64, f"zly rozmiar podpisu: {len(raw)}"

token = f"BARVEA-LICENSE.v1.{seg}.{b64url(raw)}"
print(token)
print(f"\n# licenseId={payload['licenseId']} type={a.type} "
      f"expires={expires or 'NIGDY'} grace={a.grace_days}d "
      f"modules={','.join(payload['modules'])}", file=sys.stderr)
