#!/usr/bin/env python3
"""Foreign VPS passive snapshot for restoring unchanged Custom Backhaul services.

No installs, stops, reloads, port changes or network access.
Run locally on the ORIGINAL foreign VPS, not on Maya1.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path("/root/solo-backhaul-foreign-snapshots")
SERVICE_PREFIXES = ("dual-ha", "maya1-next", "maya3", "maya4", "backhaul", "stunnel", "haproxy")

def checksum(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def service_units():
    folder = Path("/etc/systemd/system")
    if not folder.is_dir():
        return []
    return [p for p in folder.iterdir()
            if p.name.endswith((".service", ".timer", ".socket", ".d"))
            and p.name.startswith(SERVICE_PREFIXES)]

def selected_files():
    paths = [
        Path("/etc/dual-ha"), Path("/opt/dual-ha"),
        Path("/etc/haproxy"), Path("/etc/stunnel"),
        Path("/usr/local/bin/dual"),
        Path("/usr/local/bin/backhaul"),
        Path("/usr/local/bin/haproxy"),
        Path("/etc/letsencrypt/live"),
        Path("/etc/letsencrypt/archive"),
        *service_units()
    ]
    return list({str(p): p for p in paths if p.exists() or p.is_symlink()}.values())

def service_state(name, operation):
    try:
        r = subprocess.run(["systemctl", operation, name], capture_output=True,
                           text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else "unknown"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"

def main():
    if os.geteuid() != 0:
        raise RuntimeError("root required")
    paths = selected_files()
    if not paths or not Path("/opt/dual-ha").is_dir():
        raise RuntimeError("Expected Custom Backhaul installation was not found; STOP")
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(ROOT, 0o700)
    name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = Path(tempfile.mkdtemp(prefix=name + "-", dir=ROOT))
    os.chmod(folder, 0o700)
    archive = folder / "foreign-original.tar.gz"
    with tarfile.open(archive, "w:gz", dereference=False) as tar:
        for path in paths:
            tar.add(str(path), arcname=str(path).lstrip("/"), recursive=True)
    os.chmod(archive, 0o600)
    units = [p.name for p in service_units() if p.name.endswith(".service")]
    manifest = {
        "format": "SOLO_FOREIGN_SNAPSHOT_V1",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "host": os.uname().nodename,
        "archives": {"foreign-original.tar.gz": checksum(archive)},
        "systemd": {u: {
            "active": service_state(u, "is-active"),
            "enabled": service_state(u, "is-enabled")
        } for u in units},
    }
    out = folder / "manifest.json"
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    os.chmod(out, 0o600)
    print("FOREIGN_SNAPSHOT_COMPLETE")
    print("HOST:", os.uname().nodename)
    print("BACKUP_PATH:", folder)
    print("ARCHIVE_SHA256:", checksum(archive))
    print("NO_SERVICES_CHANGED=TRUE")
    print("PRIVATE: contains passwords and TLS private keys; NEVER paste/archive publicly")
    print("Backup is not a proof of network connectivity or anti-DPI behavior")

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print("FOREIGN_SNAPSHOT_STOP:", str(exc)[:300], file=sys.stderr)
        sys.exit(2)
