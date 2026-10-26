#!/usr/bin/env python3
"""Adaptive Naive/Mieru 50/50 BYTE balancing model.

READ-ONLY Mihomo snapshots; no configuration writes or management API mutations.
All upstream session choices must be made at connection start, never mid-stream.
"""
import collections
import json
import math
import os
import pathlib
import time
import urllib.request

ROLES = ("NAIVE", "MIERU")
MATCHES = {"XUDP-TRUST": "NAIVE", "XUDP-NAIVE": "NAIVE", "XUDP-MIERU": "MIERU"}
STATE = pathlib.Path("/var/lib/dual-trust-mieru/naive-mieru/adaptive")
SECRET = pathlib.Path("/etc/dual-trust-mieru/iran/controller.secret")
CONTROLLER = "http://127.0.0.1:19090"


def roles_from_chain(chains):
    matches = {MATCHES[name] for name in (chains or []) if name in MATCHES}
    return matches.pop() if len(matches) == 1 else "OTHER"


class CounterSampler:
    """Snapshots of active connections. Drops that finish between polls are unknowable."""
    def __init__(self):
        self.previous = None

    def sample(self, entries):
        now = {}
        delta = {role: 0 for role in ROLES}
        new_counts = {role: 0 for role in ROLES}
        for item in entries:
            ident = item.get("id")
            if not isinstance(ident, str) or not ident:
                continue
            role = roles_from_chain(item.get("chains"))
            if role == "OTHER":
                continue
            stamp = item.get("start") or ""
            key = (ident, stamp)
            up, down = item.get("upload", 0), item.get("download", 0)
            if not all(isinstance(x, (int, float)) and not isinstance(x, bool)
                       and math.isfinite(x) and x >= 0 for x in (up, down)):
                continue
            value = int(up) + int(down)
            if key in now:
                # unexpected duplicate ID: never count it twice
                continue
            now[key] = (role, value)
            if self.previous is None:
                continue  # baseline; exclude all historical bytes
            before = self.previous.get(key)
            if before and before[0] == role:
                delta[role] += max(0, value - before[1])
            else:
                # The accumulated counter predates first observation.
                # Do not import unknown historic bytes into the live window.
                # The next consecutive observation can safely contribute deltas.
                new_counts[role] += 1
        self.previous = now
        return delta, new_counts, {r: sum(x[0] == r for x in now.values()) for r in ROLES}


class RollingTraffic:
    def __init__(self, seconds=600):
        self.seconds = seconds
        self.samples = collections.deque()

    def add(self, when, delta):
        self.samples.append((when, dict(delta)))
        self.trim(when)

    def trim(self, now):
        while self.samples and self.samples[0][0] <= now - self.seconds:
            self.samples.popleft()

    def totals(self, now=None):
        if now is not None:
            self.trim(now)
        return {r: sum(row.get(r, 0) for _, row in self.samples) for r in ROLES}

    def span(self):
        if not self.samples:
            return 0
        return self.samples[-1][0] - self.samples[0][0]


def policy(traffic, healthy, span_seconds, telemetry_fresh=True):
    """Bounded steering (20..80%) derived from bytes, not a claim of exact 50/50."""
    n, m = traffic.get("NAIVE", 0), traffic.get("MIERU", 0)
    total = n + m
    if not telemetry_fresh:
        return {"NAIVE": 0.5, "MIERU": 0.5}, "STALE_TELEMETRY"
    if not healthy["NAIVE"] and not healthy["MIERU"]:
        return {"NAIVE": 0.0, "MIERU": 0.0}, "NO_HEALTHY_CARRIER"
    if not healthy["NAIVE"]:
        return {"NAIVE": 0.0, "MIERU": 1.0}, "NAIVE_UNHEALTHY"
    if not healthy["MIERU"]:
        return {"NAIVE": 1.0, "MIERU": 0.0}, "MIERU_UNHEALTHY"
    if span_seconds < 120 or total < 1024 * 1024:
        return {"NAIVE": 0.5, "MIERU": 0.5}, "WARMUP"
    observed = n / total
    # Proportional feedback. Smooth and bound decisions; no more than 80% preference.
    target = min(0.8, max(0.2, 0.5 + (0.5 - observed) * 1.0))
    return {"NAIVE": round(target, 4), "MIERU": round(1 - target, 4)}, "ADAPTIVE"



def shadow_policy(traffic, controller_flags, span_seconds):
    """Do NOT infer eligibility from a negative Controller flag alone.

    Under lazy health checking a flag can disagree with forced-path probes.
    Without independent verified health, halt CANARY decisions rather than
    silently route 100% toward the other carrier. Production is untouched.
    """
    if any(controller_flags.get(role) is not True for role in ROLES):
        return {role: 0.0 for role in ROLES}, "HEALTH_UNVERIFIED"
    return policy(traffic, controller_flags, span_seconds)


