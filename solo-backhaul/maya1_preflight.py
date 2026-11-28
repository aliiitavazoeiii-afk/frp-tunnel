#!/usr/bin/env python3
"""Solo Backhaul: Maya1 read-only inventory, guarded snapshot and cutover plan.

No service changes, no write to production configuration and no secret values
in ordinary output. Snapshot archives are private and MUST remain off chat.
"""
import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone

MAYA1_IP = "94.184.4.38"
BUNDLE = Path("/etc/dual-ha/backhaul-bundle.env")
STATS = Path("/run/dual-ha-v2/haproxy.sock")
PRODUCTION_GATEWAY_PORT = 18080
PORT_ALLOWLIST = {21001, 21101}
ROOT = Path("/root/solo-backhaul-snapshots")
XUI_DB = Path("/etc/x-ui/x-ui.db")
XRAY_CONFIGS = (
    Path("/usr/local/x-ui/bin/config.json"),
    Path("/usr/local/x-ui/bin/xray-config.json"),
    Path("/etc/xray/config.json"),
    Path("/usr/local/etc/xray/config.json"),
)

class Stop(RuntimeError):
    pass

def require(condition, explanation):
    if not condition:
        raise Stop(explanation)

def run(*argv, timeout=12):
    return subprocess.run(list(argv), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, timeout=timeout)

def status(unit):
    try:
        r = run("systemctl", "is-active", unit, timeout=4)
        return "active" if r.returncode == 0 else "inactive"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"

def identity():
    require(os.geteuid() == 0, "Run as root on Maya1")
    require(BUNDLE.is_file() and not BUNDLE.is_symlink(), "Original Backhaul bundle missing")
    b = BUNDLE.read_text()
    require(re.search(r"(?m)^BH_IRAN_IP=['\"]?94\.184\.4\.38['\"]?$", b),
            "This is not the expected Maya1 Backhaul identity")
    require(status("x-ui.service") == "active", "x-ui service is not active")

def haproxy_stats():
    require(STATS.is_socket(), "Gateway stats socket is not available")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(4)
        s.connect(str(STATS))
        s.sendall(b"show stat\n")
        s.shutdown(socket.SHUT_WR)
        buf = bytearray()
        while True:
            part = s.recv(32768)
            if not part:
                break
            buf.extend(part)
            require(len(buf) <= 1048576, "Gateway stats unexpectedly large")
    lines = buf.decode(errors="replace").splitlines()
    require(lines and lines[0].startswith("# pxname,"), "Unexpected gateway stats header")
    fields = lines[0][2:].split(",")
    backends = {}
    for row in csv.DictReader(io.StringIO("\n".join(lines[1:])), fieldnames=fields):
        if row.get("pxname") == "dual_egress" and row.get("svname") in ("backhaul", "mieru"):
            backends[row["svname"]] = {
                "status": row.get("status", "?"),
                "sessions": row.get("scur", "?"),
                "addr": row.get("addr", ""),
                "weight": row.get("weight", "?"),
            }
    require(set(backends) == {"backhaul", "mieru"}, "Unexpected gateway backend list")
    p = backends["backhaul"]["addr"]
    m = re.fullmatch(r"127\.0\.0\.1:(\d+)", p)
    require(m is not None, "Main Backhaul is not listening on loopback")
    port = int(m.group(1))
    require(port in PORT_ALLOWLIST, "Unexpected main Backhaul local port")
    require(backends["mieru"]["addr"].startswith("127.0.0.1:"),
            "Unexpected second backend address")
    return port, backends

def find_xray_refs():
    results = []
    for p in XRAY_CONFIGS:
        if not p.is_file():
            continue
        try:
            cfg = json.loads(p.read_text())
        except (ValueError, UnicodeError, OSError):
            results.append({"file": str(p), "error": "unparseable"})
            continue
        outbounds = cfg.get("outbounds", [])
        matches = []
        for ob in outbounds if isinstance(outbounds, list) else []:
            if not isinstance(ob, dict):
                continue
            settings = ob.get("settings") or {}
            servers = settings.get("servers") or []
            if isinstance(servers, list):
                for srv in servers:
                    if isinstance(srv, dict) and srv.get("address") in ("127.0.0.1", "localhost") and srv.get("port") == 18080:
                        matches.append({"tag": ob.get("tag", ""), "protocol": ob.get("protocol", "")})
            if settings.get("address") in ("127.0.0.1", "localhost") and settings.get("port") == 18080:
                matches.append({"tag": ob.get("tag", ""), "protocol": ob.get("protocol", "")})
        results.append({"file": str(p), "outbounds_to_gateway": matches})
    return results

