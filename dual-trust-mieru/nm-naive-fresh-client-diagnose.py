#!/usr/bin/env python3
"""Diagnose live Naive SOCKS against a fresh isolated Naive client.

No production restarts, route/firewall edits, or credential printing.
Runs a temporary client on loopback :17993 only, then stops only that client.
"""
import argparse
import collections
import concurrent.futures
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

LIVE_CONFIG = pathlib.Path("/etc/dual-trust-mieru/naive-mieru/naive-live.json")
NAIVE_BIN = pathlib.Path("/usr/local/lib/dual-trust-mieru/naive")
FOREIGN_BUNDLE = pathlib.Path("/etc/dual-trust-mieru/naive-mieru/bundle.json")
NEW_PORT = 17993
PRODUCTION_SERVICES = (
    "x-ui", "dual-dispatcher", "dual-xudp-bridge",
    "nm-naive-client", "dual-mieru-carrier"
)
PATHS = (("LIVE_NAIVE", 7993), ("FRESH_NAIVE", NEW_PORT), ("MIERU", 7994))
TARGET = "https://www.gstatic.com/generate_204"


def service_state():
    result = {}
    for svc in PRODUCTION_SERVICES:
        p = subprocess.run(["systemctl", "show", svc + ".service",
                            "-p", "ActiveState", "-p", "MainPID", "-p", "NRestarts"],
                           capture_output=True, text=True, timeout=5)
        if p.returncode:
            raise RuntimeError("Cannot inspect " + svc)
        kv = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
        result[svc] = kv
    return result


def port_available(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1", port))
        except OSError:
            return False
        return True


def new_client_ready(p):
    for _ in range(60):
        if p.poll() is not None:
            raise RuntimeError("fresh Naive process exited prematurely")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.2)
            if s.connect_ex(("127.0.0.1", NEW_PORT)) == 0:
                return
        time.sleep(0.1)
    raise RuntimeError("fresh Naive SOCKS localhost listener failed")


