#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
if [[ -f /usr/local/x-ui/bin/config.json ]] && python3 - <<'PY'
import json,sys
try: c=json.load(open('/usr/local/x-ui/bin/config.json'))
except Exception: sys.exit(1)
for o in c.get('outbounds',[]):
    if o.get('tag')!='dual-tunnel': continue
    sv=(o.get('settings') or {}).get('servers') or []
    if sv and sv[0].get('address')=='127.0.0.1' and int(sv[0].get('port',0))==7990: sys.exit(0)
sys.exit(1)
PY
then
  echo 'ERROR: x-ui still routes to dual-tunnel:7990. Run sudo dual-tunnel-xui-rollback first, then uninstall.' >&2
  exit 1
fi
for s in dual-dispatcher dual-xudp-bridge dual-mieru-client dual-trust-client; do
  systemctl disable --now "$s.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$s.service"
done
systemctl daemon-reload
rm -rf /etc/dual-trust-mieru/iran
systemctl disable --now mieru.service >/dev/null 2>&1 || true
dpkg -r mieru >/dev/null 2>&1 || true
rm -f /usr/local/sbin/dual-tunnel-probe /usr/local/sbin/dual-tunnel-status /usr/local/sbin/dual-tunnel-failover-test /usr/local/sbin/dual-tunnel-xui-rollback
# Intentionally keep downloaded binaries/packages and all x-ui backups.
echo 'Iran dual services removed. x-ui was NOT modified or rolled back automatically.'
