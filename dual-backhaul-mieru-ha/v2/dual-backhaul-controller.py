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
# Three independent HTTPS destinations per lane, every ten minutes.
# On a suspicious result, confirm again after 20 seconds before changing routing.
CHECK_PERIOD = 600
CONFIRM_DELAY = 20
POLICY = "two-backhaul-3site-10m-v3"
SLEEP_SECONDS = 8  # legacy constant; v3 scheduling uses CHECK_PERIOD
MIN_BULK_BYTES_PER_SECOND = 96 * 1024
SHORT_FALL = 2  # confirmation rounds, NOT a speed threshold
BULK_FALL = 2  # advisory counter; speed checks never drain a backend
RISE = 2  # confirmation rounds for an administratively disabled lane

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

def decision(enabled, short_ok, short_bad, bulk_bad, good, verified,
             peer_enabled=False, peer_short_ok=False):
    """Only two confirmed independent HTTPS rounds can alter routing.

    The bulk/throughput parameters are intentionally ignored. If both paths
    are unwell, preserve the current HAProxy routing to avoid dual MAINT.
    """
    if not enabled and short_ok and good >= RISE:
        return "enable"
    if (enabled and not short_ok and short_bad >= SHORT_FALL
            and peer_enabled and peer_short_ok):
        return "disable"
    return None

def is_enabled(row):
    """Source of truth is HAProxy live status and positive server weight."""
    try:
        return str(row["status"]).startswith("UP") and int(row["weight"]) > 0
    except (ValueError,TypeError,KeyError):
        return False

def three_site_probe(port, expected):
    """Probe Google, Cloudflare and Apple concurrently; return individual results.

    Do not fetch any bulk data. 2 successes out of 3 count as working; 0-1
    successes trigger a confirmation round, never an immediate drain.
    """
    labels=("google","cloudflare","apple")
    def check(index):
        url,code=TARGETS[index]
        began=time.monotonic()
        if index == 1:
            result=curl(port,url,timeout=12)
            good=bool(result and result.returncode==0 and
                      "ip="+expected in result.stdout.splitlines())
        else:
            result=curl(port,url,["-o","/dev/null","-w","%{http_code}"],timeout=12)
            good=bool(result and result.returncode==0 and result.stdout.strip()==code)
        return labels[index],good,round(time.monotonic()-began,3)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        measurements=list(pool.map(check,range(3)))
    successes=sum(1 for _,ok,_ in measurements if ok)
    timings=[t for _,ok,t in measurements if ok]
    avg=round(sum(timings)/len(timings),3) if timings else None
    return successes, successes>=2, avg, {k:{"ok":ok,"elapsed_s":t}
            for k,ok,t in measurements}

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
    print("MAYA3_THREE_SITE_10MIN_CONTROLLER: live; bulk never drains routes",flush=True)
    while True:
        started=time.monotonic()
        try:
            before=states()
            identity={r:expected_ip(r) for r in PATHS}
            if not all(identity.values()):
                raise ValueError("Missing expected Backhaul egress identities; no actions")
            if any(before[r].get("addr") != "127.0.0.1:"+str(PATHS[r])
                   for r in PATHS):
                raise ValueError("Maya3 HAProxy backend targets not 21001/21002")
            def sample(role):
                return three_site_probe(PATHS[role],identity[role])
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                first=dict(zip(PATHS,pool.map(sample,PATHS)))

            # Recheck BOTH lanes only if a lane looks unhealthy or is drained.
            # Avoid treating two checks seconds apart as independent on success.
            should_confirm=any(not first[r][1] or not is_enabled(before[r])
                               for r in PATHS)
            second=first
            if should_confirm:
                time.sleep(CONFIRM_DELAY)
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    second=dict(zip(PATHS,pool.map(sample,PATHS)))

            report={}
            for role in PATHS:
                peer=next(k for k in PATHS if k!=role)
                enabled=is_enabled(before[role])
                first_ok=first[role][1]
                last=second[role]
                last_ok=last[1]
                # Two *real* rounds required for a routing decision.
                confirmed_bad=(should_confirm and not first_ok and not last_ok)
                confirmed_good=(should_confirm and first_ok and last_ok)
                peer_good=(first[peer][1] and second[peer][1])
                action=decision(enabled,last_ok,2 if confirmed_bad else 0,0,
                                2 if confirmed_good else 0,True,
                                peer_enabled=is_enabled(before[peer]),
                                peer_short_ok=peer_good)
                if action:
                    api(action+" server dual_egress/"+role)
                    print(role+" -> "+action.upper()+
                          " | confirmed HTTPS "+str(first[role][0])+"/3 and "+
                          str(last[0])+"/3 | peer="+str(peer_good),flush=True)
                # Read back actual routing after control action, not presumed state.
                report[role]={
                    "available": enabled if not action else action=="enable",
                    "routing_enabled": enabled if not action else action=="enable",
                    "connectivity_healthy": last_ok,
                    "passed_probes": last[0],"total_probes":3,
                    "https_checks": last[3],
                    "latency_average_s":last[2],
                    "consecutive_success":2 if confirmed_good else int(last_ok),
                    "consecutive_fail":2 if confirmed_bad else int(not last_ok),
                    "warning": not last_ok,
                    "confirmed_failure":confirmed_bad,
                    "confirmation_performed":should_confirm,
                    "bulk_verified":False,"bulk_pass":None,
                    "bulk_fail_streak":0,
                    "bulk_last":{"reason":"not_used_by_v3"},
                    "quality_warning":False,
                    "actual_role":"backhaul2" if role=="mieru" else "backhaul1",
                    "expected_foreign_ip":identity[role],
                    "haproxy_before_action":before[role]["status"],
                    "weight":before[role]["weight"],
                }
            after=states()
            for role in PATHS:
                report[role]["available"]=is_enabled(after[role])
                report[role]["routing_enabled"]=is_enabled(after[role])
                report[role]["haproxy_after_action"]=after[role]["status"]
            write({"updated_utc":datetime.now(timezone.utc).isoformat(),
                   "policy":POLICY,
                   "check_interval_s":CHECK_PERIOD,
                   "confirm_delay_s":CONFIRM_DELAY,
                   "targets":["Google","Cloudflare","Apple"],
                   "paths":report})
            print("THREE_SITE_CHECK MAYA3",
                  "first="+str({r:first[r][0] for r in PATHS}),
                  "last="+str({r:second[r][0] for r in PATHS}),
                  "live="+str({r:after[r]["status"] for r in PATHS}),flush=True)
        except Exception as e:
            print("HEALTH WARNING (no further HAProxy action): "+
                  type(e).__name__+": "+str(e)[:260],flush=True)
        time.sleep(max(1,CHECK_PERIOD-(time.monotonic()-started)))


def diagnose():
    """Read-only preview. Do not send enable/disable commands to production HAProxy."""
    import sys
    try:
        print("Controller read-only diagnostics: no HAProxy changes", flush=True)
        live = states()
        results = {}
        for role, port in PATHS.items():
            ip = expected_ip(role)
            if not ip:
                raise RuntimeError("Missing expected foreign IP for " + role)
            passed, ok, avg, sites = three_site_probe(port, ip)
            results[role] = {
                "foreign_ip": ip, "http_probes": passed, "https_healthy": ok,
                "latency_s": avg, "sites": sites,
                "haproxy_state": live[role]
            }
        print(json.dumps(results, indent=2), flush=True)
        if not all(r["https_healthy"] for r in results.values()):
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
