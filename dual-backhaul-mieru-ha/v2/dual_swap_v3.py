#!/usr/bin/env python3
"""V3 foreign-host swap engine. Called exclusively by dual.py's menu.

No contact with the old VPS is required before/during a switch. Both roles
must pass a *separate Iran-side 1-MiB transfer test* before production cutover.
Rollbacks are best effort: a previously broken old host cannot be resurrected.
"""
from __future__ import annotations

import contextlib
import copy
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import time

import dual
import dual_auto

HOSTS = {"94.184.4.38": "maya1", "185.215.230.221": "maya-s3", "5.10.249.206": "maya4"}
ROOT = Path("/root/dual-ha-rotations/v3")
LOCK = Path("/run/dual-ha-v3.lock")
JOURNAL = ROOT / "current.json"
CF_TRACE = "https://www.cloudflare.com/cdn-cgi/trace"
DOWNLOAD = "https://speed.cloudflare.com/__down?bytes=1048576"
BYTES = 1048576
STAGE = {"backhaul": 21101, "mieru": 21102}
LIVE = {"backhaul": 21001, "mieru": 21002}
STAGE_BACKHAUL_TCP = 18444
GUARD = "DUAL_V3_BH"
GUARD_SCRIPT = Path("/usr/local/sbin/dual-ha-v3-guard.sh")
GUARD_UNIT = Path("/etc/systemd/system/dual-ha-v3-guard.service")


class SwapError(RuntimeError):
    pass


def cmd(argv, *, timeout=30, check=True):
    p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=timeout, check=False, text=True)
    if check and p.returncode:
        raise SwapError(f"Command {argv[0]} exited {p.returncode}")
    return p


def host_ip(value):
    ip = ipaddress.ip_address(value)
    if ip.version != 4 or not ip.is_global:
        raise SwapError("New VPS requires a public IPv4")
    return str(ip)


def live_identity():
    iran = host_ip(dual.iran_ip())
    if iran not in HOSTS:
        raise SwapError("Unrecognized Iran host; refusing any change")
    # Do not rely on the fallback value of dual.iran_ip().
    bundle = dual.read_bundle()
    if bundle.get("BH_IRAN_IP") != iran:
        raise SwapError("Iran identity is not explicitly configured")
    return iran


def is_listening(port):
    for host in ("127.0.0.1",):
        try:
            with socket.create_connection((host, port), timeout=0.25):
                return True
        except OSError:
            pass
    return False


def saved(path, work):
    raw = path.read_bytes()
    dst = work / (path.name + ".prior")
    dual.atomic_write(dst, raw)
    return raw


def journal(**kwargs):
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    content = {"format": "DUAL_SWAP_V3", "updated": int(time.time()), **kwargs}
    dual.atomic_write(JOURNAL, (json.dumps(content, indent=2) + "\n").encode())


def prior_incomplete():
    if JOURNAL.is_file():
        try:
            record = json.loads(JOURNAL.read_text())
        except (OSError, ValueError):
            raise SwapError("Invalid previous journal; investigate before rotation")
        if record.get("phase") not in ("completed", "rolled_back", "staging_failed"):
            raise SwapError("Unfinished V3 rotation detected; choose recovery from sudo dual")


