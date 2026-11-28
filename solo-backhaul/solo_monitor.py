#!/usr/bin/env python3
"""Monitor REALITY end-to-end via local Xray CLIENT SOCKS inbounds.

One per-Maya test every 60s; failover only after two consecutive failed
minute-spaced rounds. By default this tool OBSERVES and never switches.
Action requires BOTH --armed and an operator-owned approval marker, as well
as a validated command installed independently on the control host.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

MARKER = Path("/etc/solo-backhaul/AUTOMATION_APPROVED")
STATE_PATH = Path("/var/lib/solo-backhaul/monitor-state.json")
TRACE = "https://www.cloudflare.com/cdn-cgi/trace"
MAX_NODES = 3

def utc():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")

class Guard(RuntimeError):
    pass

def ensure(cond, reason):
    if not cond:
        raise Guard(reason)

def config_file(path):
    stat = path.stat()
    ensure(stat.st_uid == 0 and stat.st_mode & 0o077 == 0,
           "Config must be root-owned and mode 0600")
    d = json.loads(path.read_text())
    ensure(d.get("interval_seconds") == 60, "interval_seconds must be exactly 60")
    nodes = d.get("nodes")
    ensure(isinstance(nodes, list) and 1 <= len(nodes) <= MAX_NODES,
           "Configure 1..3 Maya nodes")
    ids = set()
    ports = set()
    for node in nodes:
        name, port = node.get("id"), node.get("socks_port")
        ensure(name in ("maya1", "maya3", "maya4") and name not in ids,
               "Node identity must be unique and recognized")
        ensure(isinstance(port, int) and 1024 <= port <= 65535 and port not in ports,
               "Local Xray CLIENT SOCKS port invalid/duplicated")
        ips = (node.get("primary_egress_ip"), node.get("standby_egress_ip"))
        ensure(all(isinstance(x, str) and re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", x) for x in ips),
               "Both expected REALITY egress IPv4 values are required")
        command = node.get("switch_command")
        if command is not None:
            ensure(isinstance(command, list) and 1 <= len(command) <= 12
                   and all(isinstance(x, str) and 0 < len(x) < 512 for x in command)
                   and command[0].startswith("/"),
                   "switch_command must be a fixed absolute-path argv array")
        ids.add(name)
        ports.add(port)
    return d

def probe(port, timeout=16):
    args = ["curl", "-q", "-4", "--noproxy", "",
            "--socks5-hostname", "127.0.0.1:" + str(port),
            "--connect-timeout", "6", "--max-time", str(timeout),
            "--retry", "0", "--fail", "--silent", "--show-error", TRACE]
    try:
        result = subprocess.run(args, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, timeout=timeout + 3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    ip = re.search(r"(?m)^ip=(\d{1,3}(?:\.\d{1,3}){3})$", result.stdout)
    return ip.group(1) if ip else None

def empty_state():
    return {"format": "SOLO_MONITOR_V1", "nodes": {}}

def read_state():
    if not STATE_PATH.exists():
        return empty_state()
    data = json.loads(STATE_PATH.read_text())
    ensure(data.get("format") == "SOLO_MONITOR_V1" and isinstance(data.get("nodes"), dict),
           "Unexpected saved monitor state; stop")
    return data

def write_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(STATE_PATH.parent, 0o700)
    fd, temp = tempfile.mkstemp(prefix=".state-", dir=STATE_PATH.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(state, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, STATE_PATH)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)

def transition(old, success, *, now):
    """Pure state machine; returns (new_state, should_trigger_failover).

    Once failover is requested it stays latched and NEVER auto-fails back.
    Two failures are needed, from two independent scheduled 60-second rounds.
    """
    previous = dict(old)
    route = previous.get("route", "primary")
    ensure(route in ("primary", "standby", "switch_requested", "switch_failed"),
           "Unknown persisted route")
    consecutive = 0 if success else min(2, int(previous.get("failures", 0)) + 1)
    new = {**previous, "route": route, "failures": consecutive,
           "last_check_utc": now, "healthy": success}
    trigger = route == "primary" and not success and consecutive == 2
    if trigger:
        new["route"] = "switch_requested"
        new["last_trigger_utc"] = now
    return new, trigger

def valid_approval():
    if not MARKER.is_file() or MARKER.is_symlink():
        return False
    st = MARKER.stat()
    return st.st_uid == 0 and st.st_mode & 0o077 == 0 and MARKER.read_text().strip() == "SOLO_STANDBY_TESTED_AND_APPROVED"

def perform(node, old, observation, armed, now):
    expected = node["standby_egress_ip"] if old.get("route") in ("standby", "switch_requested", "switch_failed") else node["primary_egress_ip"]
    good = observation == expected
    nxt, trigger = transition(old, good, now=now)
    name = node["id"]
    if old.get("route") == "switch_requested" and observation == node["standby_egress_ip"]:
        nxt["route"] = "standby"
        nxt["failures"] = 0
        nxt["healthy"] = True
    if trigger:
        if armed:
            command = node.get("switch_command")
            if command is None:
                nxt["route"] = "switch_failed"
                nxt["last_action"] = "NO_COMMAND"
            else:
                try:
                    result = subprocess.run(command, stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=35)
                    if result.returncode:
                        nxt["route"] = "switch_failed"
                        nxt["last_action"] = "COMMAND_FAILED"
                    else:
                        nxt["last_action"] = "COMMAND_ACCEPTED_UNVERIFIED"
                except (OSError, subprocess.TimeoutExpired):
                    nxt["route"] = "switch_failed"
                    nxt["last_action"] = "COMMAND_TIMEOUT_OR_ERROR"
        else:
            nxt["route"] = "primary"
            nxt["last_action"] = "OBSERVE_ONLY_TWO_FAILURES"
    print(json.dumps({
        "at": now, "node": name, "observed_egress": observation or "NONE",
        "expected_egress": expected, "healthy": good,
        "failure_count": nxt["failures"], "route_state": nxt["route"],
        "trigger": trigger, "actions_enabled": armed
    }, ensure_ascii=False), flush=True)
    return nxt

def cycle(config, state, armed, now=None):
    now = now or utc()
    for node in config["nodes"]:
        name = node["id"]
        previous = state["nodes"].get(name, {})
        observation = probe(node["socks_port"])
        current = perform(node, previous, observation, armed, now)
        state["nodes"][name] = current
        # Persist after each node: avoid repeating action after a crash.
        write_state(state)
    return state

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--config", type=Path, required=True)
    p.add_argument("--once", action="store_true")
    p.add_argument("--armed", action="store_true",
                   help="Requires root-owned approval marker and per-node commands")
    args = p.parse_args()
    ensure(os.geteuid() == 0, "Run controller as root")
    cfg = config_file(args.config)
    if args.armed:
        ensure(valid_approval(), "Missing trusted standby-test approval marker; refusing actions")
        ensure(all(n.get("switch_command") for n in cfg["nodes"]),
               "All configured nodes need an explicit switch_command")
    state = read_state()
    if args.once:
        cycle(cfg, state, args.armed)
        return
    print("SOLO_MONITOR_START interval=60 seconds armed=" + str(args.armed), flush=True)
    # Offset from the START of each round, not the end of a slow request.
    next_start = time.monotonic()
    while True:
        cycle(cfg, state, args.armed)
        next_start += 60
        sleep_time = max(0.0, next_start - time.monotonic())
        if sleep_time:
            time.sleep(sleep_time)
        elif time.monotonic() - next_start > 60:
            # If host was paused, rebase rather than firing multiple quick checks.
            next_start = time.monotonic()

if __name__ == "__main__":
    try:
        main()
    except (Guard, ValueError, KeyError, OSError, subprocess.TimeoutExpired) as ex:
        print("SOLO_MONITOR_STOP:", str(ex)[:240], file=sys.stderr)
        sys.exit(2)
