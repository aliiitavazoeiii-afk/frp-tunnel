#!/usr/bin/env python3
"""Patch only the local sudo dual operator menu; preserve diagnostics and all runtime services."""
import ast
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(source)
defs = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
required = {"main", "menu", "print_status", "logs"}
if not required.issubset(defs) or 'from dual_swap_v3 import rotate as v3_rotate' in source:
    raise SystemExit("Dual.py entrypoint incompatible or V3 already installed; no changes")
if not any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
           and n.func.id == "menu" for n in ast.walk(defs["main"])):
    raise SystemExit("Main entrypoint does not call menu(); refusing ambiguous patch")

# Replace only the operator-facing menu. Host-specific role dispatch is no longer assumed.
menu_code = '''def menu() -> None:
    """V3 operator menu; preserves existing dual status/health/logs actions."""
    while True:
        print_status()
        print("\\n  [1] Dashboard      [2] Detailed health / diagnosis")
        print("  [3] Replace BACKHAUL foreign host (V3)")
        print("  [4] Replace MIERU foreign host (V3)")
        print("  [5] Last service logs")
        print("  [6] Recover interrupted V3 operation")
        print("  [0] Exit")
        try:
            selection = input("\\n  dual > ").strip()
            if selection == "0":
                break
            elif selection == "1":
                print_status()
            elif selection == "2":
                print_status(deep=True)
            elif selection in ("3", "4"):
                role = "backhaul" if selection == "3" else "mieru"
                new_ip = input("  New public foreign IPv4 for %s: " % role).strip()
                from dual_swap_v3 import rotate as v3_rotate
                v3_rotate(role, new_ip)
            elif selection == "5":
                logs()
            elif selection == "6":
                from dual_swap_v3 import recover as v3_recover
                v3_recover()
            else:
                print("  Choose 0-6")
        except (EOFError, KeyboardInterrupt):
            print("\\n  Exiting.")
            break
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as e:
            print(color("  ERROR: " + str(e), "1;31"))
'''
changes = [(defs["menu"].lineno, defs["menu"].end_lineno, menu_code)]
if "rotate" in defs:
    rot = defs["rotate"]
    if [arg.arg for arg in rot.args.args][:2] != ["role", "new_ip"]:
        raise SystemExit("Unexpected rotate signature; refusing patch")
    rotate_code = '''def rotate(role: str, new_ip: str) -> None:
    """Use the same V3 engine from the legacy direct CLI replace path."""
    from dual_swap_v3 import rotate as v3_rotate
    v3_rotate(role, new_ip)
'''
    changes.append((rot.lineno, rot.end_lineno, rotate_code))
lines = source.splitlines(keepends=True)
for start, end, replacement in sorted(changes, reverse=True):
    lines[start - 1:end] = [replacement]
output = ''.join(lines)
new_tree = ast.parse(output)
newdefs = {n.name: n for n in new_tree.body if isinstance(n, ast.FunctionDef)}
assert required.issubset(newdefs)
assert output.count('from dual_swap_v3 import rotate as v3_rotate') >= 1
assert output.count('from dual_swap_v3 import recover as v3_recover') == 1
Path(sys.argv[2]).write_text(output, encoding="utf-8")
