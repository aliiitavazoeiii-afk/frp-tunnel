#!/usr/bin/env bash
# Installs the GitHub-hosted Auto Replace menu into an existing Iran Dual HA v2 (Maya3/Maya4 compatible).
# No x-ui, Reality, HAProxy, Backhaul, or Mieru service restart.
set -Eeuo pipefail
[[ "$EUID" -eq 0 ]] || { echo "Run as root: sudo bash install-dual-auto.sh"; exit 2; }
HELPER=/opt/dual-ha/helper
LIVE="$HELPER/dual.py"
[[ -f "$LIVE" && -f "$HELPER/foreign-install.sh" ]] || {
  echo "Existing sudo dual helper not installed; refusing"; exit 2;
}
[[ -L /usr/local/bin/dual && "$(readlink /usr/local/bin/dual)" = "$LIVE" ]] || {
  echo "Unexpected /usr/local/bin/dual; refusing"; exit 2;
}
[[ -r /etc/dual-ha/backhaul-bundle.env && -r /etc/dual-ha/mieru.json ]] || {
  echo "Live Dual HA config missing; refusing"; exit 2;
}
IRAN="$(sed -n "s/^BH_IRAN_IP='\([0-9.]*\)'$/\1/p" /etc/dual-ha/backhaul-bundle.env)"
python3 - "$IRAN" <<'PY'
import ipaddress,sys
try:
    host=ipaddress.ip_address(sys.argv[1])
    if not isinstance(host, ipaddress.IPv4Address) or not host.is_global:
        raise ValueError("Configured host is not a public IPv4")
except ValueError as exc:
    raise SystemExit("Invalid BH_IRAN_IP: " + str(exc))
PY
echo "Detected configured Iran Dual HA host: $IRAN"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
BASE=https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/71894c52b6480a3fcb3127e1351c86fa12bfe64a/dual-backhaul-mieru-ha/v2
curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 \
  "$BASE/dual_auto.py" -o "$TMPDIR/dual_auto.py"
python3 -m py_compile "$TMPDIR/dual_auto.py"
if ! /usr/bin/python3 -c 'import paramiko' >/dev/null 2>&1; then
  echo "Installing Ubuntu python3-paramiko..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3-paramiko
fi
/usr/bin/python3 -c 'import paramiko'

python3 - "$LIVE" "$TMPDIR/patched-dual.py" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
out=Path(sys.argv[2])
if "Auto-replace BACKHAUL (IP + password)" in source:
    out.write_text(source)
    raise SystemExit(0)
menu_old='''                role = "backhaul" if selection == "3" else "mieru"
                new_ip = input("  New public foreign IPv4 for %s: " % role).strip()
                rotate(role, new_ip)'''
menu_new='''                role = "backhaul" if selection == "3" else "mieru"
                rc = subprocess.run(["/usr/bin/python3", str(HELPER / "dual_auto.py"), role]).returncode
                if rc:
                    raise RuntimeError("Auto replacement failed (exit %d)" % rc)'''
cli_old='''        elif args.command == "replace":
            rotate(args.role, args.ip)'''
cli_new='''        elif args.command == "replace":
            rc = subprocess.run(["/usr/bin/python3", str(HELPER / "dual_auto.py"), args.role, args.ip]).returncode
            if rc:
                raise RuntimeError("Auto replacement failed (exit %d)" % rc)'''
labels=(
 ("print(\"  [3] Replace BACKHAUL foreign host\")",
  "print(\"  [3] Auto-replace BACKHAUL (IP + password)\")"),
 ("print(\"  [4] Replace MIERU foreign host\")",
  "print(\"  [4] Auto-replace MIERU (IP + password)\")"),
)
for a,b in [(menu_old,menu_new),(cli_old,cli_new),*labels]:
    if source.count(a)!=1:
        raise SystemExit("Installed dual.py differs from expected version; refusing modification")
    source=source.replace(a,b)
out.write_text(source)
PY
python3 -m py_compile "$TMPDIR/patched-dual.py"
stamp="$(date +%Y%m%d-%H%M%S)"
cp -a "$LIVE" "$LIVE.before-auto-$stamp"
install -m 0755 "$TMPDIR/dual_auto.py" "$HELPER/dual_auto.py"
install -m 0755 "$TMPDIR/patched-dual.py" "$LIVE"

echo "AUTO REPLACE INSTALLED. No running tunnel or Xray services were restarted."
echo "Use: sudo dual  -> [3] Backhaul or [4] Mieru, enter IPv4 and new root password."
echo "Or: sudo dual replace backhaul NEW_IP"
echo "Backup: $LIVE.before-auto-$stamp"
