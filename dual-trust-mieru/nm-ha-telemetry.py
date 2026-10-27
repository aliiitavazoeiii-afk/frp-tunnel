#!/usr/bin/env python3
"""One-way HTTPS telemetry push for Hesab VPN Control Room. Never controls carriers.
Secret stays only in /etc/dual-trust-mieru/ha-telemetry.json (0600).
"""
import hashlib, hmac, json, pathlib, sys, time, urllib.parse, urllib.request

STATUS=pathlib.Path("/var/lib/dual-trust-mieru/naive-mieru/ha/status.json")
CONFIG=pathlib.Path("/etc/dual-trust-mieru/ha-telemetry.json")
def main():
    if not CONFIG.is_file():
        print("TELEMETRY NOT CONFIGURED; local HA unaffected")
        return
    cfg=json.loads(CONFIG.read_text())
    url=str(cfg["endpoint"])
    p=urllib.parse.urlsplit(url)
    if p.scheme!="https" or not p.hostname or p.username or p.password or p.fragment:
        raise ValueError("telemetry endpoint must be plain HTTPS URL, no embedded credentials")
    key=str(cfg["secret"])
    sid=str(cfg["server_id"])
    if len(key)<32 or not sid or len(sid)>96 or not STATUS.is_file():
        raise ValueError("telemetry secret must be >=32 chars; server_id nonempty and status available")
    payload=json.loads(STATUS.read_text())
    if payload.get("schema")!=1 or not isinstance(payload.get("roles"),dict):
        raise ValueError("invalid schema")
    # Server ID in signed JSON must agree with provisioned identity.
    payload["server_id"]=sid
    body=json.dumps(payload,separators=(",",":"),sort_keys=True).encode()
    timestamp=str(int(time.time()))
    digest=hmac.new(key.encode(),timestamp.encode()+b"."+body,hashlib.sha256).hexdigest()
    req=urllib.request.Request(url, data=body, method="POST",headers={
        "Content-Type":"application/json",
        "X-NM-Server-ID":sid,"X-NM-Timestamp":timestamp,
        "X-NM-Signature":"sha256="+digest,
        "User-Agent":"Naive-Mieru-Telemetry/1"})
    with urllib.request.urlopen(req,timeout=6) as r:
        if not 200<=r.status<300:
            raise RuntimeError("telemetry refused")
    print("Telemetry accepted for",sid,"sequence",payload.get("last_event_seq"))
if __name__=="__main__":
    try:main()
    except Exception as e:
        print("TELEMETRY ERROR:",type(e).__name__,str(e)[:180],file=sys.stderr)
        sys.exit(1)
