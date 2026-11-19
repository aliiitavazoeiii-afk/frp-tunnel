#!/usr/bin/env python3
"""Maya3 experiment: replace Mieru SOCKS :21002 with independent Backhaul2.
Does not modify HAProxy config, controller, original Backhaul, x-ui or Xray.
Commands: prepare IP DOMAIN | switch | rollback | status
"""
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time

IRAN = "185.215.230.221"
BASE = Path("/etc/dual-ha")
DIR = BASE / "bh2-experiment"
META = DIR / "state.json"
BH = DIR / "iran.toml"
ROUTER = DIR / "router.cfg"
TLS = DIR / "tls.conf"
BUNDLE = DIR / "foreign-bundle.env"
PORT_STAGE = 21102
PORT_LIVE = 21002
PORT_TLS = 18445
SOCKS_EGRESS = 11080
SERVICES = ("dual-ha-bh2-server", "dual-ha-bh2-router", "dual-ha-bh2-tls")
SSH_SERVICES = ("dual-ha-backhaul", "dual-ha-backhaul-tls", "dual-ha-v2-gateway", "dual-ha-v2-health")

def run(*argv, check=True, timeout=30):
    r = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError("Command failed: " + " ".join(argv[:3]) + ": " + r.stderr[-700:])
    return r

def active(unit):
    return run("systemctl", "is-active", "--quiet", unit, check=False).returncode == 0

def enabled(unit):
    return run("systemctl", "is-enabled", "--quiet", unit, check=False).returncode == 0

def ssh_safe_ipv4(text):
    try:
        x = ipaddress.ip_address(text)
        if x.version != 4 or not x.is_global:
            raise ValueError("not a global IPv4")
        return str(x)
    except ValueError as e:
        raise RuntimeError("Invalid public IPv4: " + text) from e

def read_bundle():
    vals = {}
    for row in (BASE / "backhaul-bundle.env").read_text().splitlines():
        m = re.fullmatch(r"([A-Z_]+)='([^']*)'", row)
        if m:
            vals[m.group(1)] = m.group(2)
    return vals

def identity():
    primary = read_bundle()
    if primary.get("BH_IRAN_IP") != IRAN:
        raise RuntimeError("REFUSED: this utility is for Maya3 only")
    for unit in SSH_SERVICES:
        if not active(unit):
            raise RuntimeError("Required production service is not active: " + unit)
    if not Path("/opt/dual-ha/bin/backhaul").is_file():
        raise RuntimeError("Custom Backhaul binary missing")
    return primary

def listening(port):
    with socket.socket() as s:
        s.settimeout(.5)
        return s.connect_ex(("127.0.0.1", port)) == 0

def atomic(path, contents, mode=0o600):
    tmp = path.with_name(path.name + ".new")
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
    with os.fdopen(fd, "w") as f:
        f.write(contents)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    os.chmod(path, mode)

def save_meta(data):
    atomic(META, json.dumps(data, indent=2) + "\n")

def load_meta():
    if not META.is_file():
        raise RuntimeError("No experiment prepared on Maya3")
    return json.loads(META.read_text())

def cert_for(domain):
    cert = Path("/etc/letsencrypt/live") / domain / "fullchain.pem"
    key = Path("/etc/letsencrypt/live") / domain / "privkey.pem"
    if not cert.is_file() or not key.is_file():
        raise RuntimeError("Valid pre-existing certificate required (no certbot/port 80 changes): " + domain)
    run("openssl", "x509", "-in", str(cert), "-noout", "-checkhost", domain)
    run("openssl", "x509", "-in", str(cert), "-noout", "-checkend", "604800")
    return cert, key

