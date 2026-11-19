#!/usr/bin/env python3
"""Maya3 Backhaul2 transactional foreign VPS replacement.
Preserves original Backhaul1, Xray, HAProxy leastconn and working backend names.
Requires current active Maya3 bh2-experiment deployment. For newly provisioned
foreign nodes, uses V3 SSH onboarding (verified fingerprint, one-time password).
"""
import contextlib
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
import subprocess
import sys
import time

import dual
import dual_auto
from dual_swap_v3 import probe as canary_probe, get_weight, set_weight, ha_command

IRAN = "185.215.230.221"
CONFIG = Path("/etc/dual-ha/bh2-experiment")
BUNDLE = CONFIG / "foreign-bundle.env"
META = CONFIG / "state.json"
BH = CONFIG / "iran.toml"
ROUTER = CONFIG / "router.cfg"
TLS = CONFIG / "tls.conf"
WORK_ROOT = Path("/root/dual-bh2-rotations")
LOCK = WORK_ROOT / "lock"
JOURNAL = WORK_ROOT / "current.json"
STAGE_TLS_PORT = 18446
LIVE_TLS_PORT = 18445
STAGE_SOCKS = 21103
STAGE_BACKHAUL = 19089
STAGE_ROUTER = 19088
BACKHAUL2_UNIT = "dual-ha-bh2-server"
ROUTER2_UNIT = "dual-ha-bh2-router"
FOREIGN_UNIT = "dual-ha-backhaul-client"
GUARD = "DUAL_BH2_GUARD"
GUARD_SCRIPT = CONFIG / "bh2-guard.sh"
GUARD_UNIT = "/etc/systemd/system/dual-ha-bh2-guard.service"

def command(*args, timeout=30, check=True, input_data=None):
    r = subprocess.run(args, input=input_data, capture_output=True,
                       timeout=timeout, text=isinstance(input_data, str))
    if check and r.returncode:
        error = r.stderr if isinstance(r.stderr, str) else (r.stderr or b"").decode(errors="replace")
        raise RuntimeError("Command failed (" + str(r.returncode) + "): " + " ".join(args[:3]) + " " + error[-400:])
    return r

def must(condition, message):
    if not condition:
        raise RuntimeError("STOP: " + message)

def atomic_bytes(path, data):
    tmp = path.with_name(path.name + "." + secrets.token_hex(5) + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)
    os.chmod(path, 0o600)

def atomic(path, text):
    atomic_bytes(path, text.encode())

def status(unit):
    return command("systemctl", "is-active", "--quiet", unit, check=False).returncode == 0

def metadata():
    m = json.loads(META.read_text())
    must(m.get("mode") == "active", "Second Backhaul is not in active mode")
    return m

def bundle():
    data = {}
    for line in BUNDLE.read_text().splitlines():
        m = re.fullmatch(r"([A-Z_]+)='([^']*)'", line)
        if m:
            data[m.group(1)] = m.group(2)
    return data

def guard_install():
    # Own chain only; no global firewall flush or unrelated rules modified.
    script = """#!/usr/bin/env bash
set -Eeuo pipefail
IP="$(python3 -c 'import json;print(json.load(open("/etc/dual-ha/bh2-experiment/state.json"))["foreign_ip"])')"
[[ "$IP" =~ ^[0-9.]+$ ]] || exit 2
iptables -w -N DUAL_BH2_GUARD 2>/dev/null || true
iptables -w -F DUAL_BH2_GUARD
iptables -w -A DUAL_BH2_GUARD -s "$IP" -j ACCEPT
iptables -w -A DUAL_BH2_GUARD -j REJECT --reject-with tcp-reset
iptables -w -C INPUT -d 185.215.230.221 -p tcp --dport 18445 -j DUAL_BH2_GUARD 2>/dev/null ||
  iptables -w -I INPUT 1 -d 185.215.230.221 -p tcp --dport 18445 -j DUAL_BH2_GUARD
"""
    atomic(GUARD_SCRIPT, script)
    os.chmod(GUARD_SCRIPT, 0o700)
    unit = """[Unit]
Description=Owned Maya3 Backhaul2 reverse-source firewall guard
After=network-pre.target
Before=dual-ha-bh2-tls.service
[Service]
Type=oneshot
ExecStart=/etc/dual-ha/bh2-experiment/bh2-guard.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
"""
    if not Path(GUARD_UNIT).exists():
        atomic(Path(GUARD_UNIT), unit)
        os.chmod(GUARD_UNIT, 0o644)
    command("systemctl", "daemon-reload")
    command("systemctl", "enable", "dual-ha-bh2-guard.service")
    command(str(GUARD_SCRIPT))

