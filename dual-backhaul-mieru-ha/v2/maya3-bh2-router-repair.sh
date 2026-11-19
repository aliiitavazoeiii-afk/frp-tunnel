#!/usr/bin/env bash
# Maya3 second Backhaul ONLY: recover isolated HTTP router from a TCP bind conflict.
# NEVER changes live Backhaul1, original Mieru, Xray, production HAProxy/controller.
set -Eeuo pipefail
umask 077
[[ "$EUID" -eq 0 ]] || { echo "Run as root" >&2; exit 2; }
PRIMARY=/etc/dual-ha/backhaul-bundle.env
D=/etc/dual-ha/bh2-experiment
ROUTER="$D/router.cfg"
TLS="$D/tls.conf"
META="$D/state.json"
[[ -f "$PRIMARY" && -f "$ROUTER" && -f "$TLS" && -f "$META" ]] || {
  echo "STOP: Maya3 Backhaul2 stage not found"; exit 3;
}
grep -Fxq "BH_IRAN_IP='185.215.230.221'" "$PRIMARY" || {
  echo "STOP: this host is not Maya3"; exit 3;
}
python3 - "$META" <<'PY'
import json,sys
meta=json.load(open(sys.argv[1]))
assert meta["mode"]=="staged","Only staged Backhaul2 can be repaired"
assert meta["foreign_ip"]=="82.152.132.112","Wrong foreign VPS"
assert meta["domain"]=="bh3-new.biya2film.top","Unexpected domain"
PY
for name in dual-ha-backhaul dual-ha-backhaul-tls dual-ha-v2-gateway dual-ha-v2-health dual-ha-bh2-server; do
  systemctl is-active --quiet "$name" || { echo "STOP: required service inactive: $name"; exit 3; }
done
systemctl is-active --quiet dual-ha-mieru && {
  echo "STOP: Mieru is active on :21002. Leave routing unchanged."; exit 3;
}
echo "=== CURRENT EXPERIMENT ROUTER STATUS ==="
systemctl is-active dual-ha-bh2-router || true
echo "=== EXISTING BIND CONFLICT, ALL TCP STATES ==="
ss -Htan '( sport = :19084 )' || true
if ss -Hlnpt '( sport = :19084 )' | grep -q LISTEN; then
  echo "STOP: TCP/19084 currently has a listener; inspect owner before replacement."
  exit 3
fi

# Only two experimental services are stopped to prevent reconnect loops while repairing.
systemctl stop dual-ha-bh2-tls dual-ha-bh2-router
systemctl reset-failed dual-ha-bh2-router || true
NEW=''
for PORT in 19086 19184 29084 29085; do
  if [[ -z "$(ss -Htan "( sport = :$PORT )" 2>/dev/null)" ]]; then
    NEW="$PORT"; break
  fi
done
[[ -n "$NEW" ]] || { echo "STOP: no unused isolated HTTP router port"; exit 3; }
BACKUP="$D/repair-backup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$BACKUP"
cp -a "$ROUTER" "$TLS" "$BACKUP/"
echo "Isolated experimental router port: 19084 -> $NEW"
python3 - "$ROUTER" "$TLS" "$NEW" <<'PY'
from pathlib import Path
import os,sys
router,tls,port=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
old_r="bind 127.0.0.1:19084"
old_t="connect = 127.0.0.1:19084"
r=router.read_text()
t=tls.read_text()
if r.count(old_r)!=1 or t.count(old_t)!=1:
    raise SystemExit("Unexpected experimental config; refusing edit")
for path,content in [(router,r.replace(old_r,"bind 127.0.0.1:"+port)),
                     (tls,t.replace(old_t,"connect = 127.0.0.1:"+port))]:
    tmp=path.with_name(path.name+".repair-new")
    with tmp.open("x") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp,0o600)
    tmp.replace(path)
PY
if ! /usr/sbin/haproxy -c -f "$ROUTER"; then
  cp -a "$BACKUP/router.cfg" "$ROUTER"
  cp -a "$BACKUP/tls.conf" "$TLS"
  echo "ERROR: isolated HAProxy config invalid; files restored. Nothing in production touched."
  exit 4
fi
if ! systemctl start dual-ha-bh2-router; then
  journalctl -u dual-ha-bh2-router --no-pager -n 15
  echo "ERROR: experimental router still failed. Backup: $BACKUP"
  exit 4
fi
sleep 1
if ! systemctl is-active --quiet dual-ha-bh2-router ||
   ! ss -Hlnpt "( sport = :$NEW )" | grep -q LISTEN; then
  echo "ERROR: experimental router did not bind $NEW; inspect journal."
  journalctl -u dual-ha-bh2-router --no-pager -n 15
  exit 4
fi
systemctl start dual-ha-bh2-tls
systemctl is-active --quiet dual-ha-bh2-tls || {
  echo "ERROR: isolated TLS listener failed"; exit 4;
}
echo "ROUTER_REPAIRED: localhost:$NEW, TLS public :18445"
echo "Original Backhaul1, Mieru, Xray and HAProxy were not modified."
echo "Waiting briefly for foreign Backhaul2 reverse reconnect..."
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if ss -Hlnpt '( sport = :21102 )' | grep -q LISTEN; then
    echo "STAGING SOCKS :21102 READY"
    break
  fi
  sleep 2
done
ss -lntp '( sport = :21102 )' || true
echo "=== EXPERIMENT STATUS ==="
systemctl is-active dual-ha-bh2-router dual-ha-bh2-tls dual-ha-bh2-server
echo "=== NEXT: Test foreign egress and real downloads via SOCKS :21102 ==="
