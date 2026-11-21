#!/usr/bin/env bash
# Only controller + helper are replaced. NO HAProxy, Xray or tunnel restart.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 && $# == 2 && "$2" =~ ^[0-9a-f]{40}$ ]] || { echo "Usage: sudo bash install-maya-three-site-health-v3.sh maya1|maya3 SHA";exit 2; }
NODE="$1"
REF="$2"
CTRL=/opt/dual-ha/controller.py
UNIT=dual-ha-v2-health.service
case "$NODE" in
  maya1)
    SOURCE=maya1-next-controller.py
    HELPNAME=maya1-dual-helper.py
    HELPER=/opt/dual-ha/helper/maya1_dual_backhaul_menu.py
    P1=21101;P2=21102;IP1=82.152.132.159;IP2=152.237.230.77
    ;;
  maya3)
    SOURCE=dual-backhaul-controller.py
    HELPNAME=dual_backhaul_menu.py
    HELPER=/opt/dual-ha/helper/dual_backhaul_menu.py
    P1=21001;P2=21002;IP1=152.237.230.140;IP2=82.152.132.112
    ;;
  *) echo "STOP: unsupported node";exit 2;;
esac
[[ -f "$CTRL" && ! -L "$CTRL" && -f "$HELPER" && ! -L "$HELPER" &&
   "$(readlink -f /usr/local/bin/dual)" == "$HELPER" ]] || {
 echo "STOP: unexpected installed controller or sudo dual entry";exit 3;
}
systemctl is-active --quiet x-ui
systemctl is-active --quiet dual-ha-v2-gateway
# Maya1 must also have persistent startup-enabled backend definitions.
# A runtime-only 'enable server' is lost if HAProxy restarts.
if [[ "$NODE" == maya1 ]];then
  grep -Fq 'server backhaul 127.0.0.1:21101 check' /etc/dual-ha/v2/haproxy.cfg || {
    echo "STOP: Maya1 HAProxy config does not persist staged Backhaul1";exit 3;
  }
  grep -Fq 'server mieru 127.0.0.1:21102 check' /etc/dual-ha/v2/haproxy.cfg || {
    echo "STOP: Maya1 HAProxy config does not persist staged Backhaul2";exit 3;
  }
  if grep -Eq 'server (backhaul|mieru) 127[.]0[.]0[.]1:2110[12] check disabled' /etc/dual-ha/v2/haproxy.cfg;then
    echo "STOP: Maya1 HAProxy disk config still has disabled backends."
    echo "Run previously prepared Maya1 emergency persistence script first."
    exit 3
  fi
fi
[[ "$(systemctl show -p ExecStart --value "$UNIT")" == *"$CTRL"* ]] || {
 echo "STOP: unexpected controller unit ExecStart";exit 3;
}
exec 9>/run/maya-three-site-v3.lock
flock -n 9 || { echo "STOP: installer locked";exit 3; }
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
TMP="$(mktemp -d /root/.three-site.XXXXXXXX)"
BACKUP=""
CHANGED=0
finish(){
 code=$?
 trap - EXIT
 if ((code!=0 && CHANGED==1));then
   systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
   cp -a "$BACKUP/ctrl.old" "$CTRL.restore"
   cp -a "$BACKUP/helper.old" "$HELPER.restore"
   mv -Tf "$CTRL.restore" "$CTRL"
   mv -Tf "$HELPER.restore" "$HELPER"
   echo "INSTALL_FAILED_OLD_FILES_RESTORED_CONTROLLER_DISABLED"
   echo "BACKUP=$BACKUP"
 fi
 rm -rf "$TMP"
 exit "$code"
}
trap finish EXIT
curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 "$BASE/$SOURCE" -o "$TMP/controller.py"
curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 "$BASE/$HELPNAME" -o "$TMP/helper.py"
python3 -m py_compile "$TMP/controller.py" "$TMP/helper.py"
python3 - "$TMP/controller.py" "$P1" "$P2" "$IP1" "$IP2" <<'PY'
import csv,importlib.util,io,socket,sys
script,p1,p2,ip1,ip2=sys.argv[1:]
p1,p2=int(p1),int(p2)
spec=importlib.util.spec_from_file_location("canary",script)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
assert m.CHECK_PERIOD==600 and m.CONFIRM_DELAY==20
assert m.POLICY=="two-backhaul-3site-10m-v3"
assert m.PATHS=={"backhaul":p1,"mieru":p2}
assert m.SHORT_FALL==2 and m.RISE==2
assert m.decision(True,True,0,999,0,False,peer_enabled=True,peer_short_ok=True) is None
for role,port,ip in (("backhaul",p1,ip1),("mieru",p2,ip2)):
 assert m.expected_ip(role)==ip,"node identity mismatch"
 passed,ok,avg,sites=m.three_site_probe(port,ip)
 print("V3_READ_ONLY_CANARY",role,passed,"/3",sites,flush=True)
 assert ok,"route not reachable across 2/3 independent destinations"
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
 s.settimeout(4);s.connect("/run/dual-ha-v2/haproxy.sock")
 s.sendall(b"show stat\n");s.shutdown(socket.SHUT_WR)
 buf=b""
 while True:
  x=s.recv(65536)
  if not x:break
  buf+=x
  assert len(buf)<1048576
