#!/usr/bin/env python3
"""Maya1 immutable transport fingerprint for Solo Backhaul migration.

Capture/verify only. NEVER stops/reloads services, changes Xray or touches
SOCKS gateway. Compares the live ORIGINAL Bh1 carrier, WSS router and TLS.
Foreign endpoint must be verified independently on the Foreign1 host.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

MAYA1 = "94.184.4.38"
BH1 = Path("/etc/dual-ha/maya1-next/bh1")
BASE = Path("/root/solo-backhaul-snapshots/transport-fingerprint-maya1.json")
UNITS = (
    "maya1-next-bh1-backhaul.service",
    "maya1-next-bh1-router.service",
    "maya1-next-bh1-tls.service",
)

class GuardError(RuntimeError):
    pass

def require(predicate, reason):
    if not predicate:
        raise GuardError(reason)

def read_command(*args):
    x = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, timeout=10, check=False)
    require(x.returncode == 0, "Cannot inspect service " + str(args[-1]))
    return x.stdout

def digest(data):
    return hashlib.sha256(data).hexdigest()

def file_digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 16), b""):
            h.update(block)
    return h.hexdigest()

def scan_transport():
    require(os.geteuid() == 0, "Run with root on Maya1 only")
    require(BH1.is_dir() and not BH1.is_symlink(), "Expected Bh1 config folder absent")
    state_file = BH1 / "state.json"
    require(state_file.is_file() and not state_file.is_symlink(), "Bh1 state missing")
    identity = json.loads(state_file.read_text())
    require(identity.get("iran_ip") == MAYA1 and identity.get("role") == "bh1"
            and identity.get("staging_socks") == 21101,
            "Unexpected Maya1 active Bh1 identity; stop")
    result = {"format": "SOLO_BH1_FINGERPRINT_V1", "host": MAYA1,
              "foreign": identity.get("foreign_ip"), "files": {}, "units": {}}
    for file in sorted(BH1.rglob("*")):
        require(not file.is_symlink(), "Bh1 config contains symlink: " + str(file))
        if file.is_dir():
            continue
        require(file.is_file(), "Bh1 config unexpected special file")
        result["files"][str(file)] = file_digest(file)
    for unit in UNITS:
        require(read_command("systemctl", "is-active", unit).strip() == b"active",
                "Expected transport unit inactive: " + unit)
        definition = read_command("systemctl", "cat", unit)
        pid_value = read_command("systemctl", "show", "--property=MainPID",
                                 "--value", unit).strip()
        require(pid_value.isdigit() and int(pid_value) > 0,
                "No running process for " + unit)
        # Hash the kernel's executable reference, rather than assuming a
        # particular installed binary path. Keeps the running core pinned.
        exe = Path("/proc") / pid_value.decode() / "exe"
        require(exe.is_file(), "Cannot access running executable for " + unit)
        result["units"][unit] = {
            "unit_sha256": digest(definition),
            "running_executable_sha256": file_digest(exe)
        }
    # Include the installed Backhaul binary as well, even if the process still
    # has an old inode. Do not replace/rebuild binaries in the Solo migration.
    binary = Path("/opt/dual-ha/bin/backhaul")
    require(binary.is_file(), "Original installed Backhaul binary missing")
    result["files"][str(binary)] = file_digest(binary)
    return result

def differences(old, new):
    changed = []
    for group in ("host", "foreign", "format"):
        if old.get(group) != new.get(group):
            changed.append(group)
    for group in ("files", "units"):
        previous, current = old.get(group, {}), new.get(group, {})
        for name in sorted(set(previous) | set(current)):
            if previous.get(name) != current.get(name):
                changed.append(group + "/" + name)
    return changed

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=("record", "verify"))
    p.add_argument("--baseline", type=Path, default=BASE)
    args = p.parse_args()
    current = scan_transport()
    if args.mode == "record":
        args.baseline.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(args.baseline.parent, 0o700)
        # Exclusive creation: never quietly overwrite the original fingerprint.
        fd = os.open(str(args.baseline), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(current, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        print("SOLO_TRANSPORT_BASELINE_SAVED", args.baseline)
        print("TRANSPORT_COMPONENT_COUNT", len(current["files"]) + len(current["units"]))
        print("NO_PRODUCTION_SERVICES_CHANGED=TRUE")
        return
    require(args.baseline.is_file() and not args.baseline.is_symlink(),
            "Baseline does not exist or is a symlink")
    old = json.loads(args.baseline.read_text())
    diff = differences(old, current)
    if diff:
        print("SOLO_TRANSPORT_FINGERPRINT_CHANGED")
        for item in diff:
            print("DIFFERENCE:", item)
        raise GuardError("Transport mismatch; reject Solo cutover until inspected")
    print("SOLO_TRANSPORT_FINGERPRINT_UNCHANGED")
    print("Iran-side Custom Backhaul, WSS router, TLS service/config binaries unchanged")
    print("NOTE: Foreign-side transport must be verified independently")

if __name__ == "__main__":
    try:
        main()
    except (GuardError, OSError, ValueError, KeyError,
            subprocess.TimeoutExpired) as exc:
        print("SOLO_GUARD_STOP:", str(exc)[:250], file=sys.stderr)
        sys.exit(2)
