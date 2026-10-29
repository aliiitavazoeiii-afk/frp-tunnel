#!/usr/bin/env python3
"""Independent end-to-end SOCKS5 probes with HAProxy runtime failover."""
import os
import socket
import subprocess
import time

SOCKET = "/run/dual-ha/haproxy.sock"
PATHS = {"backhaul": 21001, "mieru": 21002}
TARGET = os.environ.get("DUAL_HA_PROBE_URL", "https://www.cloudflare.com/cdn-cgi/trace")
INTERVAL = 8
FALL = 3
RISE = 5

def probe(port):
    cmd = ["curl", "--silent", "--show-error", "--fail", "--output", "/dev/null",
           "--connect-timeout", "5", "--max-time", "12",
           "--socks5-hostname", f"127.0.0.1:{port}", TARGET]
    return subprocess.run(cmd, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, timeout=16).returncode == 0

def haproxy(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(4)
        s.connect(SOCKET)
        s.sendall((command + "\n").encode())
        s.shutdown(socket.SHUT_WR)
        return s.recv(8192).decode(errors="replace")

def main():
    counts = {name: {"ok": 0, "fail": 0, "enabled": None} for name in PATHS}
    while True:
        for name, port in PATHS.items():
            good = False
            try:
                good = probe(port)
            except (OSError, subprocess.TimeoutExpired):
                pass
            c = counts[name]
            c["ok"] = c["ok"] + 1 if good else 0
            c["fail"] = 0 if good else c["fail"] + 1
            action = None
            if c["fail"] >= FALL and c["enabled"] is not False:
                action = "maint"
            if c["ok"] >= RISE and c["enabled"] is not True:
                action = "ready"
            if action:
                try:
                    result = haproxy(f"set server socks_egress/{name} state {action}")
                    if "error" in result.lower():
                        raise RuntimeError(result)
                    c["enabled"] = action == "ready"
                    print(f"{name} -> {action} after e2e checks", flush=True)
                except (OSError, RuntimeError) as e:
                    print(f"{name} HAProxy update failed: {e}", flush=True)
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