class SmoothChooser:
    """Deterministic weighted distribution; only choose on new SOCKS connections."""
    def __init__(self):
        self.credit = 0.0

    def choose(self, weights):
        naive = max(0.0, min(1.0, weights.get("NAIVE", 0)))
        mieru = max(0.0, min(1.0, weights.get("MIERU", 0)))
        if naive + mieru == 0:
            return None
        if naive == 0:
            return "MIERU"
        if mieru == 0:
            return "NAIVE"
        self.credit += naive / (naive + mieru)
        if self.credit >= 1 - 1e-9:
            self.credit = max(0.0, self.credit - 1)
            return "NAIVE"
        return "MIERU"


def controller_get(path):
    secret = SECRET.read_text().strip()
    req = urllib.request.Request(
        CONTROLLER + path,
        headers={"Authorization": "Bearer " + secret})
    with urllib.request.urlopen(req, timeout=7) as response:
        return json.load(response)


def capture():
    data = controller_get("/connections")
    if not isinstance(data.get("connections"), list):
        raise ValueError("Mihomo /connections missing connections array")
    alive = {}
    for tag, role in (("XUDP-TRUST", "NAIVE"), ("XUDP-MIERU", "MIERU")):
        node = controller_get("/proxies/" + tag)
        alive[role] = node.get("alive") is True
    return data["connections"], alive


def atomic_status(path, status):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.with_name("." + path.name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(status, f, separators=(",", ":"), sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def display(status):
    data = status["bytes_10m"]
    total = data["NAIVE"] + data["MIERU"]
    shares = (f"Naive={100*data['NAIVE']/total:.1f}% "
              f"Mieru={100*data['MIERU']/total:.1f}%") if total else "Naive=N/A Mieru=N/A"
    flags = status.get("controller_alive", status.get("healthy", {}))
    health_line = (f"controller_alive=NAIVE:{flags.get('NAIVE', 'unknown')}"
                   f",MIERU:{flags.get('MIERU', 'unknown')}")
    return (f"window={status['window_seconds']}s coverage={status.get('coverage_seconds', 0)}s "
            f"observed={total/1048576:.1f} MiB; {shares}; "
            f"next_connection_weights={status['weights']['NAIVE']:.0%}/"
            f"{status['weights']['MIERU']:.0%}; {status['reason']}; "
            f"{health_line}")


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--window-seconds", type=int, default=600)
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()
    path = STATE / "status.json"
    if args.status:
        if not path.exists():
            print("NO SHADOW STATUS YET")
            return
        st = json.loads(path.read_text())
        print("SAMPLE AGE:", round(time.time() - st["timestamp"]), "seconds")
        print(display(st))
        print("Observed deltas only; first-seen cumulative bytes excluded. Short flows may be missed.")
        return
    if not args.run:
        parser.error("specify --run or --status")
    if not (2 <= args.window_seconds <= 3600 and 1 <= args.interval <= 10):
        parser.error("invalid interval/window")
    sampler = CounterSampler()
    rolling = RollingTraffic(seconds=args.window_seconds)
    health = {"NAIVE": False, "MIERU": False}
    prev_time = None
    failures = 0
    print("ADAPTIVE SHADOW started; ONLY GET /connections and GET /proxies. No routing changes.", flush=True)
    while True:
        now = time.monotonic()
        wall = time.time()
        try:
            entries, health = capture()
            delta, new_counts, active = sampler.sample(entries)
            failures = 0
            rolling.add(now, delta)
            prev_time = now
            healthy = dict(health)
            weights, reason = shadow_policy(rolling.totals(now), healthy, rolling.span())
            st = {
                "schema": 1,
                "timestamp": wall,
                "window_seconds": args.window_seconds,
                "coverage_seconds": round(rolling.span(), 1),
                "bytes_10m": rolling.totals(now),
                "active_connections": active,
                "newly_seen_last_poll": new_counts,
                "healthy": healthy,
                "controller_alive": dict(healthy),
                "weights": weights,
                "reason": reason,
                "routing_mode": "SHADOW_ONLY",
                "caveat": "first-seen accumulated bytes are excluded; short flows missed; not wire bytes"
            }
            atomic_status(path, st)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            failures += 1
            # No stale 'healthy' data on read/API errors; do not make routing decisions.
            st = {
                "schema": 1, "timestamp": wall, "window_seconds": args.window_seconds,
                "coverage_seconds": round(rolling.span(), 1),
                "bytes_10m": rolling.totals(now),
                "active_connections": {"NAIVE": 0, "MIERU": 0},
                "newly_seen_last_poll": {"NAIVE": 0, "MIERU": 0},
                "healthy": {"NAIVE": False, "MIERU": False},
                "controller_alive": {"NAIVE": None, "MIERU": None},
                "weights": {"NAIVE": 0.0, "MIERU": 0.0},
                "reason": "CONTROLLER_ERROR",
                "routing_mode": "SHADOW_ONLY",
                "caveat": "telemetry unavailable; do not apply controller decisions"
            }
            atomic_status(path, st)
            print("SHADOW WARNING controller error:", type(exc).__name__, "failures=", failures, flush=True)
            # Do NOT call systemctl, restart, or modify any network rules.
        time.sleep(max(0.0, args.interval - (time.monotonic() - now)))


if __name__ == "__main__":
    main()
