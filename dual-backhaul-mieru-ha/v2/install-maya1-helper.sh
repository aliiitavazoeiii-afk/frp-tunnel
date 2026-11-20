#!/usr/bin/env bash
# Install Maya1 status/health/jitter menu ONLY after verified new-path cutover.
# Do not modify HAProxy, Xray, tunnel daemons or health controller.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 && $# == 1 && "$1" =~ ^[a-f0-9]{40}$ ]] || {
 echo "Usage: sudo bash install-maya1-helper.sh EXACT_COMMIT";exit 2;
}
REF="$1"
[[ -e /etc/dual-ha/maya1-next/cutover-state.json ]] || {
 echo "STOP: Maya1 dual Backhaul cutover not committed";exit 3;
}
python3 - <<'PY'
import json,datetime
from pathlib import Path
marker=json.loads(Path("/etc/dual-ha/maya1-next/cutover-state.json").read_text())
assert marker.get("phase")=="completed" and marker.get("iran")=="94.184.4.38"
j=json.loads(Path("/run/dual-ha-v2/health.json").read_text())
assert j.get("policy")=="two-backhaul-bulk-v1"
dt=datetime.datetime.fromisoformat(j["updated_utc"])
age=(datetime.datetime.now(datetime.timezone.utc)-dt).total_seconds()
assert 0<=age<=35,"Stale controller"
for role,ip in (("backhaul","82.152.132.159"),("mieru","152.237.230.77")):
 d=j["paths"][role]
 assert d["expected_foreign_ip"]==ip
 assert d["passed_probes"]>=2 and d["bulk_pass"] is True
print("MAYA1_HEALTH_CONTROLLER_VALIDATED")
PY
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
TARGET=/opt/dual-ha/helper/maya1_dual_backhaul_menu.py
OLD=$(readlink -f /usr/local/bin/dual || true)
[[ "$OLD" == /opt/dual-ha/helper/* && -s "$OLD" && ! -e "$TARGET" ]] || {
 echo "STOP: unexpected live sudo dual helper path or prior new installer";exit 3;
}
T="$(mktemp /root/.maya1-helper.XXXXXXXX.py)"
trap 'rm -f "$T"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 \
 "$BASE/maya1-dual-helper.py" -o "$T"
python3 -m py_compile "$T"
OUT="$(NO_COLOR=1 python3 "$T" status)"
grep -Fq "BACKHAUL1" <<<"$OUT"
grep -Fq "BACKHAUL2" <<<"$OUT"
grep -Fq "82.152.132.159" <<<"$OUT"
grep -Fq "152.237.230.77" <<<"$OUT"
[[ "$OUT" != *$'\033'* ]] || {
 echo "STOP: ANSI leaked into NO_COLOR telemetry";exit 3;
}
BK="/root/dual-backhaul-backups/maya1-helper-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p -m 0700 "$BK"
cp -a /usr/local/bin/dual "$BK/dual.previous"
cat >"$BK/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID == 0 ]] || exit 2
rm -f /usr/local/bin/dual
cp -a "$BK/dual.previous" /usr/local/bin/dual
echo "Maya1 previous sudo dual helper restored"
EOF
chmod 0700 "$BK/rollback.sh"
install -o root -g root -m 0700 "$T" "$TARGET"
ln -s "$TARGET" /usr/local/bin/dual.maya1.new
mv -Tf /usr/local/bin/dual.maya1.new /usr/local/bin/dual
if ! NO_COLOR=1 /usr/local/bin/dual status >/dev/null;then
 bash "$BK/rollback.sh"
 exit 4
fi
echo "MAYA1_COLOR_DUAL_HELPER_INSTALLED"
echo "NO_TRANSPORT_CONTROLLER_HAPROXY_XRAY_CHANGES=TRUE"
echo "ROLES=BACKHAUL1+BACKHAUL2"
echo "LEGACY_REPLACE_DISABLED_FOR_SAFETY=TRUE"
echo "ROLLBACK: sudo bash $BK/rollback.sh"
echo "NEXT: sudo dual"
