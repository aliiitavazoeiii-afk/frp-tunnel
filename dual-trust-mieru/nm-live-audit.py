#!/usr/bin/env python3
"""Read-only live Naive/Mieru audit on the NEW Iran dispatcher.

Samples connection lifetime counters (not wire counters) and new-flow selection.
Does not write to Mihomo controller, change routing, reload or restart services.
"""
import argparse
import collections
import json
import math
import pathlib
import statistics
import subprocess
import sys
import time
import urllib.request

SECRET = pathlib.Path("/etc/dual-trust-mieru/iran/controller.secret")
API = "http://127.0.0.1:19090"
ROLES = ("NAIVE", "MIERU")
MEMBERS = {"XUDP-TRUST": "NAIVE", "XUDP-NAIVE": "NAIVE",
           "XUDP-MIERU": "MIERU"}


def role_of(conn):
    names = conn.get("chains")
    if not isinstance(names, list):
        return "OTHER"
    found = {MEMBERS[n] for n in names if isinstance(n, str) and n in MEMBERS}
    return found.pop() if len(found) == 1 else "OTHER"


def traffic_counter(conn):
    a, b = conn.get("upload"), conn.get("download")
    if not all(isinstance(x, (int, float)) and not isinstance(x, bool)
               and math.isfinite(x) and x >= 0 for x in (a, b)):
        return None
    return int(a), int(b)


def inspect(items):
    if not isinstance(items, list):
        raise ValueError("Mihomo /connections payload has no connections list")
    result = {}
    for c in items:
        if not isinstance(c, dict):
            continue
        ident = c.get("id")
        if not isinstance(ident, str) or not ident:
            continue
        counter = traffic_counter(c)
        if counter is None:
            continue
        key = (ident, str(c.get("start") or ""))
        result[key] = (role_of(c), counter[0], counter[1])
    return result


class DeltaMeter:
    def __init__(self):
        self.prev = None
        self.seen = set()
        self.new = collections.Counter()
        self.up = collections.Counter()
        self.down = collections.Counter()
        self.active_peak = collections.Counter()
        self.snapshots = 0
        self.missed = 0

    def push(self, payload):
        cur = inspect(payload)
        self.snapshots += 1
        counts = collections.Counter(role for role, _, _ in cur.values())
        for role in (*ROLES, "OTHER"):
            self.active_peak[role] = max(self.active_peak[role], counts[role])
        if self.prev is not None:
            for key, (role, up, down) in cur.items():
                if key not in self.seen:
                    self.new[role] += 1
                old = self.prev.get(key)
                if old and old[0] == role:
                    self.up[role] += max(0, up-old[1])
                    self.down[role] += max(0, down-old[2])
                # First sight is excluded from byte totals, as those bytes
                # may have transferred before the observation window.
            self.missed += len(set(self.prev)-set(cur))
        self.seen.update(cur)
        self.prev = cur
        return counts


def percent(a, b):
    return f"{100*a/(a+b):.1f}%" if a+b else "N/A"


def mib(n):
    return f"{n/1048576:.2f} MiB"


def query(path, timeout=6):
    token = SECRET.read_text().strip()
    req = urllib.request.Request(API+path, headers={"Authorization": "Bearer "+token})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def health_meta():
    try:
        group = query("/proxies/DUAL")
        roles = set(group.get("all") or [])
        print("Pool members:", ", ".join(sorted(roles)) or "(none)")
        print("Expected 2 branches:", "YES" if (
            "XUDP-MIERU" in roles and
            ("XUDP-TRUST" in roles or "XUDP-NAIVE" in roles)) else "NO / INVESTIGATE")
    except Exception as exc:
        print("Pool metadata: unavailable ("+type(exc).__name__+")")
    for tag in ("XUDP-TRUST", "XUDP-MIERU"):
        try:
            node = query("/proxies/"+tag)
            print(f"Controller flag {tag} alive={node.get('alive','unknown')} "
                  "(indicator only; not proof of user experience)")
        except Exception as exc:
            print(f"Controller flag {tag}: unavailable ({type(exc).__name__})")


def probe(port):
    cmd = ("curl", "-q", "-4", "-sS", "--socks5-hostname", f"127.0.0.1:{port}",
           "--connect-timeout", "3", "--max-time", "8", "-o", "/dev/null",
           "-w", "%{http_code} %{time_total}", "https://www.gstatic.com/generate_204")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        bits = result.stdout.strip().split()
        if len(bits) == 2 and result.returncode == 0 and bits[0] == "204":
            return float(bits[1])
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