def curl_check(item):
    name, port = item
    p = subprocess.run(
        ["curl", "-q", "-4", "-sS",
         "--socks5-hostname", "127.0.0.1:" + str(port),
         "--connect-timeout", "6", "--max-time", "10",
         "-o", "/dev/null", "-w", "%{http_code}|%{time_total}", TARGET],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=15,
        env={k: v for k, v in os.environ.items()
             if k.lower() not in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")})
    fields = p.stdout.strip().split("|")
    code = fields[0] if fields else "000"
    try:
        seconds = float(fields[1])
    except (ValueError, IndexError):
        seconds = -1
    return name, p.returncode == 0 and code == "204", p.returncode, code, seconds


def stats_for_pid(pid):
    try:
        fd_count = len(os.listdir("/proc/" + str(pid) + "/fd"))
        p = subprocess.run(
            ["ps", "-p", str(pid), "-o", "nlwp=,rss=,%cpu="],
            capture_output=True, text=True, timeout=3)
        return "fds=" + str(fd_count) + " threads,rss_kib,cpu=" + p.stdout.strip()
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return "process statistics unavailable"


def main():
    parser = argparse.ArgumentParser(description="Compare live Naive, fresh isolated Naive and Mieru without live restarts")
    parser.add_argument("--rounds", type=int, default=36, help="number of rounds, 3..60 (default: 36)")
    parser.add_argument("--gap", type=float, default=7.0, help="minimum interval between round starts, 0.5..30 sec")
    args = parser.parse_args()
    if not 3 <= args.rounds <= 60 or not 0.5 <= args.gap <= 30:
        parser.error("rounds must be 3..60 and gap must be 0.5..30 seconds")
    if os.geteuid() != 0:
        raise SystemExit("Run as root")
    before = service_state()
    if any(x["ActiveState"] != "active" for x in before.values()):
        raise SystemExit("Refusing: protected production service is not active")
    if not port_available(NEW_PORT):
        raise SystemExit("Refusing: candidate :17993 occupied")
    if not NAIVE_BIN.is_file() or not os.access(NAIVE_BIN, os.X_OK):
        raise SystemExit("Naive executable unavailable")
    if not LIVE_CONFIG.is_file() or not FOREIGN_BUNDLE.is_file():
        raise SystemExit("Verified Naive config/bundle unavailable")
    live = json.loads(LIVE_CONFIG.read_text())
    if live.get("listen") != "socks://127.0.0.1:7993":
        raise SystemExit("Unexpected live listener; refusing")
    if not str(live.get("proxy", "")).startswith("https://"):
        raise SystemExit("Unexpected proxy transport; refusing")
    new = dict(live)
    new["listen"] = "socks://127.0.0.1:" + str(NEW_PORT)
    stats = collections.defaultdict(lambda: {"PASS": 0, "FAIL": 0, "seconds": []})
    proc = None
    print("=== ISOLATED FRESH NAIVE DIFFERENTIAL TEST ===", flush=True)
    print("Production :7993/:7991/:7990 unchanged; isolated candidate :17993", flush=True)
    print(f"Sampling {args.rounds} rounds, interval at least {args.gap}s; no production service modifications", flush=True)
    with tempfile.TemporaryDirectory(prefix="nm-client-check-", dir="/run") as directory:
        os.chmod(directory, 0o700)
        cfg = pathlib.Path(directory) / "fresh-naive.json"
        fd = os.open(cfg, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(new, f)
        try:
            proc = subprocess.Popen(
                [str(NAIVE_BIN), str(cfg)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
            new_client_ready(proc)
            live_pid = int(before["nm-naive-client"]["MainPID"])
            print("Fresh isolated client ready. PID=", proc.pid, flush=True)
            print("Live client resources:", stats_for_pid(live_pid), flush=True)
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                for n in range(1, args.rounds + 1):
                    started = time.monotonic()
                    checks = list(pool.map(curl_check, PATHS))
                    slow_or_failed = any(not ok or secs >= 3 for _, ok, _, _, secs in checks)
                    for name, ok, rc, http, seconds in checks:
                        row = stats[name]
                        row["PASS" if ok else "FAIL"] += 1
                        if ok:
                            row["seconds"].append(seconds)
                    if slow_or_failed:
                        print("ROUND", n, " ".join(
                            "{}={}/HTTP{}/rc{}/{}s".format(
                                name, "PASS" if ok else "FAIL", http, rc, round(seconds, 2))
                            for name, ok, rc, http, seconds in checks),
                            flush=True)
                        if not checks[0][1]:
                            print("Live client:", stats_for_pid(live_pid), flush=True)
                            print("Fresh client:", stats_for_pid(proc.pid), flush=True)
                    elif n % 6 == 0:
                        print("completed", n, "/", args.rounds, flush=True)
                    if n < args.rounds:
                        time.sleep(max(0, args.gap - (time.monotonic() - started)))
        finally:
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=4)
            print("ISOLATED CLIENT STOPPED; temp config removed on exit", flush=True)

    print("\n=== SUMMARY ===")
    for name, _ in PATHS:
        row = stats[name]
        values = row["seconds"]
        avg = round(sum(values)/len(values), 3) if values else "N/A"
        print("{} PASS={}/{} FAIL={} AVG_SUCCESS={}s".format(
            name, row["PASS"], args.rounds, row["FAIL"], avg))
    after = service_state()
    changes = [svc for svc in PRODUCTION_SERVICES if
               before[svc]["MainPID"] != after[svc]["MainPID"]]
    print("PRODUCTION PROCESS PID CHANGES:", changes if changes else "NONE")
    print("READ-ONLY production; no reconfiguration, no restarts of protected services")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print("DIAGNOSTIC ABORTED:", type(exc).__name__, str(exc), file=sys.stderr)
        sys.exit(1)