def probe(port, target_ip, *, label):
    """Bounded fixed-destination probes; exact response size required."""
    print(f"  {label} via SOCKS :{port} — verifying egress and 1-MiB transfers", flush=True)
    trace = cmd(["curl", "-q", "-4", "--noproxy", "", "--silent", "--show-error",
                 "--socks5-hostname", f"127.0.0.1:{port}", "--connect-timeout", "5",
                 "--max-time", "12", "--fail", CF_TRACE], timeout=15, check=False)
    ip_match = re.search(rb"(?m)^ip=(\d{1,3}(?:\.\d{1,3}){3})$", trace.stdout)
    if trace.returncode or not ip_match or ip_match.group(1).decode() != target_ip:
        print("  Egress identity FAIL", flush=True)
        return False
    wins = 0
    for n in range(1, 4):
        p = cmd(["curl", "-q", "-4", "--noproxy", "", "--silent", "--show-error",
                 "--socks5-hostname", f"127.0.0.1:{port}", "--connect-timeout", "5",
                 "--max-time", "16", "--retry", "0", "--max-redirs", "0",
                 "--fail", "--max-filesize", str(BYTES), "--output", "/dev/null", "--write-out",
                 "%{http_code} %{size_download} %{time_total} %{time_starttransfer}",
                 DOWNLOAD], timeout=19, check=False)
        try:
            http, received, elapsed, ttfb = p.stdout.strip().split()
            ok = (p.returncode == 0 and http == "200" and
                  int(float(received)) == BYTES and float(elapsed) <= 12 and
                  float(ttfb) <= 8)
            seconds = round(float(elapsed), 2)
            nbytes = int(float(received))
        except (ValueError, TypeError):
            ok, seconds, nbytes = False, None, 0
        print(f"    #{n} {'PASS' if ok else 'FAIL'} bytes={nbytes} time={seconds}s", flush=True)
        wins += int(ok)
    return wins >= 2


