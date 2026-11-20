#!/usr/bin/env python3
"""Maya1 dual Backhaul data-plane health controller for staged 21101 and 21102.
The historical HAProxy backend name mieru means second Backhaul.
Uses existing HAProxy leastconn, never touches transport or Xray.
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
PATHS = {"backhaul": 21101, "mieru": 21102}
EXPECTED = {"backhaul": ("bh1", "82.152.132.159"), "mieru": ("bh2", "152.237.230.77")}
MAYA1_STAGE = Path("/etc/dual-ha/maya1-next")
TARGETS = (
    ("https://www.gstatic.com/generate_204", "204"),
    ("https://www.cloudflare.com/cdn-cgi/trace", "200"),
    ("https://www.apple.com/library/test/success.html", "200"),
)
BULK_URL = "https://speed.cloudflare.com/__down?bytes=1048576"
BULK_BYTES = 1048576
# Cost-controlled deep probe: ~1 MiB x 2 paths x 2 successful samples every 5 min.
# Fast independent HTTPS checks still run every 8 seconds.
BULK_PERIOD = 300
BULK_ATTEMPTS = 3
BULK_REQUIRED_PASSES = 2
BULK_MAX_SECONDS = 12
BULK_MAX_TTFB = 8
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
    # "show stat" is a CSV table: field names and free-text cells may contain
    # "unknown" or "error" legitimately. Never string-match the entire CSV.
    if command == "show stat":
        if not answer.lstrip().startswith("# pxname,"):
            raise ValueError("Unexpected HAProxy show stat response")
        return answer
    # Mutation commands return an empty response on success, or a short
    # diagnostic on failure. Reject only explicit command-level errors.
    if any(word in answer.lower() for word in ("error", "unknown command", "no such")):
        raise ValueError("HAProxy admin command rejected: " + answer[:200])
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
                "weight": r.get("weight", "?"),
                "addr": r.get("addr", "")
            }
    if set(data) != set(PATHS):
        raise ValueError("HAProxy did not return both expected backends")
    return data

def expected_ip(role):
    """IP from Maya1 staged identity; mismatch blocks controller actions."""
    role_dir, expected = EXPECTED[role]
    m = json.loads((MAYA1_STAGE / role_dir / "state.json").read_text())
    if (m.get("iran_ip") != "94.184.4.38"
            or m.get("role") != role_dir
            or m.get("foreign_ip") != expected
            or m.get("staging_socks") != PATHS[role]
            or m.get("mode") not in ("staged", "active")):
        return ""
    return expected

def runtime_targets_match(states_by_role):
    return all(states_by_role[role].get("addr") ==
               "127.0.0.1:" + str(port)
               for role, port in PATHS.items())

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
        started = time.monotonic()
        url, code = item
        if url.endswith("/cdn-cgi/trace"):
            r = curl(port, url)
            ok = bool(r and r.returncode == 0 and
                      "ip=" + expected in r.stdout.splitlines())
        else:
            r = curl(port, url, ["-o", "/dev/null", "-w", "%{http_code}"])
            ok = bool(r and r.returncode == 0 and r.stdout.strip() == code)
        return ok, (time.monotonic() - started) if ok else None
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(check, TARGETS))
    passed = sum(int(ok) for ok, _ in results)
    good_times = [t for ok, t in results if ok]
    average = round(sum(good_times) / len(good_times), 3) if good_times else None
    return passed, passed >= 2, average

def bulk_sample(port):
    """One complete 1 MiB transfer. Avoid judging small cold requests.

    Keep strict timeout/TTFB/throughput gates and exact response length.
    Curl's speed_download uses elapsed time INCLUDING initial TTFB.
    """
    r = curl(port, BULK_URL,
             ["-o", "/dev/null", "-w",
              "%{http_code} %{size_download} %{speed_download} "
              "%{time_total} %{time_starttransfer}"],
             timeout=18)
    if not r or r.returncode:
        return False, {"bytes": 0, "speed_bps": 0,
                       "reason": "timeout_or_transport_error"}
    try:
        code, downloaded, speed, seconds, ttfb = r.stdout.strip().split()
        n, rate, elapsed, wait = (int(float(downloaded)), float(speed),
                                  float(seconds), float(ttfb))
        ok = (code == "200" and n == BULK_BYTES
              and rate >= MIN_BULK_BYTES_PER_SECOND
              and elapsed <= BULK_MAX_SECONDS and wait <= BULK_MAX_TTFB)
        return ok, {"bytes": n, "speed_bps": round(rate),
                    "time_s": round(elapsed, 3), "ttfb_s": round(wait, 3),
                    "reason": "ok" if ok else "slow_or_short_download"}
    except (ValueError, TypeError):
        return False, {"bytes": 0, "speed_bps": 0, "reason": "malformed_probe"}


def bulk_probe(port):
    """2 successes out of at most 3 consecutive 1 MiB bounded transfers.

    Stops after success or irrecoverable failure. Retain per-sample evidence so
    the control room can tell verified low throughput from unmeasured quality.
    """
    samples = []
    wins = 0
    for attempt in range(BULK_ATTEMPTS):
        good, record = bulk_sample(port)
        samples.append(record)
        wins += int(good)
        if wins >= BULK_REQUIRED_PASSES:
            break
        if wins + (BULK_ATTEMPTS - len(samples)) < BULK_REQUIRED_PASSES:
            break
    passed = wins >= BULK_REQUIRED_PASSES
    success = [r for r in samples if r.get("reason") == "ok"]
    last = samples[-1]
    summary = {
        "bytes": BULK_BYTES if passed else last.get("bytes", 0),
        "speed_bps": min(r["speed_bps"] for r in success) if success else last.get("speed_bps", 0),
        "time_s": max(r["time_s"] for r in success) if success else last.get("time_s"),
        "ttfb_s": max(r["ttfb_s"] for r in success) if success else last.get("ttfb_s"),
        "sample_count": len(samples),
        "sample_pass": wins,
        "required_pass": BULK_REQUIRED_PASSES,
        "samples": samples,
        "reason": "ok" if passed else "insufficient_1m_quality",
    }
    return passed, summary

def decision(enabled, short_ok, short_bad, bulk_bad, good, verified):
    if enabled and (short_bad >= SHORT_FALL or bulk_bad >= BULK_FALL):
        return "disable"
    if not enabled and short_ok and verified and good >= RISE:
        return "enable"
    return None

def common_bulk_probe_outage(results, streaks):
    """A shared download-test outage must not administratively drain both paths
    while their independent HTTPS/egress checks continue succeeding."""
    for name in PATHS:
        passed, short_ok, latency, bulk = results[name]
        if not short_ok:
            return False
        before = streaks[name]["bulk_bad"]
        projected = before if bulk is None else (0 if bulk[0] else before + 1)
        if projected < BULK_FALL:
            return False
    return True

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
    print("MAYA1_DUAL_BACKHAUL_CONTROLLER: active; original HAProxy leastconn unchanged", flush=True)
    while True:
        started = time.monotonic()
        try:
            before = states()
            if not all(expected_ip(k) for k in PATHS):
                raise ValueError("Expected Backhaul IPs absent; refusing control actions")
            if not runtime_targets_match(before):
                raise ValueError("HAProxy endpoints do not match Maya1 staging; refusing control actions")
            now = time.monotonic()
            def inspect(role):
                d = streak[role]
                passed, short_ok, latency = short_probe(PATHS[role], expected_ip(role))
                due = now - d["last_bulk"] >= BULK_PERIOD
                bulk = bulk_probe(PATHS[role]) if due else None
                return passed, short_ok, latency, bulk
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                results = dict(zip(PATHS, pool.map(inspect, PATHS)))
            report = {}
            shared_bulk_failure = common_bulk_probe_outage(results, streak)
            if shared_bulk_failure:
                print("BULK SHARED-ORIGIN WARNING: both HTTPS paths pass; "
                      "holding bulk-only shutdown to prevent dual false outage", flush=True)
            for role, state in results.items():
                passed, short_ok, latency, bulk = state
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
                if shared_bulk_failure and action == "disable" and d["short_bad"] < SHORT_FALL:
                    action = None
                if action:
                    api(action + " server dual_egress/" + role)
                    up = action == "enable"
                    print(role + " -> " + action.upper() +
                          " | short=" + str(passed) + "/3" +
                          " | bulk=" + str(d["bulk"]), flush=True)
                report[role] = {
                    "available": up, "passed_probes": passed, "total_probes": 3,
                    "latency_average_s": latency, "consecutive_success": d["good"],
                    "consecutive_fail": d["short_bad"],
                    "bulk_verified": d["verified"], "bulk_pass": d["bulk_ok"],
                    "shared_bulk_probe_outage": shared_bulk_failure,
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

def diagnose():
    """Read-only preview. Do not send enable/disable commands to production HAProxy."""
    import sys
    try:
        print("Controller read-only diagnostics: no HAProxy changes", flush=True)
        live = states()
        results = {"runtime_targets_match": runtime_targets_match(live)}
        for role, port in PATHS.items():
            ip = expected_ip(role)
            if not ip:
                raise RuntimeError("Missing expected foreign IP for " + role)
            passed, ok, avg = short_probe(port, ip)
            bulk_ok, bulk = bulk_probe(port)
            results[role] = {
                "foreign_ip": ip, "http_probes": passed, "https_healthy": ok,
                "latency_s": avg, "bulk_ok": bulk_ok, "bulk": bulk,
                "haproxy_state": live[role]
            }
        print(json.dumps(results, indent=2), flush=True)
        if not all(results[r]["https_healthy"] and results[r]["bulk_ok"] for r in PATHS):
            raise RuntimeError("One or more paths failed read-only probe")
        return 0
    except Exception as e:
        print("DIAGNOSTIC FAILURE: " + repr(e), file=sys.stderr, flush=True)
        return 1

if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["--diagnose"]:
        sys.exit(diagnose())
    if sys.argv[1:]:
        print("Usage: dual-backhaul-controller.py [--diagnose]", file=sys.stderr)
        sys.exit(2)
    main()
