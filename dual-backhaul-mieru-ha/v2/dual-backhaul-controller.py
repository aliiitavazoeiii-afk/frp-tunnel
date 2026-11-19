#!/usr/bin/env python3
"""Maya3 dual Backhaul data-plane health controller.
Keeps original HAProxy frontend/backend and leastconn unchanged.
The second backend keeps legacy HAProxy identifier 'mieru' but is Backhaul2.
"""
import concurrent.futures
import csv
import io
import json
import os
import re
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

SOCK = "/run/dual-ha-v2/haproxy.sock"
STATUS = "/run/dual-ha-v2/health.json"
PATHS = {"backhaul": 21001, "mieru": 21002}
TARGETS = (
    ("https://www.gstatic.com/generate_204", "204"),
    ("https://www.cloudflare.com/cdn-cgi/trace", "200"),
    ("https://www.apple.com/library/test/success.html", "200"),
)
BULK_URL = "https://speed.cloudflare.com/__down?bytes=262144"
BULK_BYTES = 262144
BULK_PERIOD = 45
SLEEP_SECONDS = 8
MIN_BULK_BYTES_PER_SECOND = 96 * 1024
SHORT_FALL = 2
BULK_FALL = 2
RISE = 3

def api(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(4)
        s.connect(SOCK)
        s.sendall((command + "\n").encode())
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            part = s.recv(65536)
            if not part:
                break
            chunks.append(part)
            if sum(map(len, chunks)) > 1024 * 1024:
                raise ValueError("HAProxy response too large")
    answer = b"".join(chunks).decode(errors="replace")
    if "error" in answer.lower() or "unknown" in answer.lower():
        raise ValueError("HAProxy command failed")
    return answer

def states():
    rows = [line for line in api("show stat").splitlines() if line.strip()]
    if not rows:
        raise ValueError("Empty HAProxy stats")
    fields = rows[0].lstrip("# ").split(",")
    data = {}
    for r in csv.DictReader(io.StringIO("\n".join(rows[1:])), fieldnames=fields):
        if r.get("pxname") == "dual_egress" and r.get("svname") in PATHS:
            data[r["svname"]] = {
                "status": r.get("status", "UNKNOWN"),
                "weight": r.get("weight", "?")
            }
    if set(data) != set(PATHS):
        raise ValueError("HAProxy did not return both expected backends")
    return data

def expected_ip(role):
    if role == "backhaul":
        s = Path("/etc/dual-ha/backhaul-bundle.env").read_text()
        m = re.search(r"(?m)^BH_FOREIGN_IP='(\d{1,3}(?:\.\d{1,3}){3})'$", s)
        return m.group(1) if m else ""
    m = json.loads(Path("/etc/dual-ha/bh2-experiment/state.json").read_text())
    return m["foreign_ip"] if m.get("mode") == "active" else ""

def curl(port, url, extra=(), timeout=12):
    argv = ["curl", "-q", "-4", "--noproxy", "",
            "--socks5-hostname", "127.0.0.1:" + str(port),
            "--connect-timeout", "4", "--max-time", str(timeout),
            "--retry", "0", "--max-redirs", "0", "--fail", "-sS",
            *extra, url]
    try:
        return subprocess.run(argv, capture_output=True, text=True,
                              timeout=timeout + 3)
    except (OSError, subprocess.TimeoutExpired):
        return None

def short_probe(port, expected):
    def check(item):
        url, code = item
        if url.endswith("/cdn-cgi/trace"):
            r = curl(port, url)
            return bool(r and r.returncode == 0 and
                        "ip=" + expected in r.stdout.splitlines())
        r = curl(port, url, ["-o", "/dev/null", "-w", "%{http_code}"])
        return bool(r and r.returncode == 0 and r.stdout.strip() == code)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(check, TARGETS))
    return sum(results), sum(results) >= 2

