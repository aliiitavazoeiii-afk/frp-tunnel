#!/usr/bin/env bash
# Read-only, redacted inventory of the live Xray/X-UI configuration.
# Never outputs client UUID, Reality private keys, DNS names, or passwords.
set -Eeuo pipefail
echo "=== TCP :443 owner ==="
ss -Hlnpt '( sport = :443 )' | sed -E 's/pid=[0-9]+/pid=REDACTED/g'
echo "=== Active X-UI ==="
systemctl is-active x-ui || true
echo "=== Xray runtime metadata (safe) ==="
python3 - <<'PY'
import glob,json,os
paths=[
"/usr/local/x-ui/bin/config.json",
"/usr/local/x-ui/bin/xray-config.json",
"/etc/xray/config.json",
"/usr/local/etc/xray/config.json",
]
found=False
for path in paths:
    if not os.path.isfile(path):
        continue
    try:
        with open(path) as f:
            cfg=json.load(f)
    except (OSError,ValueError) as e:
        print("Config exists but cannot parse:",path,type(e).__name__)
        continue
    found=True
    print("config_file:",path)
    for inbound in cfg.get("inbounds",[]):
        settings=inbound.get("streamSettings") or {}
        print("inbound:", {"port":inbound.get("port"),
                          "protocol":inbound.get("protocol"),
                          "security":settings.get("security"),
                          "tag":inbound.get("tag")})
    for outbound in cfg.get("outbounds",[]):
        print("outbound:", {"protocol":outbound.get("protocol"),
                           "tag":outbound.get("tag")})
    routing=cfg.get("routing") or {}
    print("routing_rules_count:",len(routing.get("rules") or []))
if not found:
    print("No readable known Xray JSON path found. No database accessed.")
PY
echo "Audit complete. No change made."
