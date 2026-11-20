#!/usr/bin/env python3
"""Maya1 read-only readiness for dual independent WSSMux Backhaul migration.

NO writes, services, connections to public proxy endpoints, credential reads,
or configuration dumps. Does not install packages, certificates or DNS.
Run ON Maya1 (94.184.4.38) with root.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

IRAN="94.184.4.38"
B1="82.152.132.159"
B2="152.237.230.77"
DOMAIN="bh-new.biya2film.top"
PORTS=(22,80,443,18443,18444,18445,18446,19080,19081,19084,19085,
       21001,21002,21101,21102,21103,11080,18080)
SERVICES=(
    "x-ui","xray","dual-ha-backhaul","dual-ha-backhaul-router",
    "dual-ha-backhaul-tls","dual-ha-mieru","dual-ha-bh2-server",
    "dual-ha-bh2-router","dual-ha-bh2-tls",
    "dual-ha-v2-gateway","dual-ha-v2-health","haproxy",
    "stunnel4","certbot.timer",
)
SENSITIVE=(
    "/etc/dual-ha/backhaul-bundle.env",
    "/etc/dual-ha/backhaul-iran.toml",
    "/etc/dual-ha/backhaul-router.cfg",
    "/etc/dual-ha/backhaul-stunnel.conf",
    "/etc/dual-ha/mieru.json",
    "/etc/dual-ha/bh2-experiment/state.json",
    "/etc/dual-ha/bh2-experiment/iran.toml",
    "/etc/dual-ha/bh2-experiment/tls.conf",
    "/etc/dual-ha/v2/haproxy.cfg",
    "/run/dual-ha-v2/health.json",
    "/opt/dual-ha/bin/backhaul",
    "/opt/dual-ha/controller.py",
    "/usr/local/bin/dual",
)
def call(argv, timeout=8):
    try:
        return subprocess.run(argv,capture_output=True,text=True,
                              timeout=timeout,check=False)
    except (OSError,subprocess.TimeoutExpired):
        return None

def active(unit):
    r=call(["systemctl","is-active",unit],3)
    return r.stdout.strip() if r and r.returncode==0 else "not-active"

def dns():
    try:
        result=socket.getaddrinfo(DOMAIN,None,socket.AF_INET,
                                  socket.SOCK_STREAM)
        ips=sorted({str(ipaddress.ip_address(r[4][0])) for r in result})
    except (socket.gaierror,ValueError):
        ips=[]
    return ips

def port_listeners():
    r=call(["ss","-Hlnpt"],10)
    if r is None or r.returncode:
        return {}
    out={}
    for line in r.stdout.splitlines():
        cols=line.split()
        if len(cols)<5:continue
        m=re.search(r":(\d+)$",cols[3])
        if not m:continue
        port=int(m.group(1))
        if port not in PORTS:continue
        # Show only executable name, not full cmdline / potentially secret args.
        proc=re.search(r'\(\("([^"]+)"',line)
        out.setdefault(port,set()).add(proc.group(1) if proc else "listener")
    return {p:sorted(v) for p,v in out.items()}

def masked_bundle():
    env=Path("/etc/dual-ha/backhaul-bundle.env")
    result={}
    try:
        for line in env.read_text().splitlines():
            m=re.fullmatch(r"([A-Z_]+)='([^']*)'",line)
            if m and m.group(1) in ("BH_IRAN_IP","BH_FOREIGN_IP","BH_DOMAIN","BH_TLS_PORT"):
                result[m.group(1)]=m.group(2)
    except (OSError,UnicodeError):
        pass
    return result

def cert_status():
    cert=Path("/etc/letsencrypt/live")/DOMAIN/"fullchain.pem"
    key=Path("/etc/letsencrypt/live")/DOMAIN/"privkey.pem"
    if not cert.is_file() or not key.is_file():
        return "MISSING"
    host=call(["openssl","x509","-in",str(cert),"-noout","-checkhost",DOMAIN],8)
    valid=call(["openssl","x509","-in",str(cert),"-noout","-checkend","604800"],8)
    if not host or not valid:return "UNVERIFIED"
    return "VALID_7D" if host.returncode==0 and valid.returncode==0 else "INVALID_OR_EXPIRES"

def haproxy_stats():
    path="/run/dual-ha-v2/haproxy.sock"
    if not Path(path).exists():return {"reason":"NO_HAPROXY_SOCKET"}
    rows={}
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(2)
            s.connect(path)
            s.sendall(b"show stat\n")
            s.shutdown(socket.SHUT_WR)
            chunks=[];size=0
            while True:
                chunk=s.recv(65536)
                if not chunk:break
                size+=len(chunk)
                if size>1048576:return {"reason":"DATA_TOO_LARGE"}
                chunks.append(chunk)
        import csv,io
        text=b"".join(chunks).decode(errors="replace").splitlines()
        if not text or not text[0].startswith("# pxname,"):
            return {"reason":"UNEXPECTED_STATS"}
        for row in csv.DictReader(io.StringIO("\n".join(text[1:])),
                                  fieldnames=text[0].lstrip("# ").split(",")):
            if row.get("pxname")=="dual_egress" and row.get("svname") in ("backhaul","mieru"):
                rows[row["svname"]]={
                    "state":row.get("status"),"active":row.get("scur"),
                    "weight":row.get("weight")
                }
        return rows or {"reason":"MISSING_DUAL_EGRESS"}
    except (OSError,UnicodeError,ValueError):
        return {"reason":"SOCKET_UNAVAILABLE"}

def service_bin():
    unit="dual-ha-v2-health"
    r=call(["systemctl","show",unit,"-p","ExecStart","--value"],5)
    if not r or r.returncode:return "UNKNOWN"
    # Only recognized basename, never reveal environment or CLI secrets.
    data=r.stdout
    if "/opt/dual-ha/controller.py" in data:return "expected:/opt/dual-ha/controller.py"
    return "OTHER_REVIEW_REQUIRED"

def main():
    if os.geteuid()!=0:
        raise RuntimeError("Run as root ON Maya1")
    ip=masked_bundle()
    if ip.get("BH_IRAN_IP") not in (None,IRAN):
        raise RuntimeError("Existing Backhaul identifies a different Iran server!")
    print("MAYA1 DUAL-BACKHAUL MIGRATION READ-ONLY PREFLIGHT")
    print("TARGET IRAN:",IRAN)
    print("TARGET FOREIGN BACKHAUL1:",B1)
    print("TARGET FOREIGN BACKHAUL2:",B2)
    print("NEW TLS/WS DOMAIN:",DOMAIN)
    print("DNS A:",",".join(dns()) or "UNRESOLVED")
    print("DNS matches MAYA1:",dns()==[IRAN])
    print("DOMAIN CERT:",cert_status())
    print("ACTIVE SERVICES:")
    for name in SERVICES:
        print(" ",name,active(name))
    print("PORT LISTENERS (service/process names only):")
    for port,names in port_listeners().items():
        print(" ",str(port)+":",",".join(names))
    print("EXISTING COMPONENTS (PRESENT/MISSING; no secrets printed):")
    for name in SENSITIVE:
        p=Path(name)
        print(" ",name,"PRESENT" if p.exists() else "MISSING")
    print("CURRENT BACKHAUL PUBLIC METADATA:",json.dumps(ip,sort_keys=True))
    print("HEALTH CONTROLLER:",service_bin())
    print("HAPROXY BACKEND STATES:",json.dumps(haproxy_stats(),sort_keys=True))
    print("CPU ARCH:",os.uname().machine)
    print("FOREIGN VPS SSH access: not attempted; passwords/host fingerprints not fetched")
    print("NO files changed. NO network service restarted. NO secrets printed.")
    if dns()!=[IRAN]:
        print("BLOCKER: point DNS-only A record",DOMAIN,"to",IRAN)
    if cert_status()!="VALID_7D":
        print("BLOCKER: issue/renew valid TLS certificate before migration; never replace production :443")
    print("NEXT: use this output to select staging ports and a safe reversible two-lane cutover.")

if __name__=="__main__":
    try:
        main()
    except (RuntimeError,ValueError,OSError) as e:
        print("PREFLIGHT ERROR:",str(e),file=sys.stderr)
        sys.exit(1)
