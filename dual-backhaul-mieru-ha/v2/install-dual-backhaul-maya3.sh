#!/usr/bin/env bash
# Maya3-only, fail-closed Dual Backhaul helper + bulk-aware controller installer.
# Does NOT restart or rewrite Xray, REALITY, original Backhaul, or HAProxy.
# Usage: sudo bash install-dual-backhaul-maya3.sh EXACT_40_HEX_COMMIT
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo "Root required" >&2; exit 2; }
[[ $# == 1 && "$1" =~ ^[a-f0-9]{40}$ ]] || {
 echo "Usage: sudo bash $0 40_CHARACTER_GITHUB_COMMIT_SHA" >&2; exit 2;
}
REF="$1"
HERE=/opt/dual-ha/helper
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
[[ -r /etc/dual-ha/bh2-experiment/state.json &&
   -r /etc/dual-ha/backhaul-bundle.env &&
   -f "$HERE/dual.py" &&
   -f "$HERE/dual_swap_v3.py" &&
   -f "$HERE/dual_auto.py" ]] || {
 echo "STOP: Maya3 dual installation not found"; exit 3;
}
python3 - <<'PY'
import json
m=json.load(open('/etc/dual-ha/bh2-experiment/state.json'))
assert m.get('mode')=='active' and m.get('primary_ip')=='152.237.230.140', "Unexpected Maya3 Backhaul2 state"
assert m.get('foreign_ip')=='82.152.132.112', "Existing Backhaul2 differs from expected: inspect before install"
bundle={}
for line in open('/etc/dual-ha/backhaul-bundle.env'):
    if line.startswith("BH_IRAN_IP="):
        assert line.strip()=="BH_IRAN_IP='185.215.230.221'", "Not Maya3"
PY
for s in dual-ha-backhaul dual-ha-bh2-server dual-ha-bh2-router dual-ha-bh2-tls dual-ha-v2-gateway dual-ha-v2-health; do
  systemctl is-active --quiet "$s" || { echo "STOP: $s is not active"; exit 3; }
done
# Allow real installation only once the two independent SOCKS data planes work.
for PORT in 21001 21002; do
  curl -q -4 --noproxy "" --socks5-hostname 127.0.0.1:$PORT \
    --connect-timeout 5 --max-time 15 -fsS \
    https://www.cloudflare.com/cdn-cgi/trace |
    grep -q '^ip=' || { echo "STOP: SOCKS $PORT unavailable";exit 3; }
done
[[ "$(readlink -f /usr/local/bin/dual)" == "$HERE/dual.py" ||
    "$(readlink -f /usr/local/bin/dual)" == "$HERE/dual_backhaul_menu.py" ]] || {
 echo "STOP: unknown /usr/local/bin/dual ownership"; exit 3;
}
T="$(mktemp -d /root/.dual-backhaul-install.XXXXXXXX)"
B="/root/dual-backhaul-backups/install-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p -m 0700 "$B"
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT
for f in dual-backhaul-controller.py dual-backhaul2-rotate.py dual_backhaul_menu.py dual_auto.py; do
  curl -fsSL --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 90 "$BASE/$f" -o "$T/$f"
done
python3 -m py_compile "$T/"*.py
# Keep original V3 Python module and all current tunnel configs in place.
cp -a "$HERE/dual_auto.py" "$B/dual_auto.py"
if [[ -e "$HERE/dual_backhaul_menu.py" ]]; then cp -a "$HERE/dual_backhaul_menu.py" "$B/dual_backhaul_menu.py"; fi
if [[ -e "$HERE/dual-backhaul2-rotate.py" ]]; then cp -a "$HERE/dual-backhaul2-rotate.py" "$B/dual-backhaul2-rotate.py"; fi
cp -a /opt/dual-ha/controller.py "$B/controller.py"
readlink /usr/local/bin/dual > "$B/dual-symlink-before.txt"
cat > "$B/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || exit 2
cp -a "$B/dual_auto.py" /opt/dual-ha/helper/dual_auto.py
cp -a "$B/controller.py" /opt/dual-ha/controller.py
ln -sfn "\$(cat "$B/dual-symlink-before.txt")" /usr/local/bin/dual
systemctl restart dual-ha-v2-health
echo 'Previous helper and controller restored. Tunnel and HAProxy unchanged.'
EOF
chmod 0700 "$B/rollback.sh"
install -m 0600 "$T/dual_auto.py" "$HERE/dual_auto.py"
install -m 0700 "$T/dual-backhaul2-rotate.py" "$HERE/dual-backhaul2-rotate.py"
install -m 0700 "$T/dual_backhaul_menu.py" "$HERE/dual_backhaul_menu.py"
install -m 0600 "$T/dual-backhaul-controller.py" /opt/dual-ha/controller.py
python3 -m py_compile "$HERE/dual_backhaul_menu.py" "$HERE/dual-backhaul2-rotate.py" \
  "$HERE/dual_auto.py" /opt/dual-ha/controller.py
ln -sfn "$HERE/dual_backhaul_menu.py" /usr/local/bin/dual
if ! sudo dual status; then
  echo "FAILED: helper error; restoring prior files" >&2
  bash "$B/rollback.sh"
  exit 4
fi
# Only controller restart. NO HAProxy, Xray, Backhaul, Mieru or other services restart.
systemctl restart dual-ha-v2-health
# Require fresh output from the new controller, not merely systemd "active".
ready=0
for i in $(seq 1 12); do
  if systemctl is-active --quiet dual-ha-v2-health &&
    python3 - <<'PY'
import json,datetime
p="/run/dual-ha-v2/health.json"
data=json.load(open(p))
updated=datetime.datetime.fromisoformat(data["updated_utc"])
age=(datetime.datetime.now(datetime.timezone.utc)-updated).total_seconds()
assert data.get("policy")=="two-backhaul-bulk-v1", "Old controller still publishing"
assert set(data.get("paths",{}))=={"backhaul","mieru"}
assert -5 <= age <= 35
PY
  then ready=1; break; fi
  sleep 3
done
if [[ "$ready" != 1 ]]; then
  echo "Controller did not publish fresh bulk-aware state; restoring previous version." >&2
  bash "$B/rollback.sh"
  exit 4
fi
printf "%s\n" "$B" > /root/dual-backhaul-backups/installed-current
chmod 0600 /root/dual-backhaul-backups/installed-current
echo "INSTALLED DUAL BACKHAUL helper and BULK-aware FAILOVER controller"
echo "HAPROXY & leastconn untouched. Xray and both Backhaul instances untouched."
echo "ROLLBACK: sudo bash $B/rollback.sh"
echo "NEXT: sudo dual"
