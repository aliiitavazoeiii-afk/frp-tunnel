#!/usr/bin/env python3
"""Dual egress health controller. No traffic is enabled without proven HTTPS egress."""
import concurrent.futures
import csv
import io
import json
import os
import socket
import subprocess
import time
from datetime import datetime, timezone

SOCK = "/run/dual-ha-v2/haproxy.sock"
STATUS = "/run/dual-ha-v2/health.json"
PATHS = {"backhaul": 21001, "mieru": 21002}
TARGETS = (
    ("https://www.gstatic.com/generate_204", 204),
    ("https://www.cloudflare.com/cdn-cgi/trace", 200),
    ("https://www.apple.com/library/test/success.html", 200),
)
INTERVAL = 8
FALL = 3
RISE = 5
REQUIRED_PASS = 2


def api(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(3)
        s.connect(SOCK)
        s.sendall((command + "\n").encode())
        s.shutdown(socket.SHUT_WR)
        data = bytearray()
        while True:
            chunk = s.recv(32768)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > 1024 * 1024:
                raise ValueError("HAProxy response too large")
        return data.decode(errors="replace")


def states():
    result = {}
    lines = [line for line in api("show stat").splitlines() if line.strip()]
    if not lines:
        return result
    header = lines[0].lstrip("# ").split(",")
    for row in csv.DictReader(io.StringIO("\n".join(lines[1:])), fieldnames=header):
        if row.get("pxname") == "dual_egress" and row.get("svname") in PATHS:
            result[row["svname"]] = row.get("status", "")
    return result


def probe_one(port, url, expected):
    cmd = [
        "curl", "-4", "--silent", "--show-error", "--output", "/dev/null",
        "--write-out", "%{http_code} %{time_total}",
        "--connect-timeout", "3", "--max-time", "7",
        "--noproxy", "", "--socks5-hostname", f"127.0.0.1:{port}", url,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=9)
        chunks = result.stdout.strip().split()
        http = int(chunks[0]) if chunks else 0
        seconds = float(chunks[1]) if len(chunks) > 1 else 99.0
        return result.returncode == 0 and http == expected, round(seconds, 3)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False, 99.0


def probe_path(port):
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(TARGETS)) as pool:
        futures = [pool.submit(probe_one, port, url, expected) for url, expected in TARGETS]
        values = [f.result() for f in futures]
    passed = sum(ok for ok, _ in values)
    times = [sec for ok, sec in values if ok]
    return passed >= REQUIRED_PASS, passed, round(sum(times) / len(times), 3) if times else None


def write_state(data):
    safe = STATUS + ".tmp"
    with open(safe, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(safe, STATUS)


def main():
    import sys
    sys.stdout.reconfigure(line_buffering=True)
    streaks = {name: {"good": 0, "bad": 0, "enabled": None} for name in PATHS}
    while True:
        try:
            state = states()
        except (OSError, ValueError) as e:
            print(f"HAProxy stats unavailable: {e}")
            time.sleep(INTERVAL)
            continue

        for name, port in PATHS.items():
            ok, passed, latency = probe_path(port)
            s = streaks[name]
            s["good"] = s["good"] + 1 if ok else 0
            s["bad"] = 0 if ok else s["bad"] + 1
            old = state.get(name, "UNKNOWN")
            s["enabled"] = old not in ("MAINT", "UNKNOWN", "STOPPED")
            action = None
            if s["enabled"] and s["bad"] >= FALL:
                action = "disable"
            if not s["enabled"] and s["good"] >= RISE:
                action = "enable"
            if action:
                try:
                    answer = api(f"{action} server dual_egress/{name}")
                    if "error" in answer.lower() or "unknown" in answer.lower():
                        raise ValueError(answer)
                    s["enabled"] = action == "enable"
                    print(f"{name}: {action.upper()} after HTTPS end-to-end probes")
                except (OSError, ValueError) as e:
                    print(f"{name}: HAProxy {action} FAILED: {e}")
            state[name] = {
                "available": s["enabled"],
                "passed_probes": passed,
                "total_probes": len(TARGETS),
                "latency_average_s": latency,
                "consecutive_success": s["good"],
                "consecutive_fail": s["bad"],
                "haproxy_before_action": old,
            }
        write_state({"updated_utc": datetime.now(timezone.utc).isoformat(), "paths": state})
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