def endpoint_probe(port):
    cmd = [
        "curl", "-q", "-4", "--noproxy", "", "--socks5-hostname", "127.0.0.1:" + str(port),
        "--connect-timeout", "5", "--max-time", "15", "--retry", "0", "--fail",
        "--silent", "--show-error", "https://www.cloudflare.com/cdn-cgi/trace"
    ]
    try:
        r = run(*cmd, timeout=18)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    match = re.search(r"(?m)^ip=(\d{1,3}(?:\.\d{1,3}){3})$", r.stdout)
    return match.group(1) if match else None

def inventory(probe=False):
    identity()
    port, lanes = haproxy_stats()
    print("SOLO_MAYA1_READONLY_AUDIT")
    print("IRAN:", MAYA1_IP)
    print("ACTIVE_BACKHAUL_LOCAL_PORT:", port)
    for name, data in lanes.items():
        print("LANE:", name, "status=", data["status"], "sessions=", data["sessions"],
              "addr=", data["addr"], "weight=", data["weight"])
    for service in (
        "x-ui.service", "dual-ha-v2-gateway.service", "dual-ha-v2-health.service",
        "maya1-next-bh1-backhaul.service", "maya1-next-bh1-router.service",
        "maya1-next-bh1-tls.service", "maya1-next-bh2-backhaul.service",
        "maya1-next-bh2-router.service", "maya1-next-bh2-tls.service"
    ):
        print("SERVICE:", service, status(service))
    refs = find_xray_refs()
    # Tags should not be printed: custom tags may contain user information.
    for item in refs:
        print("XRAY_FILE:", item["file"],
              "gateway_outbound_count=", len(item.get("outbounds_to_gateway", [])),
              "parse_error=", item.get("error", "none"))
    print("XRAY_CONFIG_DETECTED:", bool(refs))
    if probe:
        direct = endpoint_probe(port)
        gateway = endpoint_probe(PRODUCTION_GATEWAY_PORT)
        print("DIRECT_SOCKS_IP:", direct or "FAILED")
        print("GATEWAY_IP:", gateway or "FAILED")
        print("DIRECT_EQUALS_GATEWAY:", bool(direct and direct == gateway))
    print("NO_PRODUCTION_CHANGES=TRUE")
    return port, lanes, refs

def backup_paths():
    entries = [
        Path("/etc/dual-ha"),
        Path("/opt/dual-ha"),
        Path("/etc/haproxy"),
        Path("/etc/stunnel"),
        Path("/usr/local/bin/dual"),
        *XRAY_CONFIGS
    ]
    unit_dir = Path("/etc/systemd/system")
    if unit_dir.is_dir():
        entries.extend(p for p in unit_dir.iterdir()
                       if p.name.startswith(("dual-", "maya1-", "x-ui", "haproxy", "stunnel"))
                       and (p.is_file() or p.is_symlink() or p.is_dir()))
    unique = {}
    for p in entries:
        if p.exists() or p.is_symlink():
            unique[str(p)] = p
    return list(unique.values())

def sha256(path):
    hashobj = hashlib.sha256()
    with path.open("rb") as src:
        for chunk in iter(lambda: src.read(65536), b""):
            hashobj.update(chunk)
    return hashobj.hexdigest()