lines=buf.decode(errors="replace").splitlines()
assert lines and lines[0].startswith("# pxname,")
rows={}
for row in csv.DictReader(io.StringIO("\n".join(lines[1:])),fieldnames=lines[0].lstrip("# ").split(",")):
 if row.get("pxname")=="dual_egress" and row.get("svname") in ("backhaul","mieru"):
  rows[row["svname"]]=row
assert set(rows)=={"backhaul","mieru"}
for name,port in (("backhaul",p1),("mieru",p2)):
 row=rows[name]
 assert row["addr"]=="127.0.0.1:"+str(port)
 assert row["status"].startswith("UP") and int(row["weight"])>0
print("V3_PREINSTALL_TWO_LANES_ACTIVE")
PY
BACKUP="/root/dual-backhaul-backups/$NODE-three-site-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p -m 0700 "$BACKUP"
cp -a "$CTRL" "$BACKUP/ctrl.old"
cp -a "$HELPER" "$BACKUP/helper.old"
echo "BACKUP=$BACKUP"
CHANGED=1
systemctl stop "$UNIT"
install -o root -g root -m 0600 "$TMP/controller.py" "$CTRL.v3-next"
install -o root -g root -m 0700 "$TMP/helper.py" "$HELPER.v3-next"
CHANGED=1
mv -Tf "$CTRL.v3-next" "$CTRL"
mv -Tf "$HELPER.v3-next" "$HELPER"
systemctl enable --now "$UNIT"
python3 - "$IP1" "$IP2" <<'PY'
import datetime,json,sys,time
from pathlib import Path
ip1,ip2=sys.argv[1:]
p=Path("/run/dual-ha-v2/health.json")
stop=time.monotonic()+85
while time.monotonic()<stop:
 try:
  d=json.loads(p.read_text())
  age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(d["updated_utc"])).total_seconds()
  if d.get("policy")=="two-backhaul-3site-10m-v3" and d.get("check_interval_s")==600 and 0<=age<30:
   for role,ip in (("backhaul",ip1),("mieru",ip2)):
    item=d["paths"][role]
    assert item["expected_foreign_ip"]==ip and item["passed_probes"]>=2
    assert item["routing_enabled"] is True
    assert len(item["https_checks"])==3
   print("V3_FRESH_10MIN_3SITE_STATUS_PASS")
   break
 except (OSError,KeyError,ValueError,TypeError,AssertionError):
  pass
 time.sleep(2)
else:
 raise RuntimeError("fresh healthy 3-site report not published")
PY
NO_COLOR=1 /usr/local/bin/dual status | tee "$TMP/status"
grep -Fq 'interval=600s' "$TMP/status"
grep -Fq 'BACKHAUL1' "$TMP/status"
grep -Fq 'BACKHAUL2' "$TMP/status"
systemctl is-active --quiet "$UNIT"
CHANGED=0
trap - EXIT
rm -rf "$TMP"
echo "MAYA_THREE_SITE_10MIN_V3_INSTALLED"
echo "NO_XRAY_HAPROXY_OR_TUNNEL_RESTART=TRUE"
echo "BACKUP=$BACKUP"