def bulk_probe(port):
    r = curl(port, BULK_URL,
             ["-o", "/dev/null", "-w",
              "%{http_code} %{size_download} %{speed_download} %{time_total}"],
             timeout=18)
    if not r or r.returncode:
        return False, {"bytes": 0, "speed_bps": 0, "reason": "timeout_or_transport_error"}
    try:
        code, downloaded, speed, seconds = r.stdout.strip().split()
        n, rate = int(float(downloaded)), float(speed)
        ok = code == "200" and n == BULK_BYTES and rate >= MIN_BULK_BYTES_PER_SECOND
        return ok, {"bytes": n, "speed_bps": round(rate),
                    "time_s": round(float(seconds), 3),
                    "reason": "ok" if ok else "slow_or_short_download"}
    except (ValueError, TypeError):
        return False, {"bytes": 0, "speed_bps": 0, "reason": "malformed_probe"}

def decision(enabled, short_ok, short_bad, bulk_bad, good, verified):
    if enabled and (short_bad >= SHORT_FALL or bulk_bad >= BULK_FALL):
        return "disable"
    if not enabled and short_ok and verified and good >= RISE:
        return "enable"
    return None

def write(data):
    path = Path(STATUS)
    temp = path.with_suffix(".json.next")
    with temp.open("w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(temp, path)

def main():
    streak = {k: {"short_bad": 0, "bulk_bad": 0, "good": 0,
                  "verified": False, "last_bulk": -1e20,
                  "bulk_ok": False, "bulk": {"reason": "not_yet_measured"}}
              for k in PATHS}
    print("DUAL_BACKHAUL_CONTROLLER: active; original HAProxy leastconn unchanged", flush=True)
    while True:
        started = time.monotonic()
        try:
            before = states()
            if not all(expected_ip(k) for k in PATHS):
                raise ValueError("Expected Backhaul IPs absent; refusing control actions")
            now = time.monotonic()
            def inspect(role):
                d = streak[role]
                passed, short_ok = short_probe(PATHS[role], expected_ip(role))
                due = now - d["last_bulk"] >= BULK_PERIOD
                bulk = bulk_probe(PATHS[role]) if due else None
                return passed, short_ok, bulk
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                results = dict(zip(PATHS, pool.map(inspect, PATHS)))
            report = {}
            for role, state in results.items():
                passed, short_ok, bulk = state
                d = streak[role]
                d["short_bad"] = 0 if short_ok else d["short_bad"] + 1
                if bulk is not None:
                    d["last_bulk"] = now
                    d["bulk_ok"], d["bulk"] = bulk
                    d["verified"] = True
                    d["bulk_bad"] = 0 if d["bulk_ok"] else d["bulk_bad"] + 1
                healthy = short_ok and d["bulk_ok"] and d["verified"]
                d["good"] = d["good"] + 1 if healthy else 0
                current = before[role]["status"]
                up = current not in ("MAINT", "UNKNOWN", "STOPPED")
                action = decision(up, short_ok, d["short_bad"], d["bulk_bad"],
                                  d["good"], d["verified"])
                if action:
                    api(action + " server dual_egress/" + role)
                    up = action == "enable"
                    print(role + " -> " + action.upper() +
                          " | short=" + str(passed) + "/3" +
                          " | bulk=" + str(d["bulk"]), flush=True)
                report[role] = {
                    "available": up, "passed_probes": passed, "total_probes": 3,
                    "latency_average_s": None, "consecutive_success": d["good"],
                    "consecutive_fail": d["short_bad"],
                    "bulk_verified": d["verified"], "bulk_pass": d["bulk_ok"],
                    "bulk_fail_streak": d["bulk_bad"],
                    "bulk_last": d["bulk"], "actual_role": "backhaul2" if role == "mieru" else "backhaul1",
                    "expected_foreign_ip": expected_ip(role),
                    "haproxy_before_action": current, "weight": before[role]["weight"],
                }
            write({"updated_utc": datetime.now(timezone.utc).isoformat(),
                   "policy": "two-backhaul-bulk-v1", "paths": report})
        except Exception as e:
            print("HEALTH WARNING (no HAProxy action): " +
                  type(e).__name__ + ": " + str(e)[:260], flush=True)
        time.sleep(max(1, SLEEP_SECONDS - (time.monotonic() - started)))

if __name__ == "__main__":
    main()