def snapshot():
    identity()
    require(XUI_DB.is_file() and not XUI_DB.is_symlink(),
            "X-UI SQLite DB not at /etc/x-ui/x-ui.db; stop and review DB backend")
    if Path("/etc/default/x-ui").is_file():
        config = Path("/etc/default/x-ui").read_text()
        require(not re.search(r"(?im)^\s*XUI_DB_TYPE\s*=\s*['\"]?(postgres|postgresql|pg)", config),
                "PostgreSQL needs a separate pg_dump backup")
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(ROOT, 0o700)
    now = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = Path(tempfile.mkdtemp(prefix=now + "-", dir=ROOT))
    os.chmod(folder, 0o700)
    try:
        db_copy = folder / "x-ui.db"
        src_uri = "file:" + str(XUI_DB) + "?mode=ro"
        with sqlite3.connect(src_uri, uri=True, timeout=15) as source:
            with sqlite3.connect(db_copy, timeout=15) as destination:
                source.backup(destination, pages=256, sleep=0.1)
                require(destination.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
                        "X-UI SQLite backup integrity check failed")
        os.chmod(db_copy, 0o600)
        archive = folder / "production-configs.tar.gz"
        with tarfile.open(archive, "w:gz", dereference=False) as tar:
            for path in backup_paths():
                tar.add(str(path), arcname=str(path).lstrip("/"), recursive=True)
        os.chmod(archive, 0o600)
        statuses = {
            s: {
                "active": status(s),
                "enabled": run("systemctl", "is-enabled", s, timeout=5).stdout.strip()
            }
            for s in (
                "x-ui.service", "dual-ha-v2-gateway.service",
                "dual-ha-v2-health.service", "maya1-next-bh1-backhaul.service",
                "maya1-next-bh1-router.service", "maya1-next-bh1-tls.service",
                "maya1-next-bh2-backhaul.service", "maya1-next-bh2-router.service",
                "maya1-next-bh2-tls.service"
            )
        }
        manifest = {
            "schema": "SOLO_SNAPSHOT_V1",
            "host": MAYA1_IP,
            "created_utc": now,
            "source_branch": "backup-dual-backhaul-2026-11-28",
            "sha256": {"x-ui.db": sha256(db_copy),
                       "production-configs.tar.gz": sha256(archive)},
            "services": statuses,
        }
        report = folder / "manifest.json"
        report.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        os.chmod(report, 0o600)
        print("SOLO_SNAPSHOT_COMPLETE")
        print("BACKUP_PATH:", folder)
        print("MANIFEST_SHA256:", sha256(report))
        print("DB_INTEGRITY_CHECK: ok")
        print("ALL_FILES_PRIVATE=TRUE")
        print("WARNING: archive contains secrets; never post or share it")
        print("NO_PRODUCTION_CHANGES=TRUE")
    except BaseException:
        print("SNAPSHOT_INCOMPLETE:", folder, "(private partial files; inspect manually)", file=sys.stderr)
        raise

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("audit", "snapshot", "plan"))
    parser.add_argument("--probe", action="store_true", help="Run read-only HTTPS egress checks")
    args = parser.parse_args()
    if args.operation == "snapshot":
        snapshot()
        return
    port, lanes, refs = inventory(probe=args.probe)
    if args.operation == "plan":
        safe = (
            lanes["backhaul"]["status"].startswith("UP")
            and len(refs) > 0
            and any(len(x.get("outbounds_to_gateway", [])) == 1 for x in refs)
            and not any(x.get("error") for x in refs)
        )
        print("DIRECT_TARGET:", "127.0.0.1:" + str(port))
        print("CURRENT_GATEWAY:", "127.0.0.1:18080")
        print("XRAY_SINGLE_GATEWAY_OUTBOUND_FOUND:", safe)
        print("MIGRATION_STATUS:", "REVIEW_REQUIRED_BEFORE_XUI_EDIT" if safe else "BLOCKED_REQUIRES_INSPECTION")
        print("RULE: prepare a single-client REALITY canary before any global X-UI change")
        print("RULE: leave tunnel binary, WSS/TLS files, keys, carrier and Pool Guard untouched")
        print("RULE: disable old health controller and gateway only after direct client tests")
        print("RULE: do not delete second lane until connection draining and verified rollback")
        print("NO_PRODUCTION_CHANGES=TRUE")

if __name__ == "__main__":
    try:
        main()
    except (Stop, OSError, ValueError, KeyError, sqlite3.Error,
            subprocess.TimeoutExpired) as exc:
        print("SOLO_STOP:", str(exc)[:300], file=sys.stderr)
        sys.exit(2)