def probe(port, expected_ip, *, thorough=False):
    urls = [
        ("https://www.cloudflare.com/cdn-cgi/trace", "trace"),
        ("https://www.gstatic.com/generate_204", "204")
    ]
    if thorough:
        urls.append(("https://speed.cloudflare.com/__down?bytes=1048576", "download"))
        urls.append(("https://speed.cloudflare.com/__down?bytes=1048576", "download"))
    for url, target in urls:
        args = ("curl", "-q", "-4", "--noproxy", "", "--socks5-hostname",
                "127.0.0.1:" + str(port), "--connect-timeout", "5",
                "--max-time", "25" if target == "download" else "12",
                "--fail", "--silent", "--show-error")
        if target == "trace":
            r = run(*args, url, check=False, timeout=17)
            if r.returncode != 0 or ("ip=" + expected_ip) not in r.stdout.splitlines():
                raise RuntimeError("SOCKS " + str(port) + " wrong egress or trace timeout")
        elif target == "204":
            r = run(*args, "-o", "/dev/null", "-w", "%{http_code}", url, check=False, timeout=17)
            if r.returncode != 0 or r.stdout.strip() != "204":
                raise RuntimeError("SOCKS " + str(port) + " failed HTTPS 204")
        else:
            r = run(*args, "-o", "/dev/null", "-w", "%{http_code} %{size_download}", url, check=False, timeout=30)
            if r.returncode != 0 or r.stdout.strip() != "200 1048576":
                raise RuntimeError("SOCKS " + str(port) + " failed 1-MiB download")
    print("PASS: verified foreign IP, HTTPS, and " +
          ("2 x 1 MiB downloads" if thorough else "connectivity"), flush=True)

def create_units():
    units = {
        SERVICES[0]: ("/opt/dual-ha/bin/backhaul", "-c", str(BH)),
        SERVICES[1]: ("/usr/sbin/haproxy", "-W", "-db", "-f", str(ROUTER)),
        SERVICES[2]: ("/usr/bin/stunnel", str(TLS)),
    }
    for name, argv in units.items():
        unit = Path("/etc/systemd/system") / (name + ".service")
        if unit.exists():
            raise RuntimeError("Existing service unit collision: " + str(unit))
    for name, argv in units.items():
        text = ("[Unit]\nDescription=Maya3 second Backhaul experiment " + name +
                "\nAfter=network-online.target\nWants=network-online.target\n" +
                "[Service]\nType=simple\nExecStart=" + " ".join(argv) +
                "\nRestart=on-failure\nRestartSec=3\nLimitNOFILE=65536\n" +
                "[Install]\nWantedBy=multi-user.target\n")
        atomic(Path("/etc/systemd/system") / (name + ".service"), text, 0o644)
    run("systemctl", "daemon-reload")

def fw_add(ip):
    rule = ("-s", ip, "-d", IRAN, "-p", "tcp", "--dport", str(PORT_TLS),
            "-m", "comment", "--comment", "maya3-bh2-test", "-j", "ACCEPT")
    if run("iptables", "-w", "-C", "INPUT", *rule, check=False).returncode:
        run("iptables", "-w", "-I", "INPUT", "1", *rule)
    return rule

def fw_del(ip):
    rule = ("-s", ip, "-d", IRAN, "-p", "tcp", "--dport", str(PORT_TLS),
            "-m", "comment", "--comment", "maya3-bh2-test", "-j", "ACCEPT")
    if run("iptables", "-w", "-C", "INPUT", *rule, check=False).returncode == 0:
        run("iptables", "-w", "-D", "INPUT", *rule)

def configure(port):
    s = BH.read_text()
    old = "127.0.0.1:21102=127.0.0.1:11080"
    new = "127.0.0.1:21002=127.0.0.1:11080"
    if s.count(old) + s.count(new) != 1:
        raise RuntimeError("Backhaul2 config is unexpected: refusing edit")
    desired = old if port == PORT_STAGE else new
    atomic(BH, s.replace(new, desired).replace(old, desired))