def summarize_probes(rounds):
    print("\n=== SYNTHETIC FULL-PATH LATENCY (HTTP 204, not Instagram/Reels) ===", flush=True)
    results = {7991: [], 7992: []}
    for k in range(rounds):
        for port in (7991, 7992):
            results[port].append(probe(port))
        if k < rounds-1:
            time.sleep(0.35)
    for port, name in ((7991, "NAIVE"), (7992, "MIERU")):
        vals = sorted(x for x in results[port] if x is not None)
        bad = rounds-len(vals)
        if vals:
            p95 = vals[max(0, math.ceil(0.95*len(vals))-1)]
            print(f"{name:6} :{port} PASS={len(vals)}/{rounds} "
                  f"AVG={statistics.mean(vals):.3f}s P95={p95:.3f}s "
                  f"MAX={max(vals):.3f}s FAIL={bad}")
        else:
            print(f"{name:6} :{port} PASS=0/{rounds} FAIL={bad}")
    print("A clean HTTP result does not rule out real-user stalls or UDP/XUDP problems.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--interval", type=float, default=2)
    ap.add_argument("--http-rounds", type=int, default=6)
    args = ap.parse_args()
    if not 10 <= args.seconds <= 300:
        ap.error("seconds must be 10..300")
    if not 1 <= args.interval <= 10:
        ap.error("interval must be 1..10")
    if not 0 <= args.http_rounds <= 12:
        ap.error("http-rounds must be 0..12")
    print("=== NAIVE / MIERU LIVE AUDIT: READ ONLY ===", flush=True)
    print("Sampling period:", args.seconds, "seconds; interval:", args.interval)
    print("NO proxy changes, controller writes, restarts or firewall changes.")
    health_meta()
    meter = DeltaMeter()
    try:
        first = query("/connections")
        counts = meter.push(first["connections"])
        print("ACTIVE BASELINE:", dict(counts), flush=True)
        started = time.monotonic()
        until = started + args.seconds
        next_progress = started + 30
        while True:
            remain = until-time.monotonic()
            if remain <= 0:
                break
            time.sleep(min(args.interval, remain))
            now = query("/connections")
            current_counts = meter.push(now["connections"])
            tick = time.monotonic()
            if tick >= next_progress and tick < until:
                elapsed = min(args.seconds, round(tick - started))
                print(f"PROGRESS {elapsed}/{args.seconds}s "
                      f"active: NAIVE={current_counts['NAIVE']} "
                      f"MIERU={current_counts['MIERU']}; "
                      f"new observed: NAIVE={meter.new['NAIVE']} "
                      f"MIERU={meter.new['MIERU']}", flush=True)
                next_progress += 30
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print("AUDIT INCOMPLETE: cannot access live Mihomo stats:",type(exc).__name__, file=sys.stderr)
        raise SystemExit(2)
    active = collections.Counter(role for role, _, _ in meter.prev.values())
    n, m = meter.new["NAIVE"], meter.new["MIERU"]
    nu, mu = meter.up["NAIVE"], meter.up["MIERU"]
    nd, md = meter.down["NAIVE"], meter.down["MIERU"]
    print("\n=== OBSERVED LIVE ROUTING ===")
    print(f"Snapshots: {meter.snapshots} (fast connections between polls can be missed)")
    print(f"ACTIVE NOW: Naive={active['NAIVE']} Mieru={active['MIERU']} "
          f"Other/Unclassified={active['OTHER']}")
    print(f"ACTIVE SHARE: Naive={percent(active['NAIVE'],active['MIERU'])} "
          f"Mieru={percent(active['MIERU'],active['NAIVE'])} "
          "(concurrency, NOT users)")
    print(f"NEWLY OBSERVED CONNECTIONS: Naive={n} Mieru={m} Other={meter.new['OTHER']}")
    print(f"NEW CONNECTION SHARE: Naive={percent(n,m)} Mieru={percent(m,n)}")
    print(f"UPLOADED DELTAS: Naive={mib(nu)} Mieru={mib(mu)} "
          f"NaiveShare={percent(nu,mu)}")
    print(f"DOWNLOADED DELTAS: Naive={mib(nd)} Mieru={mib(md)} "
          f"NaiveShare={percent(nd,md)}")
    print(f"TOTAL SAMPLED BYTES: Naive={mib(nu+nd)} Mieru={mib(mu+md)} "
          f"NaiveShare={percent(nu+nd,mu+md)}")
    if n+m < 30:
        print("CAUTION: fewer than 30 new observed flows; share is statistically noisy.")
    if n+m:
        share=n/(n+m)
        if abs(share-.5)>0.15 and n+m>=30:
            print("NOTICE: New-flow split differs from 50/50 by >15 percentage points.")
            print("Check health flags, existing sticky streams and real traffic before changes.")
        else:
            print("New-flow balance: no material skew established by this sample.")
    if meter.new["OTHER"] > 0 or active["OTHER"] > 0:
        print("CAUTION: unclassified chains omitted from Naive/Mieru percentage.")
    print("Byte deltas are active Mihomo connection counters, not total NIC/wire traffic.")
    print("First-observed accumulated bytes and flows entirely between snapshots are excluded.")
    if args.http_rounds:
        summarize_probes(args.http_rounds)
    print("\nAUDIT COMPLETE: no configuration or service modifications.")


if __name__ == "__main__":
    main()
