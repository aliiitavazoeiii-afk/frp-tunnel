#!/usr/bin/env bash
# Safely replace ONLY the local "sudo dual" status/helper entry point on Maya1.
# Requires completed verified cutover and both actual HAProxy targets on new SOCKS.
# Does NOT touch VPN transports, Xray, HAProxy, controller or old endpoints.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 && $# == 1 && "$1" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Usage: sudo bash install-maya1-helper.sh EXACT_COMMIT";exit 2;
}
REF="$1"
OLD=/usr/local/bin/dual
TARGET=/opt/dual-ha/helper/maya1_dual_backhaul_menu.py
PENDING=/usr/local/bin/dual.maya1.pending

# Refuse unknown entry points, broken links, non-root ownership or double install.
[[ "$(command -v dual || true)" == "$OLD" ]] || {
  echo "STOP: sudo dual is not resolved from /usr/local/bin/dual";exit 3;
}
[[ -e "$OLD" && ! -d "$OLD" && "$(stat -Lc '%u' "$OLD")" == 0 ]] || {
  echo "STOP: old sudo dual command absent/broken/not root-owned";exit 3;
}
[[ ! -e "$TARGET" && ! -L "$TARGET" && ! -e "$PENDING" && ! -L "$PENDING" ]] || {
  echo "STOP: partial/new Maya1 helper already exists; refuse overwrite";exit 3;
}
python3 - <<'PY'
import csv,datetime,io,json,socket
from pathlib import Path
mfile=Path("/etc/dual-ha/maya1-next/cutover-state.json")
assert mfile.is_file() and not mfile.is_symlink(),"Cutover marker missing"
marker=json.loads(mfile.read_text())
assert marker.get("format")=="MAYA1_NEXT_V1"
assert marker.get("phase")=="completed" and marker.get("iran")=="94.184.4.38","Cutover not completed"
j=json.loads(Path("/run/dual-ha-v2/health.json").read_text())
assert j.get("policy")=="two-backhaul-bulk-v1"
dt=datetime.datetime.fromisoformat(j["updated_utc"])
age=(datetime.datetime.now(datetime.timezone.utc)-dt).total_seconds()
assert 0 <= age <= 35,"Controller health stale"
lanes={"backhaul":("bh1","82.152.132.159",21101),
       "mieru":("bh2","152.237.230.77",21102)}
for backend,(folder,ip,port) in lanes.items():
  d=j["paths"][backend]
  assert d["expected_foreign_ip"]==ip,"Controller IP mismatch"
  assert d["passed_probes"]>=2 and d["bulk_pass"] is True,"Health check failed"
  assert d["bulk_last"]["bytes"]==1048576 and d["bulk_last"]["sample_pass"]>=2,"Quality unverified"
  stage=json.loads((Path("/etc/dual-ha/maya1-next")/folder/"state.json").read_text())
  assert stage["foreign_ip"]==ip and stage["staging_socks"]==port,"Staging identity mismatch"
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
  s.settimeout(4)
  s.connect("/run/dual-ha-v2/haproxy.sock")
  s.sendall(b"show stat\n")
  s.shutdown(socket.SHUT_WR)
  blocks=[];n=0
  while True:
    x=s.recv(65536)
    if not x:break
    n+=len(x)
    assert n<=1048576,"HAProxy response too large"
    blocks.append(x)
lines=b"".join(blocks).decode(errors="replace").splitlines()
assert lines and lines[0].startswith("# pxname,"),"HAProxy stats missing"
found={}
for r in csv.DictReader(io.StringIO("\n".join(lines[1:])),
                        fieldnames=lines[0].lstrip("# ").split(",")):
  if r.get("pxname")=="dual_egress" and r.get("svname") in lanes:
    found[r["svname"]]=r
assert set(found)==set(lanes),"Missing expected HAProxy backend"
for backend,(_,ip,port) in lanes.items():
  row=found[backend]
  assert row.get("addr")==f"127.0.0.1:{port}",f"Wrong HAProxy target for {backend}"
  assert row.get("status")=="UP",f"HAProxy backend {backend} not UP"
print("MAYA1_LIVE_DUAL_BACKHAUL_ROUTING_AND_HEALTH_VERIFIED")
PY
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
T="$(mktemp /root/.maya1-helper.XXXXXXXX.py)"
trap 'rm -f "$T" "$PENDING"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 \
  "$BASE/maya1-dual-helper.py" -o "$T"
python3 -m py_compile "$T"
OUTPUT="$(NO_COLOR=1 python3 "$T" status)"
grep -Fq "BACKHAUL1" <<<"$OUTPUT"
grep -Fq "BACKHAUL2" <<<"$OUTPUT"
grep -Fq "82.152.132.159" <<<"$OUTPUT"
grep -Fq "152.237.230.77" <<<"$OUTPUT"
[[ "$OUTPUT" != *$'\033'* ]] || {
  echo "STOP: invalid ANSI in no-color status output";exit 3;
}
BACKUP="/root/dual-backhaul-backups/maya1-helper-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p -m 0700 "$BACKUP"
cp -a "$OLD" "$BACKUP/dual.previous"
cat >"$BACKUP/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID == 0 ]] || { echo "Root required";exit 2; }
[[ "\$(readlink -f '$OLD')" == '$TARGET' ]] || {
  echo "STOP: current dual is no longer the Maya1 helper; not overwriting";exit 3;
}
cp -a "$BACKUP/dual.previous" "$BACKUP/dual.previous.restore.tmp"
mv -Tf "$BACKUP/dual.previous.restore.tmp" "$OLD"
echo "MAYA1_PREVIOUS_DUAL_COMMAND_RESTORED"
EOF
chmod 0700 "$BACKUP/rollback.sh"
mkdir -p -m 0755 /opt/dual-ha/helper
install -o root -g root -m 0700 "$T" "$TARGET"
ln -s "$TARGET" "$PENDING"
mv -Tf "$PENDING" "$OLD"
if ! NO_COLOR=1 "$OLD" status >/dev/null;then
  bash "$BACKUP/rollback.sh"
  echo "STOP: new helper did not pass postinstall status"
  exit 4
fi
echo "MAYA1_COLOR_DUAL_HELPER_INSTALLED"
echo "NO_TUNNEL_CONTROLLER_HAPROXY_XRAY_CHANGES=TRUE"
echo "ROLES=BACKHAUL1+BACKHAUL2"
echo "OLD_BACKHAUL_MIERU_REPLACE_DISABLED=TRUE"
echo "ROLLBACK: sudo bash $BACKUP/rollback.sh"
echo "NEXT: sudo dual"
