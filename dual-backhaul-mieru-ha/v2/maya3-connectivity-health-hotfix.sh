#!/usr/bin/env bash
# Maya3 only. Installs connectivity-only health controller and accurate sudo dual.
# Xray, HAProxy, two Backhaul transports and all foreign hosts are untouched.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 && $# == 1 && "$1" =~ ^[a-f0-9]{40}$ ]] || {
  echo "Usage: sudo bash maya3-connectivity-health-hotfix.sh PINNED_COMMIT";exit 2;
}
REF="$1"
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
CTR=/opt/dual-ha/controller.py
HELP=/opt/dual-ha/helper/dual_backhaul_menu.py
SERVICE=dual-ha-v2-health.service
[[ "$(readlink -f /usr/local/bin/dual)" == "$HELP" &&
   -f "$CTR" && ! -L "$CTR" && -f "$HELP" && ! -L "$HELP" ]] || {
  echo "STOP: unexpected existing Maya3 controller or helper";exit 3;
}
exec 9>/run/maya3-health-hotfix.lock
flock -n 9 || { echo "STOP: another install already running";exit 3; }
if systemctl is-active --quiet "$SERVICE" || systemctl is-enabled --quiet "$SERVICE";then
  echo "STOP: flawed controller still running or enabled."
  echo "FIRST: sudo systemctl disable --now dual-ha-v2-health";exit 3;
fi
for unit in x-ui dual-ha-v2-gateway dual-ha-backhaul \
            dual-ha-bh2-server dual-ha-bh2-router dual-ha-bh2-tls;do
  systemctl is-active --quiet "$unit" || { echo "STOP: inactive $unit";exit 3; }
done
python3 - <<'PY'
import json,re
from pathlib import Path
b=Path("/etc/dual-ha/backhaul-bundle.env").read_text()
assert re.search(r"(?m)^BH_IRAN_IP='185\.215\.230\.221'$",b)
assert re.search(r"(?m)^BH_FOREIGN_IP='152\.237\.230\.140'$",b)
m=json.loads(Path("/etc/dual-ha/bh2-experiment/state.json").read_text())
assert m.get("mode")=="active"
assert m.get("foreign_ip")=="82.152.132.112"
assert m.get("primary_ip")=="152.237.230.140"
print("MAYA3_IDENTITY_PASS")
PY
for item in "21001 152.237.230.140" "21002 82.152.132.112";do
  read -r port ip <<<"$item"
  observed="$(curl -q -4 --noproxy "" \
    --socks5-hostname "127.0.0.1:$port" \
    --connect-timeout 5 --max-time 16 -fsS \
    https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p')"
  [[ "$observed" == "$ip" ]] || { echo "STOP: SOCKS $port IP mismatch";exit 3; }
  echo "EGRESS_$port=$observed"
done
unitcmd="$(systemctl show -p ExecStart --value "$SERVICE")"
[[ "$unitcmd" == *"$CTR"* ]] || { echo "STOP: different controller ExecStart";exit 3; }
TMP="$(mktemp -d /root/.maya3-safe-controller.XXXXXXXX)"
BACKUP=""
CHANGED=0
on_exit(){
  local code=$?
  trap - EXIT
  if ((code != 0 && CHANGED == 1));then
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    install -o root -g root -m 0600 "$BACKUP/controller.old" "$CTR"
    install -o root -g root -m 0700 "$BACKUP/menu.old" "$HELP"
    echo "RESTORED_OLD_FILES_WITH_CONTROLLER_DISABLED=TRUE"
    echo "BACKUP=$BACKUP"
  fi
  rm -rf "$TMP"
  exit "$code"
}
trap on_exit EXIT
for name in dual-backhaul-controller.py dual_backhaul_menu.py;do
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 \
    "$BASE/$name" -o "$TMP/$name"
done
python3 -m py_compile "$TMP/dual-backhaul-controller.py" "$TMP/dual_backhaul_menu.py"
grep -Fq '"policy": "two-backhaul-connectivity-v2"' "$TMP/dual-backhaul-controller.py"
grep -Fq 'peer_enabled and peer_short_ok' "$TMP/dual-backhaul-controller.py"
grep -Fq 'Low bulk throughput is an independent' "$TMP/dual_backhaul_menu.py"
python3 - "$TMP/dual-backhaul-controller.py" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location("candidate",sys.argv[1])
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
assert c.PATHS=={"backhaul":21001,"mieru":21002}
assert c.SHORT_FALL==4 and c.RISE==3
for role,ip in (("backhaul","152.237.230.140"),("mieru","82.152.132.112")):
    assert c.expected_ip(role)==ip
    passed,ok,_=c.short_probe(c.PATHS[role],ip)
    print("HTTPS_CANARY",role,passed,"/3","OK",ok,flush=True)
    assert ok,"Maya3 path HTTPS unhealthy: "+role
assert c.decision(True,True,0,100,0,True,peer_enabled=True,peer_short_ok=True) is None
assert c.decision(True,False,4,0,0,True,peer_enabled=False,peer_short_ok=False) is None
assert c.decision(False,True,0,4,3,False)=="enable"
print("SAFE_CONTROLLER_OFFLINE_AND_LIVE_PREFLIGHT_PASS")
PY
BACKUP="/root/dual-backhaul-backups/maya3-health-v2-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p -m 0700 "$BACKUP"
cp -a "$CTR" "$BACKUP/controller.old"
cp -a "$HELP" "$BACKUP/menu.old"
echo "BACKUP=$BACKUP"
install -o root -g root -m 0600 "$TMP/dual-backhaul-controller.py" "$CTR.maya3-new"
install -o root -g root -m 0700 "$TMP/dual_backhaul_menu.py" "$HELP.maya3-new"
CHANGED=1
mv -Tf "$CTR.maya3-new" "$CTR"
mv -Tf "$HELP.maya3-new" "$HELP"
systemctl enable --now "$SERVICE"
python3 - <<'PY'
import datetime,json,subprocess,time
from pathlib import Path
p=Path("/run/dual-ha-v2/health.json")
deadline=time.monotonic()+90
while time.monotonic()<deadline:
    try:
        d=json.loads(p.read_text())
        age=(datetime.datetime.now(datetime.timezone.utc)-
             datetime.datetime.fromisoformat(d["updated_utc"])).total_seconds()
        if d.get("policy")=="two-backhaul-connectivity-v2" and 0<=age<=30:
            paths=d["paths"]
            if all(paths[k].get("expected_foreign_ip")==ip and paths[k].get("passed_probes",0)>=2
                   for k,ip in (("backhaul","152.237.230.140"),
                                ("mieru","82.152.132.112"))):
                print("MAYA3_NEW_HEALTH_CONTROLLER_VALIDATED")
                break
    except (OSError,ValueError,KeyError,TypeError):
        pass
    time.sleep(3)
else:
    raise RuntimeError("no fresh 2-lane connectivity-v2 health report")
assert subprocess.run(["systemctl","is-active","--quiet","dual-ha-v2-health"]).returncode==0
PY
NO_COLOR=1 /usr/local/bin/dual status
CHANGED=0
trap - EXIT
rm -rf "$TMP"
echo "MAYA3_CONNECTIVITY_HEALTH_V2_INSTALLED"
echo "HAProxy_Xray_Backhaul_RESTARTED=NO"
echo "SPEED_ONLY_HAPROXY_DRAIN_DISABLED=TRUE"
echo "BACKUP=$BACKUP"
