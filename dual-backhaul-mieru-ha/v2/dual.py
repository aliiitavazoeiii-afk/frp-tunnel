#!/usr/bin/env python3
"""Dual HA operational console for IRAN: read-only diagnostics and guarded foreign rotations.

No Xray/3x-ui modifications. Rollbacks restore the previous isolated tunnel on failure.
IP reachability by itself cannot identify government filtering with certainty.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ETC = Path(os.environ.get("DUAL_ETC", "/etc/dual-ha"))
RUN = Path(os.environ.get("DUAL_RUN", "/run/dual-ha-v2"))
HELPER = Path(__file__).resolve().parent
ROTATIONS = Path("/root/dual-ha-rotations")
REPO = "aliiitavazoeiii-afk/frp-tunnel"
FOREIGN_INSTALL = HELPER / "foreign-install.sh"
SERVICES = {
    "backhaul": "dual-ha-backhaul",
    "mieru": "dual-ha-mieru",
    "gateway": "dual-ha-v2-gateway",
    "health": "dual-ha-v2-health",
    "x-ui": "x-ui",
}
PORTS = {"backhaul": 21001, "mieru": 21002, "gateway": 18080}
TARGETS = [
    ("Cloudflare", "https://www.cloudflare.com/cdn-cgi/trace", 200),
    ("Google 204", "https://www.gstatic.com/generate_204", 204),
    ("Apple", "https://www.apple.com/library/test/success.html", 200),
]
COLORS = bool(sys.stdout.isatty() and not os.environ.get("NO_COLOR"))
SHA = "22e7929f920d71aace7e43311bbb33fe7c07c583080621d064f79a9d13460601"


def color(s: str, code: str) -> str:
    return ("\033[" + code + "m" + s + "\033[0m") if COLORS else s


def run(cmd: list[str], *, timeout: int = 30, input_bytes: bytes | None = None,
        check: bool = True) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       timeout=timeout, check=False)
    if check and r.returncode:
        error = r.stderr.decode(errors="replace").strip()
        # Never print secrets, potentially embedded in command arguments or stderr.
        raise RuntimeError("Command failed (exit %s): %s" % (r.returncode, error[-500:]))
    return r


def status(name: str) -> str:
    r = run(["systemctl", "is-active", name], check=False, timeout=5)
    return r.stdout.decode(errors="replace").strip() or "unknown"


def read_bundle() -> dict[str, str]:
    src = ETC / "backhaul-bundle.env"
    result = {}
    if not src.is_file():
        return result
    for line in src.read_text().splitlines():
        m = re.fullmatch(r"([A-Z_]+)='([^']*)'", line)
        if m:
            result[m.group(1)] = m.group(2)
    return result


def read_mieru() -> dict:
    path = ETC / "mieru.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def active_ips() -> dict[str, str]:
    bh = read_bundle()
    cfg = read_mieru()
    try:
        mr = cfg["profiles"][0]["servers"][0]["ipAddress"]
    except (LookupError, TypeError):
        mr = "UNKNOWN"
    return {"backhaul": bh.get("BH_FOREIGN_IP", "UNKNOWN"), "mieru": mr}


def iran_ip() -> str:
    return read_bundle().get("BH_IRAN_IP") or "94.184.4.38"


def health_cache() -> tuple[dict, int | None]:
    try:
        data = json.loads((RUN / "health.json").read_text())
        updated = datetime.datetime.fromisoformat(data["updated_utc"])
        age = max(0, int((datetime.datetime.now(datetime.timezone.utc) - updated).total_seconds()))
        return data.get("paths", {}), age
    except (OSError, ValueError, KeyError, TypeError):
        return {}, None


def outbound_probe(port: int, url: str, expected: int, max_seconds: int = 10) -> dict:
    args = ["curl", "-4", "--noproxy", "", "--silent", "--show-error",
            "--socks5-hostname", "127.0.0.1:%d" % port,
            "--connect-timeout", "4", "--max-time", str(max_seconds),
            "--output", "-", "--write-out", "\nDUAL_HTTP:%{http_code} DUAL_TIME:%{time_total}\n", url]
    try:
        r = run(args, timeout=max_seconds + 2, check=False)
        data = r.stdout.decode(errors="replace")
        code = re.search(r"DUAL_HTTP:(\d{3})", data)
        latency = re.search(r"DUAL_TIME:([0-9.]+)", data)
        ip = re.search(r"(?m)^ip=(\d{1,3}(?:\.\d{1,3}){3})$", data)
        http = int(code.group(1)) if code else 0
        ok = r.returncode == 0 and http == expected
        return {"ok": ok, "http": http, "latency": float(latency.group(1)) if latency else None,
                "ip": ip.group(1) if ok and ip else None,
                "error": "" if ok else ("curl_exit=%s HTTP=%s" % (r.returncode, http))}
    except (OSError, subprocess.TimeoutExpired):
        return {"ok": False, "http": 0, "latency": None, "ip": None, "error": "timeout/error"}


def parallel_probes() -> dict:
    tasks = [(role, port, name, url, expected)
             for role, port in PORTS.items()
             for name, url, expected in TARGETS[:2]]
    result = {role: {} for role in PORTS}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        futs = {pool.submit(outbound_probe, port, url, expected): (role, name)
                for role, port, name, url, expected in tasks}
        for future in concurrent.futures.as_completed(futs):
            role, name = futs[future]
            try:
                result[role][name] = future.result()
            except Exception:
                result[role][name] = {"ok": False, "error": "unexpected probe error"}
    return result


def tcp_probe(host: str, port: int, timeout: float = 3) -> bool:
    try:
        with socket.create_connection((host, port), timeout):
            return True
    except (OSError, ValueError):
        return False


def print_status(deep: bool = False) -> None:
    ips = active_ips()
    h, age = health_cache()
    print()
    print(color("  DUAL HA  |  Iran Xray / 2 independent foreign egress paths", "1;36"))
    print("  " + "-" * 65)
    print("  IRAN    %s  | REALITY 443: %s" % (iran_ip(), color(status("x-ui"), "32")))
    for role in ("backhaul", "mieru"):
        info = h.get(role, {})
        fresh = age is not None and age <= 30
        if not fresh:
            state = color("UNKNOWN (stale/missing controller data)", "33")
        elif info.get("available") is True:
            state = color("HEALTHY", "32")
        else:
            state = color("DOWN / health checks failed (cause unverified)", "31")
        print("  %-8s %15s  local SOCKS 127.0.0.1:%d" %
              (role.upper(), ips[role], PORTS[role]))
        print("           %s | https=%s/3 avg=%ss" %
              (state, info.get("passed_probes", "?"), info.get("latency_average_s", "?")))
    print("  GATEWAY 127.0.0.1:18080 | HAProxy=%s | controller=%s" %
          (status(SERVICES["gateway"]), status(SERVICES["health"])))
    print("  health.json age: %ss" % (age if age is not None else "UNKNOWN"))
    print("  " + "-" * 65)
    if not deep:
        print("  sudo dual health     : end-to-end HTTPS probes + network checks")
        print("  sudo dual replace ...: staged replacement (needs root SSH keys)")
        return
    probes = parallel_probes()
    print(color("\n  REAL HTTPS PATH CHECKS (not a definitive censorship detector)", "1;36"))
    for role in ("backhaul", "mieru", "gateway"):
        ps = probes[role]
        passed = sum(bool(v.get("ok")) for v in ps.values())
        ips_seen = sorted({v["ip"] for v in ps.values() if v.get("ip")})
        for name in ("Cloudflare", "Google 204"):
            p = ps.get(name, {})
            label = color("PASS", "32") if p.get("ok") else color("FAIL", "31")
            latency = p.get("latency")
            print("  %-8s %-12s %-6s  %s" %
                  (role, name, label, "%.3fs" % latency if latency is not None else p.get("error", "")))
        print("    HTTPS requests: %s/2; observed egress IP: %s" %
              (passed, ", ".join(ips_seen) if ips_seen else "unavailable"))
        if passed < 2:
            print("    diagnosis: DEGRADED / DOWN; filtering, service failure and routing failure cannot be distinguished yet.")
    if ips["mieru"] != "UNKNOWN":
        print("  TCP IRAN -> Mieru %s:28443 : %s" %
              (ips["mieru"], "REACHABLE" if tcp_probe(ips["mieru"], 28443) else
               "UNREACHABLE (service/firewall/route/filtering ambiguous)"))
    print("  Backhaul is REVERSE: its foreign host connects to Iran TCP/18443.")
    print("  :21001 real SOCKS egress is the decisive Backhaul data-plane check.")
    print("  Network filtering cannot be verified conclusively from one VPS and two HTTPS probes.\n")


SSH_OPTS = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=9", "-o", "ServerAliveInterval=8", "-o", "ServerAliveCountMax=2"]


def ssh(ip: str, command: str, *, timeout: int = 90, stdin: bytes | None = None) -> str:
    r = run(["ssh", *SSH_OPTS, "root@" + ip, command], timeout=timeout, input_bytes=stdin)
    return r.stdout.decode(errors="replace")


def scp(source: str, dest: str, *, timeout: int = 40) -> None:
    run(["scp", "-q", *SSH_OPTS, source, dest], timeout=timeout)


def ensure_ip(value: str) -> str:
    ip = ipaddress.ip_address(value)
    if ip.version != 4 or not ip.is_global:
        raise ValueError("Only globally routable foreign IPv4 is allowed")
    return str(ip)


def safety_checks(role: str, new_ip: str, *, check_ssh: bool = True) -> str:
    if os.geteuid() != 0:
        raise RuntimeError("Root permissions required: sudo dual replace ...")
    if not FOREIGN_INSTALL.is_file():
        raise RuntimeError("Missing foreign installer: reinstall dual helper from the latest repository")
    if not (ETC / "mieru.json").is_file() or not (ETC / "backhaul-bundle.env").is_file():
        raise RuntimeError("Existing Iran tunnel files are missing; refusing production rotation")
    ips = active_ips()
    old_ip = ensure_ip(ips[role])
    new_ip = ensure_ip(new_ip)
    if new_ip == old_ip:
        raise RuntimeError("New IP is identical to current %s IP" % role)
    other = "mieru" if role == "backhaul" else "backhaul"
    if new_ip == ips[other] or new_ip == iran_ip():
        raise RuntimeError("New IP overlaps existing HA host")
    health, age = health_cache()
    if age is None or age > 24 or not health.get(other, {}).get("available"):
        raise RuntimeError("Other HA path not confirmed healthy/fresh; rotation not safe")
    if not all(status(SERVICES[k]) == "active" for k in ("x-ui", "gateway", "health", other)):
        raise RuntimeError("Core live services are not all active; abort before any change")
    if check_ssh:
        for ip in (old_ip, new_ip):
            try:
                ssh(ip, "id -u && test -d /root", timeout=15)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as e:
                raise RuntimeError("Root SSH key login failed for %s. First verify SSH fingerprint and set up key-based access from Iran. %s" %
                                   (ip, type(e).__name__)) from e
    return old_ip


def checked_confirm(role: str, old: str, new: str) -> bool:
    print(color("\n  PRODUCTION FOREIGN REPLACEMENT — MAY INTERRUPT EXISTING CONNECTIONS", "1;33"))
    print("  Role: %s | OLD: %s | NEW: %s" % (role, old, new))
    print("  Existing REALITY users will be routed through surviving HA path during switch.")
    print("  This action DOES NOT edit 3x-ui, UUIDs, or TCP/443.")
    print("  It requires root SSH keys to BOTH hosts and independently verified SSH fingerprints.")
    word = "REPLACE " + role
    try:
        return input("  Type exactly '%s' to continue: " % word).strip() == word
    except EOFError:
        return False


def workdir() -> Path:
    ROTATIONS.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(ROTATIONS, 0o700)
    w = ROTATIONS / datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if w.exists():
        raise RuntimeError("Rotation directory already exists; try again after inspecting prior run")
    w.mkdir(mode=0o700)
    return w


def candidate_mieru_bundle(path: Path, ip: str) -> tuple[str, str]:
    raw = {}
    for line in path.read_text().splitlines():
        m = re.fullmatch(r"([A-Z_]+)='([^']*)'", line)
        if m:
            raw[m.group(1)] = m.group(2)
    if raw.get("MIERU_REMOTE_IP") != ip or raw.get("MIERU_TCP_PORT") != "28443":
        raise RuntimeError("Foreign Mieru bundle identity mismatch; refusing use")
    user, password = raw.get("MIERU_USER"), raw.get("MIERU_PASSWORD")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", user or "") or not re.fullmatch(r"[0-9a-f]{64}", password or ""):
        raise RuntimeError("Foreign Mieru bundle credential format invalid")
    return user, password


def atomic_write(path: Path, content: bytes, mode: int = 0o600) -> None:
    fd, name = tempfile.mkstemp(prefix=".dual-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def confirm_egress(role: str, ip: str, *, seconds: int = 35) -> bool:
    port = PORTS[role]
    deadline = time.monotonic() + seconds
    count = 0
    while time.monotonic() < deadline:
        p = outbound_probe(port, TARGETS[0][1], 200, max_seconds=10)
        if p["ok"] and p["ip"] == ip:
            count += 1
            if count >= 2:
                return True
        else:
            count = 0
        time.sleep(2)
    return False


def prepped_remote_install(role: str, ip: str, candidate_bundle: Path | None = None) -> None:
    args = ["--role", role, "--iran-ip", iran_ip(), "--foreign-ip", ip]
    if role == "backhaul":
        if not candidate_bundle:
            raise RuntimeError("Backhaul bundle required")
        ssh(ip, "umask 077; test ! -e /root/dual-ha-backhaul-bundle.env && touch /root/dual-ha-backhaul-bundle.env",
            timeout=15)
        scp(str(candidate_bundle), "root@" + ip + ":/root/dual-ha-backhaul-bundle.env")
        args += ["--bundle", "/root/dual-ha-backhaul-bundle.env", "--prepare"]
    print("  Installing %s on new foreign host %s (fresh server only)..." % (role, ip))
    cmd = "bash -s -- " + " ".join(args)
    ssh(ip, cmd, stdin=FOREIGN_INSTALL.read_bytes(), timeout=420)
    print("  Foreign installation completed.")


def replace_mieru(old_ip: str, new_ip: str, w: Path) -> None:
    config_path = ETC / "mieru.json"
    backup = w / "mieru.previous.json"
    shutil.copy2(config_path, backup)
    os.chmod(backup, 0o600)
    changed = False
    try:
        prepped_remote_install("mieru", new_ip)
        candidate = w / "mieru.candidate-bundle.env"
        scp("root@" + new_ip + ":/etc/dual-ha/mieru-bundle.env", str(candidate))
        os.chmod(candidate, 0o600)
        user, password = candidate_mieru_bundle(candidate, new_ip)
        if not tcp_probe(new_ip, 28443, timeout=5):
            raise RuntimeError("New Mita TCP/28443 unreachable from Iran; old Mieru remains active")
        print("  New Mita running and TCP reachable; switching ONLY Iran Mieru client...")
        cfg = read_mieru()
        try:
            cfg["profiles"][0]["user"]["name"] = user
            cfg["profiles"][0]["user"]["password"] = password
            cfg["profiles"][0]["servers"][0]["ipAddress"] = new_ip
        except (LookupError, TypeError) as e:
            raise RuntimeError("Existing Mieru JSON unexpected; refusing change") from e
        changed = True
        atomic_write(config_path, (json.dumps(cfg, indent=2) + "\n").encode())
        run(["systemctl", "restart", "dual-ha-mieru"], timeout=20)
        if not confirm_egress("mieru", new_ip):
            raise RuntimeError("HTTPS egress via new Mieru did not confirm candidate public IP")
        print(color("  SUCCESS: Mieru path now egresses via %s" % new_ip, "1;32"))
        print("  Old Mita %s was NOT stopped, keeping rollback potential." % old_ip)
        print("  Private previous config in %s" % backup)
    except Exception:
        if changed:
            print(color("  NEW MIERU FAILED — RESTORING PREVIOUS CONFIG AND SERVICE", "1;31"))
            atomic_write(config_path, backup.read_bytes())
            run(["systemctl", "restart", "dual-ha-mieru"], timeout=25)
            if not confirm_egress("mieru", old_ip, seconds=30):
                print(color("  URGENT: old Mieru path not confirmed after rollback; keep Backhaul active!", "1;31"))
            else:
                print(color("  ROLLBACK VERIFIED: previous Mieru egress recovered", "1;32"))
        raise
    finally:
        # Candidate secrets should not remain on Iran after switch; active creds live in /etc/dual-ha/mieru.json.
        p = w / "mieru.candidate-bundle.env"
        if p.exists():
            p.unlink()


def backhaul_candidate_bundle(old_ip: str, new_ip: str, w: Path) -> Path:
    src = ETC / "backhaul-bundle.env"
    original = src.read_text()
    pattern = "BH_FOREIGN_IP='%s'" % old_ip
    if original.count(pattern) != 1:
        raise RuntimeError("Original Backhaul bundle identity mismatch")
    content = original.replace(pattern, "BH_FOREIGN_IP='%s'" % new_ip)
    if not re.search(r"(?m)^BH_TOKEN='[0-9a-f]{64}'$", content):
        raise RuntimeError("Backhaul token format mismatch; refusing rotation")
    candidate = w / "backhaul.candidate-bundle.env"
    atomic_write(candidate, content.encode())
    shutil.copy2(src, w / "backhaul.previous-bundle.env")
    os.chmod(w / "backhaul.previous-bundle.env", 0o600)
    return candidate


def ufw_allow_new(ip: str) -> bool:
    if shutil.which("ufw") is None:
        return False
    res = run(["ufw", "status"], check=False)
    if "Status: active" not in res.stdout.decode(errors="replace"):
        return False
    # Avoid changing any old UFW rules. Only add one explicitly tagged rule.
    run(["ufw", "allow", "from", ip, "to", "any", "port", "18443",
         "proto", "tcp", "comment", "dual-ha-replacement"], timeout=20)
    print("  UFW added source-restricted Iran TCP/18443 entry for new foreign host.")
    return True


def ufw_rollback(ip: str, added: bool) -> None:
    if added:
        run(["ufw", "--force", "delete", "allow", "from", ip, "to", "any",
             "port", "18443", "proto", "tcp"], check=False, timeout=20)


def replace_backhaul(old_ip: str, new_ip: str, w: Path) -> None:
    candidate = backhaul_candidate_bundle(old_ip, new_ip, w)
    opened = False
    old_stop_attempted = False
    started_new = False
    new_enabled = False
    original_bundle = (w / "backhaul.previous-bundle.env").read_bytes()
    try:
        prepped_remote_install("backhaul", new_ip, candidate)
        opened = ufw_allow_new(new_ip)
        print(color("  READY: old Backhaul is still live. Switching reverse client now...", "1;33"))
        old_stop_attempted = True
        ssh(old_ip, "systemctl stop dual-ha-backhaul-client", timeout=25)
        ssh(new_ip, "systemctl start dual-ha-backhaul-client", timeout=25)
        started_new = True
        if not confirm_egress("backhaul", new_ip, seconds=45):
            raise RuntimeError("New Backhaul SOCKS :21001 could not prove correct foreign egress")
        # Persist staged new service on boot, then retire only old client.
        # New service will survive reboot; old service must not return unexpectedly.
        ssh(new_ip, "systemctl enable dual-ha-backhaul-client", timeout=15)
        new_enabled = True
        ssh(old_ip, "systemctl disable dual-ha-backhaul-client", timeout=15)
        atomic_write(ETC / "backhaul-bundle.env", candidate.read_bytes())
        print(color("  SUCCESS: Backhaul reverse client switched to %s" % new_ip, "1;32"))
        print("  Previous bundle backup: %s" % (w / "backhaul.previous-bundle.env"))
        print("  Keep the old foreign host available for manual rollback until stability verified.")
        print("  Review provider firewall: Iran TCP/18443 must permit the new foreign IP.")
        print("  Old UFW IP allow entry is NOT removed automatically.")
    except Exception:
        if old_stop_attempted:
            print(color("  NEW BACKHAUL FAILED — INITIATING ROLLBACK TO OLD FOREIGN HOST", "1;31"))
            try:
                # Always stop and disable the candidate to prevent stale reverse reconnection after reboot.
                ssh(new_ip, "systemctl disable --now dual-ha-backhaul-client", timeout=25)
            except Exception:
                print(color("  WARNING: new foreign client may still be connected; inspect manually!", "1;31"))
            try:
                atomic_write(ETC / "backhaul-bundle.env", original_bundle)
                ssh(old_ip, "systemctl enable --now dual-ha-backhaul-client", timeout=25)
                if confirm_egress("backhaul", old_ip, seconds=35):
                    print(color("  ROLLBACK VERIFIED: old Backhaul egress restored", "1;32"))
                else:
                    print(color("  URGENT: old Backhaul path did not recover; rely on Mieru.", "1;31"))
            except Exception:
                print(color("  URGENT: failed to restore old Backhaul service; rely on Mieru.", "1;31"))
        ufw_rollback(new_ip, opened)
        raise
    finally:
        if candidate.exists():
            candidate.unlink()


def rotate(role: str, new_ip: str) -> None:
    new_ip = ensure_ip(new_ip)
    old = safety_checks(role, new_ip)
    if not checked_confirm(role, old, new_ip):
        print("  Cancelled. No production configuration touched.")
        return
    w = workdir()
    print("  Rotation backup directory:", w)
    if role == "backhaul":
        replace_backhaul(old, new_ip, w)
    else:
        replace_mieru(old, new_ip, w)
    print(color("  Rotation completed. Run sudo dual health and monitor for 24-72h.", "1;32"))
    print("  Old foreign host is NOT deleted. No 3x-ui setting or REALITY identity was edited.")


def logs() -> None:
    for role in ("gateway", "health", "backhaul", "mieru"):
        service = SERVICES[role]
        print("\n=== %s ===" % service)
        r = run(["journalctl", "-u", service, "-n", "12", "--no-pager", "-o", "short-iso"],
                timeout=10, check=False)
        text = r.stdout.decode(errors="replace")
        # Very old logs sometimes contain secrets. Avoid leaking secret-bearing lines.
        text = "\n".join(line for line in text.splitlines()
                         if not any(word in line.lower() for word in
                                    ("password", "token=", "secret=", "privatekey")))
        print(text[-2000:])


def menu() -> None:
    while True:
        print_status()
        print(color("\n  [1] Dashboard      [2] Detailed health / censorship diagnosis", "1;36"))
        print("  [3] Replace BACKHAUL foreign host")
        print("  [4] Replace MIERU foreign host")
        print("  [5] Last service logs")
        print("  [0] Exit")
        try:
            selection = input("\n  dual > ").strip()
            if selection == "0":
                break
            if selection == "1":
                print_status()
            elif selection == "2":
                print_status(deep=True)
            elif selection in ("3", "4"):
                role = "backhaul" if selection == "3" else "mieru"
                new_ip = input("  New public foreign IPv4 for %s: " % role).strip()
                rotate(role, new_ip)
            elif selection == "5":
                logs()
            else:
                print("  Choose 0-5")
        except (EOFError, KeyboardInterrupt):
            print("\n  Exiting.")
            break
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as e:
            print(color("  ERROR: " + str(e), "1;31"))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Dual HA: dashboard, HTTPS health, logs, guarded foreign host rotation")
    subs = parser.add_subparsers(dest="command")
    subs.add_parser("status")
    subs.add_parser("health")
    subs.add_parser("logs")
    replace = subs.add_parser("replace", help="Staged SSH replacement (requires confirmation)")
    replace.add_argument("role", choices=["backhaul", "mieru"])
    replace.add_argument("ip", help="New foreign public IPv4")
    args = parser.parse_args()
    try:
        if args.command == "status":
            print_status()
        elif args.command == "health":
            print_status(deep=True)
        elif args.command == "logs":
            logs()
        elif args.command == "replace":
            rotate(args.role, args.ip)
        else:
            if not sys.stdin.isatty():
                print_status()
            else:
                menu()
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as e:
        print(color("ERROR: " + str(e), "1;31"), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
