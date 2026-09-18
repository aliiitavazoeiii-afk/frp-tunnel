#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=dual-trust-mieru
D=/etc/$PROJECT/iran

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# Refuse destructive cleanup if x-ui is still attached to the new entry.
if [[ -f /usr/local/x-ui/bin/config.json ]]; then
  if python3 - <<'PY'
import json,sys
try: cfg=json.load(open('/usr/local/x-ui/bin/config.json'))
except Exception: sys.exit(1)
for o in cfg.get('outbounds',[]):
    if o.get('tag')!='dual-tunnel': continue
    for s in (o.get('settings',{}).get('servers') or []):
        if s.get('address')=='127.0.0.1' and int(s.get('port',0))==7990: sys.exit(0)
sys.exit(1)
PY
  then
    echo "ERROR: x-ui still points to dual-tunnel 127.0.0.1:7990. Run sudo dual-tunnel-xui-rollback first." >&2
    exit 1
  fi
fi

for s in dual-dispatcher dual-xudp-bridge dual-mieru-carrier dual-trust-client; do
  systemctl disable --now "$s.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$s.service"
done
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

rm -rf "$D"
rm -f /usr/local/sbin/dual-tunnel-probe /usr/local/sbin/dual-tunnel-status /usr/local/sbin/dual-tunnel-failover-test /usr/local/sbin/dual-tunnel-replace-foreign

echo "SUCCESS: Iran dual Trust/Mieru services/config removed."
echo "Pinned shared binaries and x-ui backups were intentionally retained."