def prepare(ip, domain):
    primary = identity()
    ip = ssh_safe_ipv4(ip)
    if ip in (IRAN, primary.get("BH_FOREIGN_IP")):
        raise RuntimeError("Second Backhaul needs a different foreign VPS")
    if not re.fullmatch(r"(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,63}", domain):
        raise RuntimeError("Invalid DNS hostname")
    if DIR.exists() or any(Path("/etc/systemd/system/" + s + ".service").exists() for s in SERVICES):
        raise RuntimeError("Existing experiment found; use status/rollback, no overwrite")
    mr = json.loads((BASE / "mieru.json").read_text())
    mieru_ip = mr["profiles"][0]["servers"][0]["ipAddress"]
    if ip == mieru_ip:
        raise RuntimeError("A NEW dedicated VPS is required; do not destroy Mieru rollback host")
    ips = set(run("getent", "ahostsv4", domain).stdout.split())
    rows = run("getent", "ahostsv4", domain).stdout.splitlines()
    resolved = {r.split()[0] for r in rows if r.strip()}
    if resolved != {IRAN}:
        raise RuntimeError("Domain must be DNS-only A record to " + IRAN +
                           "; observed=" + repr(sorted(resolved)))
    cert, key = cert_for(domain)
    for port in (PORT_TLS, 19084, 19085, PORT_STAGE):
        if listening(port):
            raise RuntimeError("Port already occupied: " + str(port))
    for binpath in ("/usr/sbin/haproxy", "/usr/bin/stunnel", "/usr/sbin/iptables"):
        if not Path(binpath).is_file():
            raise RuntimeError("Missing prerequisite (no apt changes allowed): " + binpath)
    DIR.mkdir(mode=0o700, parents=False)
    try:
        token = secrets.token_hex(32)
        ctrl = "/assets/" + secrets.token_hex(16)
        tunnel = "/socket/" + secrets.token_hex(16)
        bundle = (
            "BH_DOMAIN='" + domain + "'\nBH_IRAN_IP='" + IRAN +
            "'\nBH_FOREIGN_IP='" + ip + "'\nBH_TOKEN='" + token +
            "'\nBH_CONTROL_PATH='" + ctrl + "'\nBH_TUNNEL_PATH='" + tunnel +
            "'\nBH_TLS_PORT='18443'\n"
        )
        atomic(BUNDLE, bundle)
        atomic(BH, (
            '[server]\nbind_addr = "127.0.0.1:19085"\ntransport = "wsmux"\n' +
            'token = "' + token + '"\nws_control_path = "' + ctrl +
            '"\nws_tunnel_path = "' + tunnel + '"\n' +
            "keepalive_period = 75\nheartbeat = 40\nnodelay = true\n" +
            "channel_size = 4096\nmux_con = 16\nmux_version = 1\n" +
            "mux_framesize = 32768\nmux_recievebuffer = 4194304\n" +
            "mux_streambuffer = 65536\nsniffer = false\nweb_port = 0\n" +
            'log_level = "info"\nports = [\n  "127.0.0.1:21102=127.0.0.1:11080"\n]\n'
        ))
        atomic(ROUTER, (
            "global\n  maxconn 20000\ndefaults\n  mode http\n" +
            "  timeout connect 5s\n  timeout client 1h\n  timeout server 1h\n" +
            "  timeout tunnel 12h\n  timeout http-request 10s\n" +
            "frontend ingress\n  bind 127.0.0.1:19084\n" +
            "  acl control_path path -i " + ctrl + "\n" +
            "  acl tunnel_path path_beg " + tunnel + "/\n" +
            "  http-request return status 200 content-type text/plain string OK if { path / }\n" +
            "  http-request return status 404 content-type text/plain string NotFound unless control_path or tunnel_path\n" +
            "  use_backend wsmux if control_path or tunnel_path\n" +
            "backend wsmux\n  server backhaul2 127.0.0.1:19085\n"
        ), 0o640)
        atomic(TLS, (
            "foreground = yes\nsyslog = no\ndebug = notice\n" +
            "socket = l:TCP_NODELAY=1\nsocket = r:TCP_NODELAY=1\n" +
            "[maya3-independent-backhaul2]\n" +
            "accept = 0.0.0.0:18445\nconnect = 127.0.0.1:19084\n" +
            "cert = " + str(cert) + "\nkey = " + str(key) +
            "\nsslVersionMin = TLSv1.2\nTIMEOUTconnect = 10\nTIMEOUTidle = 43200\n"
        ))
        run("/usr/sbin/haproxy", "-c", "-f", str(ROUTER))
        state = {"mode": "staged", "foreign_ip": ip, "domain": domain,
                 "old_mieru_ip": mieru_ip, "primary_ip": primary["BH_FOREIGN_IP"],
                 "original_mieru_enabled": enabled("dual-ha-mieru"),
                 "original_mieru_active": active("dual-ha-mieru")}
        shutil.copy2(BASE / "mieru.json", DIR / "mieru.original.json")
        os.chmod(DIR / "mieru.original.json", 0o600)
        unit = Path("/etc/systemd/system/dual-ha-mieru.service")
        if unit.exists():
            shutil.copy2(unit, DIR / "mieru.original.service")
            os.chmod(DIR / "mieru.original.service", 0o600)
        save_meta(state)
        create_units()
        fw_add(ip)
        for unit in SERVICES:
            run("systemctl", "enable", "--now", unit)
        print("STAGED: Backhaul2 server listening on TCP 18445; SOCKS staging 21102")
        print("Mieru, production Backhaul, HAProxy and Xray not modified.")
        print("NEXT: provision FRESH foreign VPS using bundle " + str(BUNDLE))
        print("NOTE: bundle BH_TLS_PORT=18443 for legacy foreign installer; change only remote_addr to :18445 before starting foreign reverse service.")
    except BaseException:
        print("PREPARE FAILED: partial experiment files may exist. Review status/rollback before retry.", file=sys.stderr)
        raise