def guard_restore_meta(meta_bytes):
    atomic_bytes(META, meta_bytes)
    if GUARD_SCRIPT.exists():
        command(str(GUARD_SCRIPT), check=False)

def guard_remove_if_temp():
    # If guard was newly installed by failed operation, retaining its chain is
    # safe only after restoring the original foreign IP in metadata.
    if GUARD_SCRIPT.exists():
        command(str(GUARD_SCRIPT), check=False)

def make_journal(phase, *, old, new, work):
    WORK_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    atomic(JOURNAL, json.dumps({"format": "DUAL_BH2_V1", "phase": phase,
                 "old": old, "new": new, "work": str(work),
                 "updated": int(time.time())}, indent=2) + "\n")

def prepare_local(old, new, work):
    original = bundle()
    must(original.get("BH_IRAN_IP") == IRAN, "Not Maya3 bundle")
    must(original.get("BH_FOREIGN_IP") == old, "Active Backhaul2 bundle IP mismatch")
    for file in (BH, ROUTER, TLS, META, BUNDLE):
        must(file.is_file() and not file.is_symlink(), "Missing/untrusted " + str(file))
        shutil.copy2(file, work / (file.name + ".prior"))
    old_cfg = BH.read_text()
    old_router = ROUTER.read_text()
    old_tls = TLS.read_text()
    port_re = re.findall(r'(?m)^  bind 127\.0\.0\.1:(\d+)$', old_router)
    must(len(port_re) == 1, "Cannot parse current BH2 local router binding")
    local_router_port = port_re[0]
    must("accept = 0.0.0.0:18445" in old_tls and
         old_tls.count("connect = 127.0.0.1:" + local_router_port) == 1,
         "BH2 TLS/router mismatch")
    must(old_cfg.count('127.0.0.1:19085') == 1, "BH2 server binding mismatch")
    must(old_cfg.count('127.0.0.1:21002=127.0.0.1:11080') == 1, "BH2 SOCKS mapping mismatch")
    for key, field in [("BH_TOKEN", "token"), ("BH_CONTROL_PATH", "ws_control_path"),
                       ("BH_TUNNEL_PATH", "ws_tunnel_path")]:
        must(old_cfg.count(field + ' = "' + original[key] + '"') == 1,
             "BH2 credential mismatch: " + key)
    # Fresh secret and WebSocket paths are different from BOTH current paths.
    nextdata = dict(original,
                    BH_FOREIGN_IP=new, BH_TOKEN=secrets.token_hex(32),
                    BH_CONTROL_PATH="/assets/" + secrets.token_hex(16),
                    BH_TUNNEL_PATH="/socket/" + secrets.token_hex(16))
    new_cfg, new_router = old_cfg, old_router
    for key, field in [("BH_TOKEN", "token"), ("BH_CONTROL_PATH", "ws_control_path"),
                       ("BH_TUNNEL_PATH", "ws_tunnel_path")]:
        new_cfg = new_cfg.replace(original[key], nextdata[key])
        if key != "BH_TOKEN":
            new_router = new_router.replace(original[key], nextdata[key])
    new_bundle = "".join(k + "='" + nextdata[k] + "'\n" for k in
                         ("BH_DOMAIN", "BH_IRAN_IP", "BH_TOKEN",
                          "BH_CONTROL_PATH", "BH_TUNNEL_PATH",
                          "BH_FOREIGN_IP", "BH_TLS_PORT"))
    atomic(work / "candidate.env", new_bundle)
    atomic(work / "live.toml", new_cfg)
    atomic(work / "live-router.cfg", new_router)
    atomic(work / "stage.toml", new_cfg.replace("127.0.0.1:19085", "127.0.0.1:19089")
           .replace("127.0.0.1:21002=127.0.0.1:11080",
                    "127.0.0.1:21103=127.0.0.1:11080"))
    atomic(work / "stage-router.cfg",
           new_router.replace("bind 127.0.0.1:" + local_router_port,
                              "bind 127.0.0.1:19088")
           .replace("server backhaul2 127.0.0.1:19085",
                    "server backhaul2 127.0.0.1:19089"))
    atomic(work / "stage-tls.conf",
           old_tls.replace("accept = 0.0.0.0:18445",
                           "accept = 0.0.0.0:18446")
           .replace("connect = 127.0.0.1:" + local_router_port,
                    "connect = 127.0.0.1:19088"))
    must("bind 127.0.0.1:19088" in (work / "stage-router.cfg").read_text(),
         "Staging router binding generation failed")
    command("/usr/sbin/haproxy", "-c", "-f", str(work / "stage-router.cfg"))
    return nextdata

