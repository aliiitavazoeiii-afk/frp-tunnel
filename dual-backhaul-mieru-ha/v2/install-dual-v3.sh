#!/usr/bin/env bash
# Only modifies the dual helper files: no tunnel restart/config, no firewall changes.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Use sudo'; exit 2; }
umask 077
REF='8fd7a18b71ee5c206c6ee75f9315d6a25a24c28c'
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
D='/opt/dual-ha/helper'
[[ "$(readlink -f /usr/local/bin/dual)" == "$D/dual.py" ]] || { echo 'Unknown dual entrypoint'; exit 3; }
[[ -r "$D/dual.py" && -r "$D/foreign-install.sh" ]] || { echo 'Unsupported Dual layout'; exit 3; }
[[ -r /etc/dual-ha/backhaul-bundle.env && -r /etc/dual-ha/mieru.json ]] || { echo 'Missing Dual config'; exit 3; }
IRAN="$(sed -n "s/^BH_IRAN_IP='\([0-9.]*\)'$/\1/p" /etc/dual-ha/backhaul-bundle.env)"
case "$IRAN" in 94.184.4.38|185.215.230.221|5.10.249.206) ;; *) echo 'Unknown Iran host';exit 3;; esac
if ! python3 -c 'import paramiko' >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3-paramiko
  python3 -c 'import paramiko'
fi
T="$(mktemp -d /root/.dual-v3-installer.XXXXXXXX)"
B="/root/dual-ha-helper-backup/v3-$(date -u +%Y%m%dT%H%M%SZ)"
started=0
had_auto=0;had_v3=0
[[ -e "$D/dual_auto.py" ]] && had_auto=1
[[ -e "$D/dual_swap_v3.py" ]] && had_v3=1
undo() {
  [[ "$started" == 1 ]] || return 0
  cp -a "$B/dual.py" "$D/dual.py"
  if [[ "$had_auto" == 1 ]];then cp -a "$B/dual_auto.py" "$D/dual_auto.py";else rm -f "$D/dual_auto.py";fi
  if [[ "$had_v3" == 1 ]];then cp -a "$B/dual_swap_v3.py" "$D/dual_swap_v3.py";else rm -f "$D/dual_swap_v3.py";fi
}
finish() {
  local code=$?
  trap - EXIT
  [[ "$code" == 0 ]] || undo || true
  rm -rf "$T"
  exit "$code"
}
trap finish EXIT
for f in dual_swap_v3.py dual_auto.py test_dual_swap_v3.py; do
  curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 12 --max-time 90 "$BASE/$f" -o "$T/$f"
  [[ -s "$T/$f" ]] || exit 4
done
python3 - "$D/dual.py" "$T/dual.py" <<'PY'
import ast
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
tree = ast.parse(source)
defs = {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}
rotate, menu = defs.get("rotate"), defs.get("menu")
if not rotate or not menu or "from dual_swap_v3 import" in source:
    raise SystemExit("Unsupported/already upgraded dual.py: refusing install")
if [arg.arg for arg in rotate.args.args][:2] != ["role", "new_ip"]:
    raise SystemExit("Unexpected rotate() signature: refusing install")
if not any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
           and n.func.id == "rotate" for n in ast.walk(menu)):
    raise SystemExit("Existing menu does not invoke rotate(): refusing install")
lines = source.splitlines(keepends=True)
menu_source = "".join(lines[menu.lineno-1:menu.end_lineno])
if not all(re.search(r"""['"]""" + str(c) + r"""['"]""", menu_source) for c in (3, 4)):
    raise SystemExit("Options 3/4 not found in existing menu: refusing install")
# Retain all host-specific menu labels and any other menu items.
branch = re.compile(r"""(?m)^(?P<i>[ \t]*)elif[ \t]+selection[ \t]*==[ \t]*['"]5['"]:[ \t]*\n(?P<b>[ \t]*)logs\(\)[ \t]*$""")
m = branch.search(menu_source)
if not m:
    raise SystemExit("Recovery branch anchor not recognized; no files changed")