def switch():
    primary = identity()
    data = load_meta()
    if data["mode"] != "staged":
        raise RuntimeError("Expected staged experiment; mode=" + data["mode"])
    if primary["BH_FOREIGN_IP"] != data["primary_ip"]:
        raise RuntimeError("Primary Backhaul changed since staging")
    if active("dual-ha-mieru") and not listening(PORT_LIVE):
        raise RuntimeError("Mieru unexpectedly has no SOCKS listener")
    print("Checking original Backhaul :21001 ...", flush=True)
    probe(21001, data["primary_ip"], thorough=True)
    print("Checking independent Backhaul2 CANARY :21102 ...", flush=True)
    probe(PORT_STAGE, data["foreign_ip"], thorough=True)
    try:
        run("systemctl", "disable", "--now", "dual-ha-mieru")
        configure(PORT_LIVE)
        run("systemctl", "restart", SERVICES[0])
        for i in range(12):
            try:
                probe(PORT_LIVE, data["foreign_ip"], thorough=False)
                break
            except (RuntimeError, subprocess.TimeoutExpired):
                if i == 11: raise
                time.sleep(2)
        probe(PORT_LIVE, data["foreign_ip"], thorough=True)
        data["mode"] = "active"
        save_meta(data)
        print("SUCCESS: Backhaul1 :21001 + independent Backhaul2 :21002.")
        print("HAProxy remains unchanged: backend named 'mieru' now carries Backhaul2.")
        print("IMPORTANT: sudo dual status will mislabel second path; use this script status.")
    except BaseException:
        print("CUTOVER FAILED: restoring Mieru service and staging config.", file=sys.stderr)
        run("systemctl", "stop", SERVICES[0], check=False)
        configure(PORT_STAGE)
        run("systemctl", "start", SERVICES[0], check=False)
        if data["original_mieru_enabled"]:
            run("systemctl", "enable", "dual-ha-mieru", check=False)
        if data["original_mieru_active"]:
            run("systemctl", "start", "dual-ha-mieru", check=False)
        raise

def rollback():
    identity()
    data = load_meta()
    run("systemctl", "stop", SERVICES[0], check=False)
    configure(PORT_STAGE)
    for unit in reversed(SERVICES):
        run("systemctl", "disable", "--now", unit, check=False)
    fw_del(data["foreign_ip"])
    if not (BASE / "mieru.json").read_bytes() == (DIR / "mieru.original.json").read_bytes():
        raise RuntimeError("Mieru config changed externally; refusing automatic restore")
    run("systemctl", "enable", "--now", "dual-ha-mieru")
    data["mode"] = "rolled_back"
    save_meta(data)
    print("ROLLED BACK: original Mieru service enabled again. Mieru config was never changed.")
    print("Foreign Backhaul2 should be stopped on its separate VPS.")
    print("If original Mieru IP is filtered, rollback cannot make that route healthy.")

def status():
    primary = read_bundle()
    print("MAYA3 IRAN: " + primary.get("BH_IRAN_IP", "?"))
    print("PRIMARY BACKHAUL: " + primary.get("BH_FOREIGN_IP", "?"))
    print("Mieru service: " + ("active" if active("dual-ha-mieru") else "inactive"))
    if META.exists():
        data = load_meta()
        print("BACKHAUL2: " + data["foreign_ip"] + " mode=" + data["mode"])
        print("FOREIGN PORT: " + str(PORT_TLS))
        for p in (PORT_STAGE, PORT_LIVE):
            if listening(p): print("LOCAL LISTENING: " + str(p))
    print("HAProxy config/controller: UNMODIFIED")

def main():
    if os.geteuid() != 0:
        raise RuntimeError("Run as root")
    if len(sys.argv) == 4 and sys.argv[1] == "prepare":
        prepare(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 2 and sys.argv[1] == "switch":
        switch()
    elif len(sys.argv) == 2 and sys.argv[1] == "rollback":
        rollback()
    elif len(sys.argv) == 2 and sys.argv[1] == "status":
        status()
    else:
        raise RuntimeError("Usage: script.py prepare NEW_FOREIGN_IP BH2_DOMAIN | switch | rollback | status")

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError, KeyError) as e:
        print("ERROR: " + str(e), file=sys.stderr)
        sys.exit(1)