def temporary_firewall(new, action):
    args = ("-s", new, "-d", IRAN, "-p", "tcp",
            "--dport", str(STAGE_TLS_PORT), "-j", "ACCEPT")
    if action == "add":
        command("iptables", "-w", "-I", "INPUT", "1", *args)
    else:
        command("iptables", "-w", "-D", "INPUT", *args, check=False)

def remote_port(new, new_port):
    must(new_port in (18445, 18446), "Invalid candidate TLS port")
    code = ("""
from pathlib import Path
import re,sys
p=Path('/etc/dual-ha/backhaul-foreign.toml')
s=p.read_text()
m=re.findall(r'(?m)^remote_addr = "([^"]+):(?:18443|18445|18446)"$',s)
assert len(m)==1, 'Unrecognized foreign config'
assert s.count('transport = "wssmux"')==1
assert 'tls_skip_verify = false' in s
s=re.sub(r'(?m)^remote_addr = "([^"]+):(?:18443|18445|18446)"$',
         lambda x:'remote_addr = "'+x.group(1)+':'+str(sys.argv[1])+'"',s)
p.write_text(s)
""")
    dual.ssh(new, "python3 -c " + shlex.quote(code) + " " + str(new_port), timeout=20)

def run_stage(work):
    files = [
        ["/opt/dual-ha/bin/backhaul", "-c", str(work / "stage.toml")],
        ["/usr/sbin/haproxy", "-W", "-db", "-f", str(work / "stage-router.cfg")],
        ["/usr/bin/stunnel", str(work / "stage-tls.conf")]
    ]
    procs = []
    for idx, args in enumerate(files):
        log = open(work / ("stage-%d.log" % idx), "wb")
        try:
            p = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=log, start_new_session=True)
            procs.append(p)
        finally:
            log.close()
    return procs

def stop_stage(processes):
    for p in reversed(processes):
        if p.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(p.pid, signal.SIGKILL)

def wait_ready(port, ip, seconds=60):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        r = command("curl", "-q", "-4", "--noproxy", "",
                    "--socks5-hostname", "127.0.0.1:" + str(port),
                    "--connect-timeout", "4", "--max-time", "7",
                    "-fsS", "https://www.cloudflare.com/cdn-cgi/trace",
                    timeout=10, check=False)
        if r.returncode == 0 and "ip=" + ip in r.stdout.splitlines():
            return
        time.sleep(2)
    raise RuntimeError("New reverse SOCKS did not become ready (expected " + ip + ")")