addition = (m.group(0) + "\n" + m.group("i") + 'elif selection == "6":\n'
            + m.group("b") + "from dual_swap_v3 import recover\n"
            + m.group("b") + "recover()")
menu_source = menu_source[:m.start()] + addition + menu_source[m.end():]
exitline = re.compile(r"""(?m)^(?P<i>[ \t]*)print\(['"][^\n]*\[0\][^\n]*Exit[^\n]*\)""")
m = exitline.search(menu_source)
if not m:
    raise SystemExit("Menu exit line not recognized; no files changed")
menu_source = (menu_source[:m.start()] + m.group("i")
               + 'print("  [6] Recover interrupted V3 operation")\n'
               + menu_source[m.start():])
lines[menu.lineno-1:menu.end_lineno] = [menu_source]
source = "".join(lines)
tree = ast.parse(source)
rotate = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "rotate")
lines = source.splitlines(keepends=True)
replacement = '''def rotate(role: str, new_ip: str) -> None:
    """Transactional V3 engine behind standard sudo dual choices 3 and 4."""
    from dual_swap_v3 import rotate as v3_rotate
    v3_rotate(role, new_ip)
'''
lines[rotate.lineno-1:rotate.end_lineno] = [replacement]
output = "".join(lines)
ast.parse(output)
if output.count("from dual_swap_v3 import rotate as v3_rotate") != 1:
    raise SystemExit("V3 patch verification failed")
if output.count("from dual_swap_v3 import recover") != 1:
    raise SystemExit("V3 recovery verification failed")
Path(sys.argv[2]).write_text(output)
PY
python3 -m py_compile "$T/dual.py" "$T/dual_auto.py" "$T/dual_swap_v3.py"
python3 "$T/test_dual_swap_v3.py" -q
mkdir -p -m 0700 "$B"
cp -a "$D/dual.py" "$B/dual.py"
[[ "$had_auto" == 0 ]] || cp -a "$D/dual_auto.py" "$B/dual_auto.py"
[[ "$had_v3" == 0 ]] || cp -a "$D/dual_swap_v3.py" "$B/dual_swap_v3.py"
echo "$REF" > "$B/source-commit.txt"
started=1
install -m 0700 "$T/dual.py" "$D/.dual.py.v3-next"
install -m 0600 "$T/dual_auto.py" "$D/.dual_auto.py.v3-next"
install -m 0600 "$T/dual_swap_v3.py" "$D/.dual_swap_v3.py.v3-next"
mv -f "$D/.dual_auto.py.v3-next" "$D/dual_auto.py"
mv -f "$D/.dual_swap_v3.py.v3-next" "$D/dual_swap_v3.py"
mv -f "$D/.dual.py.v3-next" "$D/dual.py"
PYTHONPATH="$D" python3 -c 'import dual;import dual_auto;import dual_swap_v3'
/usr/local/bin/dual status >/dev/null
cat >"$B/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || exit 2
if grep -Eq '"phase": "(staging|cutover|committed)"' /root/dual-ha-rotations/v3/current.json 2>/dev/null;then
 echo 'Finish/recover V3 transaction in sudo dual first';exit 3
fi
cp -a '$B/dual.py' '$D/dual.py'
EOF
if [[ "$had_auto" == 1 ]];then echo "cp -a '$B/dual_auto.py' '$D/dual_auto.py'" >>"$B/rollback.sh";else echo "rm -f '$D/dual_auto.py'" >>"$B/rollback.sh";fi
if [[ "$had_v3" == 1 ]];then echo "cp -a '$B/dual_swap_v3.py' '$D/dual_swap_v3.py'" >>"$B/rollback.sh";else echo "rm -f '$D/dual_swap_v3.py'" >>"$B/rollback.sh";fi
chmod 0700 "$B/rollback.sh"
started=0
echo 'V3_HELPER_INSTALLED; no VPN services restarted'
echo "Backups: $B"
echo 'Next: sudo dual  (3=Backhaul, 4=Mieru, 6=Recovery)'