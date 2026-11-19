#!/usr/bin/env python3
"""Interactive sudo dual for Maya3 independent Backhaul 1+2.
Original HAProxy backend names are retained. This is a presentation/orchestration
layer; it does not rewrite HAProxy, x-ui, original Backhaul binaries or credentials.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import dual
from dual_swap_v3 import rotate as rotate_primary, recover as recover_primary, get_weight

IRAN = "185.215.230.221"
META = Path("/etc/dual-ha/bh2-experiment/state.json")
BH2_SCRIPT = Path(__file__).resolve().parent / "dual-backhaul2-rotate.py"
BACKEND = {"backhaul1": "backhaul", "backhaul2": "mieru"}
PORTS = {"backhaul1": 21001, "backhaul2": 21002}
OLD_SCP = dual.scp

def scp_with_fallback(src, dst, *, timeout=40):
    try:
        return OLD_SCP(src, dst, timeout=timeout)
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        msg = str(exc).lower()
        # Do not retry if an authentication error, unknown host or unknown
        # filesystem condition occurred: fallback is only for SFTP incompatibility.
        if not any(fragment in msg for fragment in (
            "scp: connection closed", "subsystem request failed",
            "sftp subsystem", "connection closed"
        )):
            raise
        print("  SFTP unavailable: trying legacy SCP transport (-O)", flush=True)
        return dual.run(["scp", "-O", "-q", *dual.SSH_OPTS, src, dst],
                        timeout=timeout)

def roles():
    m = json.loads(META.read_text())
    if m.get("mode") != "active":
        raise RuntimeError("Backhaul2 experiment is not active; refusing dual mode")
    primary = dual.read_bundle()
    if primary.get("BH_IRAN_IP") != IRAN:
        raise RuntimeError("This command is enabled for Maya3 only")
    return {"backhaul1": primary["BH_FOREIGN_IP"], "backhaul2": m["foreign_ip"]}

def activate_compatibility():
    dual.scp = scp_with_fallback
    # Existing V3 primary rotation asks for dual.active_ips().mienu; when the
    # Mieru package is removed, supply the actual BH2 foreign IP instead.
    dual.active_ips = lambda: {
        "backhaul": dual.read_bundle()["BH_FOREIGN_IP"],
        "mieru": roles()["backhaul2"]
    }

def bh2():
    spec = importlib.util.spec_from_file_location("dual_backhaul2_rotate", BH2_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("BH2 rotation module unavailable")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def status():
    active = roles()
    h, age = dual.health_cache()
    backend = dual.haproxy_metrics()
    print("\n  DUAL BACKHAUL | MAYA3 | unchanged HAProxy leastconn")
    print("  ----------------------------------------------------------------")
    print("  IRAN: " + IRAN + "  | REALITY/x-ui: " + dual.status("x-ui"))
    for role in ("backhaul1", "backhaul2"):
        info = h.get(BACKEND[role], {})
        stats = backend.get(BACKEND[role], {})
        state = stats.get("state", "UNKNOWN")
        print("  %-9s foreign=%-16s SOCKS=%-5d %s" %
              (role.upper(), active[role], PORTS[role], state))
        try:
            weight = get_weight(BACKEND[role])
        except (OSError, ValueError, RuntimeError):
            weight = "?"
        print("        active=%s total=%s weight=%s | HTTPS=%s/3 | BULK=%s | bytes=%s speed=%s B/s" %
              (stats.get("current", "?"), stats.get("total", "?"), weight,
               info.get("passed_probes", "?"),
               info.get("bulk_pass", "not measured"),
               info.get("bulk_last", {}).get("bytes", "?"),
               info.get("bulk_last", {}).get("speed_bps", "?")))
    print("  Controller cache age: " + str(age) + "s")
    print("  ----------------------------------------------------------------")
    print("  NOTE: HAProxy's backend identifier 'mieru' now means BACKHAUL2.")
    print("  Original Mieru client package is not required for this mode.")

def health():
    status()
    from dual_swap_v3 import probe
    active = roles()
    for name in ("backhaul1", "backhaul2"):
        print("\n  Live 1-MiB verification: " + name)
        ok = probe(PORTS[name], active[name], label=name.upper())
        print("  " + name.upper() + " = " + ("PASS" if ok else "FAIL"))
    print("\n  IMPORTANT: existing TCP streams are not migrated during an outage.")

def jitter(samples=24):
    if not 8 <= samples <= 80:
        raise ValueError("Jitter sample count must be between 8 and 80")
    audit = Path(__file__).resolve().parent / "dual-backhaul-jitter-audit.py"
    if not audit.is_file():
        raise RuntimeError("Read-only jitter audit missing: update sudo dual helper")
    print("READ-ONLY jitter audit: no service config, anti-DPI or HAProxy changes.", flush=True)
    result = subprocess.run([sys.executable, str(audit), "--samples", str(samples)],
                            check=False)
    if result.returncode:
        raise RuntimeError("Jitter audit failed (exit %d)" % result.returncode)

def logs():
    for unit in ("dual-ha-backhaul", "dual-ha-bh2-server",
                 "dual-ha-bh2-router", "dual-ha-bh2-tls",
                 "dual-ha-v2-health"):
        r = subprocess.run(["journalctl", "-u", unit, "-n", "12",
                            "--no-pager", "-o", "short-iso"],
                           capture_output=True, text=True, timeout=10)
        print("\n=== " + unit + " ===")
        lines = [x for x in r.stdout.splitlines()
                 if not any(word in x.lower() for word in
                    ("password", "token=", "secret=", "privatekey"))]
        print("\n".join(lines[-12:]))

def replace(which, new_ip):
    if which not in BACKEND:
        raise RuntimeError("Choose backhaul1 or backhaul2")
    if new_ip in roles().values():
        raise RuntimeError("IP is already active in another role")
    activate_compatibility()
    if which == "backhaul1":
        rotate_primary("backhaul", new_ip)
        # The legacy Mieru rollback script checks this identity on return.
        m = json.loads(META.read_text())
        m["primary_ip"] = dual.read_bundle()["BH_FOREIGN_IP"]
        import tempfile
        fd, name = tempfile.mkstemp(prefix=".bh2-meta-", dir=str(META.parent))
        with os.fdopen(fd, "w") as f:
            json.dump(m, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(name, 0o600)
        os.replace(name, META)
    else:
        bh2().replace(new_ip)

def recover(which):
    activate_compatibility()
    if which == "backhaul1":
        recover_primary()
    elif which == "backhaul2":
        bh2().recover()
    else:
        raise RuntimeError("Choose backhaul1 or backhaul2")

def menu():
    while True:
        try:
            status()
            print("\n  [1] Status  [2] Live HTTPS+download health")
            print("  [3] Replace BACKHAUL 1 foreign server")
            print("  [4] Replace BACKHAUL 2 foreign server")
            print("  [5] Logs  [6] Recover interrupted swap  [7] Jitter audit  [0] Exit")
            choice = input("\n  dual > ").strip()
            if choice == "0":
                break
            if choice == "1":
                status()
            elif choice == "2":
                health()
            elif choice in ("3", "4"):
                which = "backhaul1" if choice == "3" else "backhaul2"
                ip = input("New FOREIGN IPv4 for " + which + ": ").strip()
                replace(which, ip)
            elif choice == "5":
                logs()
            elif choice == "7":
                jitter()
            elif choice == "6":
                which = input("Recover backhaul1 or backhaul2? ").strip().lower()
                recover(which)
            else:
                print("Choose 0–6")
        except (RuntimeError, ValueError, OSError,
                subprocess.TimeoutExpired) as exc:
            print("ERROR: " + str(exc)[:400], file=sys.stderr)
        except (KeyboardInterrupt, EOFError):
            print("\nExit")
            break

def main():
    if os.geteuid() != 0:
        raise RuntimeError("Run sudo dual")
    if len(sys.argv) == 1:
        if sys.stdin.isatty():
            menu()
        else:
            status()
        return
    if len(sys.argv) == 2 and sys.argv[1] == "status":
        status()
    elif len(sys.argv) == 2 and sys.argv[1] == "health":
        health()
    elif len(sys.argv) == 2 and sys.argv[1] == "logs":
        logs()
    elif len(sys.argv) in (2, 3) and sys.argv[1] == "jitter":
        jitter(int(sys.argv[2]) if len(sys.argv) == 3 else 24)
    elif len(sys.argv) == 4 and sys.argv[1] == "replace":
        replace(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "recover":
        recover(sys.argv[2])
    else:
        raise RuntimeError(
            "Usage: sudo dual [status|health|jitter [8..80]|logs|replace backhaul1|backhaul2 NEW_IP|recover backhaul1|backhaul2]"
        )

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
        print("ERROR: " + str(exc), file=sys.stderr)
        sys.exit(1)