def replace(new):
    if os.geteuid() != 0:
        raise RuntimeError("Run as root")
    address = ipaddress.ip_address(new)
    must(address.version == 4 and address.is_global, "Invalid new foreign IPv4")
    m = metadata()
    must(dual.iran_ip() == IRAN, "Not Maya3")
    old = m["foreign_ip"]
    main_ip = dual.read_bundle()["BH_FOREIGN_IP"]
    must(new not in (old, main_ip, IRAN, m.get("old_mieru_ip")), "New VPS overlaps another role")
    for service in ("dual-ha-v2-gateway", "dual-ha-v2-health",
                    BACKHAUL2_UNIT, ROUTER2_UNIT, "dual-ha-bh2-tls"):
        must(status(service), "Service not active: " + service)
    must(not status("dual-ha-mieru"), "Mieru must remain inactive")
    for port in (18446, STAGE_SOCKS, STAGE_BACKHAUL, STAGE_ROUTER):
        r = command("ss", "-Htan", "( sport = :" + str(port) + " )", check=False)
        must(not r.stdout.strip(), "Stage port in use: " + str(port))
    WORK_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with LOCK.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if JOURNAL.exists():
            record = json.loads(JOURNAL.read_text())
            must(record["phase"] in ("completed", "staging_failed", "rolled_back"),
                 "Incomplete previous swap: use recover, do not overwrite backups")
        print("\nMAYA3 BACKHAUL2: " + old + " -> " + new, flush=True)
        print("Original Backhaul1 / HAProxy leastconn / Xray untouched.", flush=True)
        print("New VPS requires independently verified SSH fingerprint.", flush=True)
        dual_auto.authorize_new(new)
        work = WORK_ROOT / (time.strftime("%Y%m%dT%H%M%SZ",time.gmtime()) +
                            "-" + secrets.token_hex(4))
        work.mkdir(mode=0o700)
        make_journal("staging", old=old, new=new, work=work)
        processes = []
        fw = False
        remote_started = False
        cutover = False
        old_weight = get_weight("mieru")
        try:
            newdata = prepare_local(old, new, work)
            dual_auto.prepared_backhaul_install(new, IRAN, work / "candidate.env")
            temporary_firewall(new, "add")
            fw = True
            remote_port(new, STAGE_TLS_PORT)
            processes = run_stage(work)
            dual.ssh(new, "systemctl start " + FOREIGN_UNIT, timeout=25)
            remote_started = True
            wait_ready(STAGE_SOCKS, new)
            must(canary_probe(STAGE_SOCKS, new, label="BACKHAUL2 STAGE CANARY"),
                 "Candidate real-download gate failed; production remains unchanged")
            dual.ssh(new, "systemctl stop " + FOREIGN_UNIT, timeout=20)
            remote_started = False
            stop_stage(processes)
            processes.clear()
            temporary_firewall(new, "del")
            fw = False
            remote_port(new, LIVE_TLS_PORT)
            make_journal("cutover", old=old, new=new, work=work)
            cutover = True
            # Guard SOURCE before making current port serve the candidate.
            # Prevent an old foreign client from re-registering port 21002.
            new_state = dict(m, foreign_ip=new)
            atomic(META, json.dumps(new_state, indent=2) + "\n")
            guard_install()
            atomic_bytes(BUNDLE, (work / "candidate.env").read_bytes())
            atomic_bytes(BH, (work / "live.toml").read_bytes())
            atomic_bytes(ROUTER, (work / "live-router.cfg").read_bytes())
            command("systemctl", "restart", BACKHAUL2_UNIT, timeout=35)
            command("systemctl", "restart", ROUTER2_UNIT, timeout=35)
            dual.ssh(new, "systemctl enable --now " + FOREIGN_UNIT, timeout=35)
            remote_started = True
            wait_ready(21002, new)
            must(canary_probe(21002, new, label="BACKHAUL2 LIVE CANARY"),
                 "Live second Backhaul full transfer gate failed")
            if old_weight == 0:
                if get_weight("mieru") != 0:
                    set_weight("mieru", 0)
                print("Live Backhaul2 verified; intentionally retained weight=0.", flush=True)
            else:
                if get_weight("mieru") == 0:
                    set_weight("mieru", old_weight)
                # Controller re-enables after bulk probes; do not restart HAProxy.
            make_journal("completed", old=old, new=new, work=work)
            print("SUCCESS BACKHAUL2 " + new + " | original Backhaul1 untouched", flush=True)
            print("Old foreign node not contacted; its config remains untouched.", flush=True)
        except BaseException:
            print("REPLACEMENT FAILED: staging/rollback in progress", flush=True)
            if remote_started:
                with contextlib.suppress(Exception):
                    dual.ssh(new, "systemctl disable --now " + FOREIGN_UNIT, timeout=12)
            if cutover:
                # Restore previous source allowlist and ORIGINAL SECOND-PATH configs.
                for path in (BUNDLE, BH, ROUTER, META):
                    prior = work / (path.name + ".prior")
                    if prior.is_file():
                        atomic_bytes(path, prior.read_bytes())
                guard_remove_if_temp()
                with contextlib.suppress(Exception):
                    command("systemctl", "restart", BACKHAUL2_UNIT, timeout=25)
                    command("systemctl", "restart", ROUTER2_UNIT, timeout=25)
                with contextlib.suppress(Exception):
                    set_weight("mieru", old_weight)
                make_journal("rolled_back", old=old, new=new, work=work)
            else:
                make_journal("staging_failed", old=old, new=new, work=work)
            raise
        finally:
            stop_stage(processes)
            if fw:
                temporary_firewall(new, "del")

def recover():
    if os.geteuid() != 0: raise RuntimeError("Root required")
    if not JOURNAL.exists(): print("No Backhaul2 swap journal"); return
    record = json.loads(JOURNAL.read_text())
    phase = record["phase"]
    if phase not in ("cutover", "staging"):
        print("No incomplete cutover: " + phase); return
    work = Path(record["work"])
    must(work.parent == WORK_ROOT and work.is_dir(), "Untrusted recovery directory")
    m = metadata()
    if phase == "cutover":
        for path in (BUNDLE, BH, ROUTER, META):
            prior = work / (path.name + ".prior")
            must(prior.is_file(), "Missing rollback snapshot: " + str(prior))
        for path in (BUNDLE, BH, ROUTER, META):
            atomic_bytes(path, (work / (path.name + ".prior")).read_bytes())
        guard_remove_if_temp()
        command("systemctl", "restart", BACKHAUL2_UNIT)
        command("systemctl", "restart", ROUTER2_UNIT)
        print("Original Backhaul2 local config restored; confirm original VPS reconnects")
    else:
        print("Incomplete STAGING: no live production files were changed.")
    make_journal("rolled_back" if phase == "cutover" else "staging_failed",
                 old=record["old"], new=record["new"], work=work)

if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "replace":
        replace(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "recover":
        recover()
    else:
        print("Usage: dual-backhaul2-rotate.py replace NEW_IP | recover", file=sys.stderr)
        sys.exit(2)