def wait_gateway(role, timeout=65):
    """Avoid declaring success when HAProxy has administratively MAINT'ed the path."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = dual.haproxy_metrics().get(role, {})
        if data.get("state") == "UP":
            return True
        time.sleep(3)
    return False


def verify_ssh(new):
    # Uses password exactly once, verifying unknown SSH fingerprint out-of-band.
    dual_auto.authorize_new(new)


def stage_mieru(new, work):
    dual.prepped_remote_install("mieru", new)
    remote = work / "mieru.foreign-bundle"
    dual.scp("root@" + new + ":/etc/dual-ha/mieru-bundle.env", str(remote))
    remote.chmod(0o600)
    username, password = dual.candidate_mieru_bundle(remote, new)
    remote.unlink(missing_ok=True)
    if not dual.tcp_probe(new, 28443, timeout=5):
        raise SwapError("New Mieru TCP/28443 is not reachable")
    client = dual.read_mieru()
    if client.get("profiles", [{}])[0].get("servers", [{}])[0].get("ipAddress") != dual.active_ips()["mieru"]:
        raise SwapError("Existing Mieru profile identity mismatch")
    client["profiles"][0]["user"].update({"name": username, "password": password})
    client["profiles"][0]["servers"][0]["ipAddress"] = new
    stage_cfg = copy.deepcopy(client)
    stage_cfg["socks5Port"] = STAGE["mieru"]
    stage_cfg["rpcPort"] = 28965
    cfg_path = work / "mieru.stage.json"
    dual.atomic_write(cfg_path, (json.dumps(stage_cfg) + "\n").encode())
    if is_listening(STAGE["mieru"]) or is_listening(28965):
        raise SwapError("Staging Mieru SOCKS or RPC port is occupied")
    env = os.environ.copy()
    env["MIERU_CONFIG_JSON_FILE"] = str(cfg_path)
    log = open(work / "mieru.stage.log", "ab", buffering=0)
    try:
        proc = subprocess.Popen(["/opt/dual-ha/bin/mieru", "run"], env=env,
                                stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                start_new_session=True)
    finally:
        log.close()
    dual.atomic_write(work / "mieru.stage.pid", (str(proc.pid)+"\n").encode())
    for _ in range(20):
        if proc.poll() is not None:
            raise SwapError("Candidate Mieru process terminated")
        if is_listening(STAGE["mieru"]):
            break
        time.sleep(0.4)
    else:
        stop_process(proc)
        raise SwapError("Candidate Mieru did not open staging SOCKS")
    dual.atomic_write(work / "mieru.production.json", (json.dumps(client, indent=2) + "\n").encode())
    return proc


def stop_process(proc):
    if proc is None or proc.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=4)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=3)


def maybe_stop_candidate(new, role):
    unit = "dual-ha-mita" if role == "mieru" else "dual-ha-backhaul-client"
    with contextlib.suppress(Exception):
        dual.ssh(new, "systemctl disable --now " + unit, timeout=12)


def cleanup_old_remote(old, role):
    """Best effort, never required for cutover. Revocation on Iran is decisive."""
    unit = "dual-ha-mita" if role == "mieru" else "dual-ha-backhaul-client"
    path = "/etc/dual-ha/mita.json /etc/dual-ha/mieru-bundle.env" if role == "mieru" else "/etc/dual-ha/backhaul-foreign.toml /root/dual-ha-backhaul-bundle.env"
    script = "systemctl disable --now " + unit + " 2>/dev/null || :; rm -f " + path
    try:
        dual.ssh(old, script, timeout=8)
        return True
    except Exception:
        return False


def stage_backhaul(new, iran, old_data, work):
    """Pre-stage a wholly distinct reverse route; never touch live Backhaul."""
    old = dual.read_bundle()
    expected = ("BH_DOMAIN", "BH_TOKEN", "BH_CONTROL_PATH", "BH_TUNNEL_PATH", "BH_FOREIGN_IP")
    if any(not old.get(k) for k in expected):
        raise SwapError("Existing Backhaul bundle incomplete")
    token = secrets.token_hex(32)
    ctrl = "/assets/" + secrets.token_hex(16)
    tunnel = "/socket/" + secrets.token_hex(16)
    newvals = dict(old, BH_TOKEN=token, BH_CONTROL_PATH=ctrl,
                   BH_TUNNEL_PATH=tunnel, BH_FOREIGN_IP=new)
    candidate = work / "backhaul.foreign-bundle.env"
    dual.atomic_write(candidate, "".join(f"{k}='{v}'\n" for k,v in newvals.items()).encode())
    toml_src = Path("/etc/dual-ha/backhaul-iran.toml")
    router_src = Path("/etc/dual-ha/backhaul-router.cfg")
    tls_src = Path("/etc/dual-ha/backhaul-stunnel.conf")
    for f in (toml_src, router_src, tls_src):
        if not f.is_file():
            raise SwapError("Missing Backhaul Iran configuration: " + str(f))
    toml = toml_src.read_text()
    router = router_src.read_text()
    for original, after, name in [
        (old["BH_TOKEN"], token, "token"),
        (old["BH_CONTROL_PATH"], ctrl, "control path"),
        (old["BH_TUNNEL_PATH"], tunnel, "tunnel path"),
    ]:
        if name == "token":
            if toml.count(original) != 1:
                raise SwapError("Backhaul token template mismatch")
            toml = toml.replace(original, after)
        else:
            if toml.count(original) != 1 or router.count(original) != 1:
                raise SwapError("Backhaul path template mismatch: " + name)
            toml = toml.replace(original, after)
            router = router.replace(original, after)
    if (toml.count('127.0.0.1:19081') != 1 or
        toml.count('127.0.0.1:21001=127.0.0.1:11080') != 1 or
        router.count('127.0.0.1:19080') != 1 or
        router.count('127.0.0.1:19081') != 1):
        raise SwapError("Unexpected Backhaul port layout: cannot stage safely")
    prod_toml, prod_router = toml, router
    stage_toml = toml.replace('127.0.0.1:19081', '127.0.0.1:19083').replace(
        '127.0.0.1:21001=127.0.0.1:11080','127.0.0.1:21101=127.0.0.1:11080')
    stage_router = router.replace('127.0.0.1:19080','127.0.0.1:19082').replace(
        '127.0.0.1:19081','127.0.0.1:19083')
    tls = tls_src.read_text()
    cert = re.search(r"(?m)^cert = ([^\r\n]+)$",tls)
    key = re.search(r"(?m)^key = ([^\r\n]+)$",tls)
    if not cert or not key or not Path(cert.group(1).strip()).is_file() or not Path(key.group(1).strip()).is_file():
        raise SwapError("Production TLS certificate and key not verifiable")
    stage_tls = "\n".join([
        "foreground = yes", "syslog = no", "debug = notice",
        "[dual-ha-v3-stage]", f"accept = 0.0.0.0:{STAGE_BACKHAUL_TCP}",
        "connect = 127.0.0.1:19082", f"cert = {cert.group(1)}",
        f"key = {key.group(1)}", "sslVersionMin = TLSv1.2", "TIMEOUTconnect = 10", ""])
    cfgs = [("backhaul.stage.toml", stage_toml),
            ("router.stage.cfg", stage_router),
            ("stunnel.stage.conf", stage_tls),
            ("backhaul.production.toml", prod_toml),
            ("router.production.cfg", prod_router)]
    for filename, data in cfgs:
        dual.atomic_write(work / filename, data.encode())
    for port in (STAGE["backhaul"], 19082, 19083, STAGE_BACKHAUL_TCP):
        if is_listening(port) or cmd(["ss", "-Hln", "sport = :"+str(port)],check=False).stdout.strip():
            raise SwapError("Backhaul staging port is occupied: " + str(port))
    # Install an isolated foreign service in prepare mode: no reverse connection yet.
    dual_auto.prepared_backhaul_install(new, iran, candidate)
    set_foreign_port(new, STAGE_BACKHAUL_TCP)
    return newvals


def set_foreign_port(ip, port):
    if port not in (STAGE_BACKHAUL_TCP, 18443):
        raise SwapError("Invalid Backhaul port")
    # Only replace the exact remote_addr field, preserving domain/TLS SNI.
    py = ("from pathlib import Path\n"
          "p=Path('/etc/dual-ha/backhaul-foreign.toml')\n"
          "s=p.read_text()\n"
          "import re\n"
          "m=re.findall(r'(?m)^remote_addr = \"([^\"]+):(?:18443|18444)\"$',s)\n"
          "assert len(m)==1, 'Unexpected remote_addr'\n"
          f"s=re.sub(r'(?m)^remote_addr = \"([^\"]+):(?:18443|18444)\"$',lambda a:'remote_addr = \"'+a.group(1)+':{port}\"',s)\n"
          "p.write_text(s)\n")
    dual.ssh(ip, "python3 -c " + shlex.quote(py), timeout=15)


def ipt(*args, check=True):
    return cmd(["iptables", "-w", *args], timeout=15, check=check)


def stage_firewall(new, iran):
    # Temporary, minimal new-source allowance for *staging* TCP/18444 only.
    allow = ["-s", new, "-d", iran, "-p", "tcp", "--dport", str(STAGE_BACKHAUL_TCP), "-j", "ACCEPT"]
    ipt("-I", "INPUT", "1", *allow)
    return allow


def undo_stage_firewall(rule):
    if rule:
        ipt("-D", "INPUT", *rule, check=False)


def guard_exists():
    return ipt("-S", GUARD, check=False).returncode == 0


def begin_production_guard(new, iran):
    # Never rely on the old allowlist, or require the old foreign host online.
    if guard_exists():
        # New source must win over the previous guard's old-source allow rule.
        ipt("-I", GUARD, "1", "-s", new, "-j", "ACCEPT")
        ipt("-I", GUARD, "2", "-p", "tcp", "-j", "REJECT", "--reject-with", "tcp-reset")
    else:
        ipt("-N", GUARD)
        ipt("-A", GUARD, "-s", new, "-j", "ACCEPT")
        ipt("-A", GUARD, "-p", "tcp", "-j", "REJECT", "--reject-with", "tcp-reset")
    # Highest priority: ahead of legacy !-s OLD rules on Maya1 and guards on Maya3.
    ipt("-I", "INPUT", "1", "-d", iran, "-p", "tcp", "--dport", "18443", "-j", GUARD)


def remove_production_guard(iran, had_guard=False):
    # Remove only the temporary high-priority jump installed by this attempt.
    ipt("-D", "INPUT", "-d", iran, "-p", "tcp", "--dport", "18443", "-j", GUARD, check=False)
    if had_guard:
        # Old V3 script will repopulate the chain from restored live bundle.
        if GUARD_SCRIPT.is_file():
            cmd([str(GUARD_SCRIPT)], check=False)
    else:
        ipt("-F", GUARD, check=False)
        ipt("-X", GUARD, check=False)


def install_persistent_guard(iran):
    """Owned, idempotent protection restored after reboot; no unrelated chain flush."""
    script = f'''#!/usr/bin/env bash
set -Eeuo pipefail
IP="$(sed -n "s/^BH_FOREIGN_IP='\\([0-9.]*\\)'$/\\1/p" /etc/dual-ha/backhaul-bundle.env)"
[[ "$IP" =~ ^([0-9]{{1,3}}\\.){{3}}[0-9]{{1,3}}$ ]]
iptables -w -N {GUARD} 2>/dev/null || true
iptables -w -F {GUARD}
iptables -w -A {GUARD} -s "$IP" -j ACCEPT
iptables -w -A {GUARD} -p tcp -j REJECT --reject-with tcp-reset
iptables -w -D INPUT -d {iran} -p tcp --dport 18443 -j {GUARD} 2>/dev/null || true
iptables -w -I INPUT 1 -d {iran} -p tcp --dport 18443 -j {GUARD}
'''
    unit = '''[Unit]
Description=Dual V3 Backhaul current source firewall guard
After=network-online.target dual-ha-rotation-guard.service maya3-backhaul-guard.service
Before=dual-ha-backhaul-tls.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dual-ha-v3-guard.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
'''
    dual.atomic_write(GUARD_SCRIPT, script.encode(), mode=0o700)
    dual.atomic_write(GUARD_UNIT, unit.encode(), mode=0o644)
    cmd(["systemctl", "daemon-reload"])
    cmd(["systemctl", "enable", "dual-ha-v3-guard.service"])
    cmd([str(GUARD_SCRIPT)])


def _start_stage(iran, work):
    # Isolated subprocesses, no production systemd unit or HAProxy modification.
    binary = "/opt/dual-ha/bin/backhaul"
    for exe in (binary, "/usr/sbin/haproxy", "/usr/bin/stunnel"):
        if not Path(exe).is_file():
            raise SwapError("Missing stage prerequisite " + exe)
    commands = [
        [binary, "-c", str(work / "backhaul.stage.toml")],
        ["/usr/sbin/haproxy", "-W", "-db", "-f", str(work / "router.stage.cfg")],
        ["/usr/bin/stunnel", str(work / "stunnel.stage.conf")],
    ]
    procs = []
    try:
        for idx, argv in enumerate(commands):
            log = open(work / f"backhaul.stage.{idx}.log", "ab", buffering=0)
            try:
                p = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=log, start_new_session=True)
            finally:
                log.close()
            procs.append(p)
            dual.atomic_write(work / f"backhaul.stage.{idx}.pid", (str(p.pid)+"\n").encode())
            time.sleep(1)
            if p.poll() is not None:
                raise SwapError("Backhaul candidate stage component stopped")
        if not is_listening(STAGE_BACKHAUL_TCP):
            raise SwapError("Candidate Backhaul TLS 18444 is not accepting locally")
        return procs
    except Exception:
        for p in reversed(procs):
            stop_process(p)
        raise


def cleanup_remote_temp(new):
    with contextlib.suppress(Exception):
        dual.ssh(new, "rm -f /root/.dual-ha-backhaul-candidate-*.env", timeout=9)


def finalize_old_host(old, new, role):
    if cleanup_old_remote(old, role):
        print("  Old VPS role service disabled and owned secrets removed", flush=True)
        return "completed"
    print("  Remote cleanup PENDING: old VPS unreachable. Old Iran credentials revoked.", flush=True)
    return "remote_cleanup_pending"


def swap_mieru(old, new, work):
    config = Path("/etc/dual-ha/mieru.json")
    old_bytes = saved(config, work)
    proc = None
    switched = False
    try:
        proc = stage_mieru(new, work)
        if not probe(STAGE["mieru"], new, label="NEW MIERU CANARY"):
            raise SwapError("New Mieru failed 1-MiB transfer gate; old config unchanged")
        journal(phase="cutover", role="mieru", old=old, new=new, work=str(work))
        dual.atomic_write(config, (work / "mieru.production.json").read_bytes())
        switched = True
        cmd(["systemctl", "restart", "dual-ha-mieru"], timeout=30)
        if not probe(LIVE["mieru"], new, label="LIVE MIERU"):
            raise SwapError("New live Mieru failed transfer gate")
        if not wait_gateway("mieru"):
            raise SwapError("Mieru live SOCKS passed but HAProxy did not enable the path")
        print("  LIVE MIERU + HAProxy verified; existing connections may have reconnected", flush=True)
        journal(phase="committed", role="mieru", old=old, new=new, work=str(work))
        cleanup = finalize_old_host(old, new, "mieru")
        journal(phase="completed", role="mieru", old=old, new=new, cleanup=cleanup)
        print("SUCCESS MIERU " + new + " / " + cleanup, flush=True)
        return
    except BaseException:
        if switched and (not JOURNAL.is_file() or json.loads(JOURNAL.read_text()).get("phase") != "committed"):
            print("  ROLLBACK: restoring previous Mieru config", flush=True)
            dual.atomic_write(config, old_bytes)
            cmd(["systemctl", "restart", "dual-ha-mieru"], timeout=30)
            restored = dual.active_ips()["mieru"] == old
            journal(phase="rolled_back", role="mieru", old=old, new=new, config_restored=restored)
        elif not switched:
            journal(phase="staging_failed", role="mieru", old=old, new=new)
        if not switched or json.loads(JOURNAL.read_text()).get("phase") != "committed":
            maybe_stop_candidate(new, "mieru")
        raise
    finally:
        stop_process(proc)


def swap_backhaul(old, new, iran, work):
    bundle = Path("/etc/dual-ha/backhaul-bundle.env")
    cfg = Path("/etc/dual-ha/backhaul-iran.toml")
    router = Path("/etc/dual-ha/backhaul-router.cfg")
    original = {str(p): saved(p, work) for p in (bundle, cfg, router)}
    stage_rule = None
    procs = []
    started_foreign = False
    committed = False
    guard_added = False
    had_guard = guard_exists()
    try:
        vals = stage_backhaul(new, iran, original, work)
        stage_rule = stage_firewall(new, iran)
        journal(phase="staging", role="backhaul", old=old, new=new,
                work=str(work), stage_firewall_created=True)
        procs = _start_stage(iran, work)
        dual.ssh(new, "systemctl start dual-ha-backhaul-client", timeout=25)
        started_foreign = True
        if not probe(STAGE["backhaul"], new, label="NEW BACKHAUL CANARY"):
            raise SwapError("Backhaul candidate transfer failed; production unchanged")
        # Candidate has been independently verified; stop staging before cutover.
        dual.ssh(new, "systemctl stop dual-ha-backhaul-client", timeout=20)
        for proc in reversed(procs):
            stop_process(proc)
        procs.clear()
        undo_stage_firewall(stage_rule)
        stage_rule = None
        set_foreign_port(new, 18443)
        journal(phase="cutover", role="backhaul", old=old, new=new, work=str(work))
        guard_added = True  # mark before mutation for failure-injection rollback
        begin_production_guard(new, iran)
        newbundle = work / "backhaul.foreign-bundle.env"
        dual.atomic_write(bundle, newbundle.read_bytes())
        dual.atomic_write(cfg, (work / "backhaul.production.toml").read_bytes())
        dual.atomic_write(router, (work / "router.production.cfg").read_bytes())
        committed = True
        cmd(["systemctl", "restart", "dual-ha-backhaul"], timeout=30)
        cmd(["systemctl", "restart", "dual-ha-backhaul-router"], timeout=30)
        dual.ssh(new, "systemctl enable --now dual-ha-backhaul-client", timeout=35)
        if not probe(LIVE["backhaul"], new, label="LIVE BACKHAUL"):
            raise SwapError("New production Backhaul data-plane verification failed")
        if not wait_gateway("backhaul"):
            raise SwapError("Backhaul live SOCKS passed but HAProxy did not enable the path")
        install_persistent_guard(iran)
        # A prior V3 run may have owned one INPUT jump; keep precisely one.
        if had_guard:
            ipt("-D", "INPUT", "-d", iran, "-p", "tcp", "--dport", "18443", "-j", GUARD, check=False)
        journal(phase="committed", role="backhaul", old=old, new=new, work=str(work))
        cleanup_remote_temp(new)
        cleanup = finalize_old_host(old, new, "backhaul")
        journal(phase="completed", role="backhaul", old=old, new=new, cleanup=cleanup)
        print("SUCCESS BACKHAUL " + new + " / " + cleanup, flush=True)
    except BaseException:
        if (guard_added or committed) and (not JOURNAL.is_file() or json.loads(JOURNAL.read_text()).get("phase") != "committed"):
            print("  ROLLBACK: recovering Iran Backhaul files and firewall", flush=True)
            with contextlib.suppress(Exception):
                dual.ssh(new, "systemctl disable --now dual-ha-backhaul-client", timeout=12)
            for name, old_bytes in original.items():
                dual.atomic_write(Path(name), old_bytes)
            remove_production_guard(iran, had_guard=had_guard)
            with contextlib.suppress(Exception):
                cmd(["systemctl", "restart", "dual-ha-backhaul"], timeout=25)
                cmd(["systemctl", "restart", "dual-ha-backhaul-router"], timeout=25)
            journal(phase="rolled_back", role="backhaul", old=old, new=new)
        elif not guard_added and not committed:
            journal(phase="staging_failed", role="backhaul", old=old, new=new)
        if started_foreign and json.loads(JOURNAL.read_text()).get("phase") != "committed":
            maybe_stop_candidate(new, "backhaul")
        raise
    finally:
        for proc in reversed(procs):
            stop_process(proc)
        undo_stage_firewall(stage_rule)


def reap_owned_stage(work):
    """Terminate only documented V3 stage processes with /proc ownership proof."""
    for path in work.glob("*.stage.*pid"):
        try:
            pid = int(path.read_text().strip())
            command = Path(f"/proc/{pid}/cmdline").read_bytes()
            if str(work).encode() not in command:
                continue
            os.killpg(pid, signal.SIGTERM)
        except (OSError, ValueError, ProcessLookupError):
            pass


def recover():
    """Best-effort local recovery of interrupted cutover, without any old-host SSH."""
    if os.geteuid() != 0:
        raise SwapError("Recovery requires sudo dual")
    with LOCK.open("a+") as exclusive:
        try:
            fcntl.flock(exclusive, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SwapError("Rotation still running; recovery refused")
        return _recover_locked()


def _recover_locked():
    if not JOURNAL.is_file():
        print("No pending V3 rotation", flush=True)
        return
    j = json.loads(JOURNAL.read_text())
    phase, role, old, new = j.get("phase"), j.get("role"), j.get("old"), j.get("new")
    if phase == "committed":
        print("New role already committed; checking production, do not roll back automatically.", flush=True)
        if probe(LIVE[role], new, label="RECOVER LIVE") and wait_gateway(role):
            cleanup = finalize_old_host(old, new, role)
            journal(phase="completed", role=role, old=old, new=new, cleanup=cleanup)
            print("RECOVERY_COMMITTED", flush=True)
            return
        raise SwapError("Committed role is not healthy; manual review required before recovery")
    if phase == "staging":
        work = Path(j.get("work", ""))
        if work.is_dir() and work.is_relative_to(ROOT):
            reap_owned_stage(work)
        if role == "backhaul" and j.get("stage_firewall_created") is True:
            undo_stage_firewall(["-s",new,"-d",iran,"-p","tcp", "--dport",
                                 str(STAGE_BACKHAUL_TCP),"-j","ACCEPT"])
        maybe_stop_candidate(new, role)
        journal(phase="staging_failed", role=role, old=old, new=new)
        print("Staging cleaned; production configs were not changed. Old path may still be unhealthy.", flush=True)
        return
    if phase != "cutover":
        print("No unfinished cutover; last phase: " + str(phase), flush=True)
        return
    work = Path(j["work"])
    iran = live_identity()
    if role == "mieru":
        src = work / "mieru.json.prior"
        if not src.is_file():
            raise SwapError("Missing Mieru rollback snapshot; manual intervention needed")
        dual.atomic_write(Path("/etc/dual-ha/mieru.json"), src.read_bytes())
        cmd(["systemctl", "restart", "dual-ha-mieru"])
    elif role == "backhaul":
        for p in ("backhaul-bundle.env", "backhaul-iran.toml", "backhaul-router.cfg"):
            src = work / (p + ".prior")
            if not src.is_file():
                raise SwapError("Missing Backhaul rollback snapshot; manual intervention needed")
            dual.atomic_write(Path("/etc/dual-ha") / p, src.read_bytes())
        remove_production_guard(iran, had_guard=GUARD_SCRIPT.is_file())
        cmd(["systemctl", "restart", "dual-ha-backhaul"])
        cmd(["systemctl", "restart", "dual-ha-backhaul-router"])
    else:
        raise SwapError("Invalid incomplete journal; refusing blind recovery")
    maybe_stop_candidate(new, role)
    journal(phase="rolled_back", role=role, old=old, new=new,
            note="Recovery restored old config; old host may still be down")
    print("OLD_CONFIG_RESTORED; verify sudo dual health. Previous host may be offline.", flush=True)


def rotate(role, new_ip):
    if role not in ("backhaul", "mieru"):
        raise SwapError("Unknown role")
    if os.geteuid() != 0:
        raise SwapError("Run sudo dual on Iran")
    iran = live_identity()
    new = host_ip(new_ip)
    old = host_ip(dual.active_ips()[role])
    if new in (old, iran, dual.active_ips()["mieru"], dual.active_ips()["backhaul"]):
        raise SwapError("Candidate IP conflicts with an existing endpoint")
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SwapError("Another foreign rotation is already running")
        prior_incomplete()
        for unit in ("dual-ha-v2-gateway", "dual-ha-v2-health"):
            if dual.status(unit) != "active":
                raise SwapError("Core gateway/controller unavailable: " + unit)
        if role == "backhaul" and dual.status("dual-ha-backhaul-tls") != "active":
            raise SwapError("Production Backhaul TLS not active")
        print(f"\n  DUAL V3 {HOSTS[iran]}: {role.upper()} {old} -> {new}", flush=True)
        print("  Old VPS SSH and other-path health are NOT required.", flush=True)
        print("  New VPS requires fresh SSH root access and independent fingerprint verification.", flush=True)
        verify_ssh(new)
        ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        work = ROOT / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(4))
        work.mkdir(mode=0o700)
        journal(phase="staging", role=role, old=old, new=new, work=str(work))
        try:
            if role == "mieru":
                swap_mieru(old, new, work)
            else:
                swap_backhaul(old, new, iran, work)
        finally:
            # No secret-containing run directories remain after terminal phase.
            if JOURNAL.is_file():
                state = json.loads(JOURNAL.read_text()).get("phase")
                if state in ("completed", "rolled_back", "staging_failed"):
                    shutil.rmtree(work, ignore_errors=True)