#!/usr/bin/env python3
"""Maya1: stage TWO INDEPENDENT Custom WSSMux Backhauls parallel to production.

Never touches: Xray :443, existing Backhaul1 :21001 / :18443,
Mieru :21002, HAProxy :18080, current credentials, or any foreign VPS.
Stages new SOCKS endpoints 21101/21102 and public TLS 18447/18448.
A later separate, explicitly approved command is required for cutover.
"""
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import time

IRAN="94.184.4.38"
DOMAIN="bh-new.biya2film.top"
TARGETS={"bh1":("82.152.132.159",18447,19090,19091,21101),
         "bh2":("152.237.230.77",18448,19092,19093,21102)}
BASE=Path("/etc/dual-ha/maya1-next")
BIN=Path("/opt/dual-ha/bin/backhaul")
MARK=Path("/root/dual-backhaul-backups")
def cmd(*parts,check=True,timeout=15):
    r=subprocess.run(parts,capture_output=True,text=True,timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(parts[0]+" failed: "+r.stderr[-300:])
    return r

def must(condition,message):
    if not condition:raise RuntimeError("STOP: "+message)

def is_active(name):
    return cmd("systemctl","is-active","--quiet",name,check=False).returncode==0

def listening(port):
    s=socket.socket();s.settimeout(.4)
    try:return s.connect_ex(("127.0.0.1",port))==0
    finally:s.close()

def netstat_ports():
    r=cmd("ss","-Htan",check=True)
    used=set()
    for line in r.stdout.splitlines():
        cols=line.split()
        if len(cols)<4:continue
        m=re.search(r":(\d+)$",cols[3])
        if m:used.add(int(m.group(1)))
    return used

def ensure_identity():
    must(os.geteuid()==0,"root required")
    must(os.uname().machine=="x86_64","Maya1 amd64 only")
    must(BIN.is_file(),"Existing Maya1 custom Backhaul binary missing")
    must(not BASE.exists(),"staging directory already exists, do not overwrite")
    b=Path("/etc/dual-ha/backhaul-bundle.env")
    must(b.is_file(),"existing Backhaul bundle missing")
    txt=b.read_text()
    must("BH_IRAN_IP='"+IRAN+"'" in txt,"not Maya1")
    must("BH_FOREIGN_IP='152.237.230.159'" in txt,"original Backhaul foreign has changed")
    must(is_active("x-ui"),"x-ui inactive")
    must(all(is_active(n) for n in (
        "dual-ha-backhaul","dual-ha-backhaul-router",
        "dual-ha-backhaul-tls","dual-ha-mieru",
        "dual-ha-v2-gateway","dual-ha-v2-health")),"existing production tunnel not fully healthy")
    for port in (443,18443,21001,21002,18080):
        must(listening(port),"current production port offline: "+str(port))
    # Fail closed if DNS has extra A records.
    ips=sorted({r[4][0] for r in socket.getaddrinfo(DOMAIN,None,socket.AF_INET,socket.SOCK_STREAM)})
    must(ips==[IRAN],"DNS-only A for "+DOMAIN+" must equal Maya1 "+IRAN)
    cert=Path("/etc/letsencrypt/live")/DOMAIN/"fullchain.pem"
    key=Path("/etc/letsencrypt/live")/DOMAIN/"privkey.pem"
    must(cert.is_file() and key.is_file(),"domain SSL certificate/key missing on MAYA1")
    cmd("openssl","x509","-in",str(cert),"-noout","-checkhost",DOMAIN)
    cmd("openssl","x509","-in",str(cert),"-noout","-checkend","604800")
    for x in ("/usr/sbin/haproxy","/usr/bin/stunnel"):
        must(Path(x).is_file(),x+" missing")
    required={v for row in TARGETS.values() for v in row[1:]}
    busy=netstat_ports()
    must(not (required&busy),"new staging ports already occupied: "+str(required&busy))
    for role in TARGETS:
        for service in services(role):
            must(not Path("/etc/systemd/system/"+service+".service").exists(),
                 "systemd service name already present: "+service)
    return cert,key

def atomic(path,body,mode=0o600):
    f=path.with_suffix(path.suffix+".new")
    fd=os.open(f,os.O_CREAT|os.O_EXCL|os.O_WRONLY,mode)
    try:
        with os.fdopen(fd,"w") as out:
            out.write(body);out.flush();os.fsync(out.fileno())
        os.replace(f,path);os.chmod(path,mode)
    finally:
        if f.exists():f.unlink()

def services(role):
    return [f"maya1-next-{role}-backhaul",f"maya1-next-{role}-router",
            f"maya1-next-{role}-tls"]

def make_configs(role, cert, key):
    foreign,tls,router,backhaul,socks=TARGETS[role]
    location=BASE/role
    location.mkdir(mode=0o700)
    token=secrets.token_hex(32)
    ctrl="/assets/"+secrets.token_hex(16)
    ws="/socket/"+secrets.token_hex(16)
    bundle=(f"BH_DOMAIN='{DOMAIN}'\nBH_IRAN_IP='{IRAN}'\n"
            f"BH_FOREIGN_IP='{foreign}'\nBH_TOKEN='{token}'\n"
            f"BH_CONTROL_PATH='{ctrl}'\nBH_TUNNEL_PATH='{ws}'\n"
            f"BH_TLS_PORT='{tls}'\n")
    atomic(location/"foreign-bundle.env",bundle)
    config=(f'[server]\nbind_addr = "127.0.0.1:{backhaul}"\n'
            f'transport = "wsmux"\ntoken = "{token}"\n'
            f'ws_control_path = "{ctrl}"\nws_tunnel_path = "{ws}"\n'
            "keepalive_period = 75\nheartbeat = 40\nnodelay = true\n"
            "channel_size = 4096\nmux_con = 16\nmux_version = 1\n"
            "mux_framesize = 32768\nmux_recievebuffer = 4194304\n"
            "mux_streambuffer = 65536\nsniffer = false\nweb_port = 0\n"
            f'log_level = "info"\nports = ["127.0.0.1:{socks}=127.0.0.1:11080"]\n')
    atomic(location/"iran.toml",config)
    route=(f"global\n  maxconn 20000\ndefaults\n  mode http\n"
           f"  timeout connect 5s\n  timeout client 1h\n"
           f"  timeout server 1h\n  timeout tunnel 12h\n"
           f"  timeout http-request 10s\nfrontend ingress\n"
           f"  bind 127.0.0.1:{router}\n"
           f"  acl control_path path -i {ctrl}\n"
           f"  acl tunnel_path path_beg {ws}/\n"
           '  http-request return status 200 content-type text/plain string OK if { path / }\n'
           '  http-request return status 404 content-type text/plain string NotFound unless control_path or tunnel_path\n'
           f"  use_backend wsmux if control_path or tunnel_path\n"
           f"backend wsmux\n  server backhaul 127.0.0.1:{backhaul}\n")
    atomic(location/"router.cfg",route,0o640)
    tlsconf=("foreground = yes\nsyslog = no\ndebug = notice\n"
             "socket = l:TCP_NODELAY=1\nsocket = r:TCP_NODELAY=1\n"
             f"[maya1-independent-{role}]\n"
             f"accept = 0.0.0.0:{tls}\nconnect = 127.0.0.1:{router}\n"
             f"cert = {cert}\nkey = {key}\n"
             "sslVersionMin = TLSv1.2\n"
             "TIMEOUTconnect = 10\nTIMEOUTidle = 43200\n")
    atomic(location/"tls.conf",tlsconf)
    meta={"mode":"staged","iran_ip":IRAN,"foreign_ip":foreign,
          "domain":DOMAIN,"tls_port":tls,"staging_socks":socks,
          "role":role}
    atomic(location/"state.json",json.dumps(meta,indent=2)+"\n")
    cmd("haproxy","-c","-f",str(location/"router.cfg"))
    for service,exe in zip(services(role),[
        f"/opt/dual-ha/bin/backhaul -c {location}/iran.toml",
        f"/usr/sbin/haproxy -W -db -f {location}/router.cfg",
        f"/usr/bin/stunnel {location}/tls.conf",
    ]):
        unit=("[Unit]\nDescription=Maya1 candidate independent "+role+" WSSMux\n"
              "Wants=network-online.target\nAfter=network-online.target\n"
              "[Service]\nType=simple\nExecStart="+exe+"\n"
              "Restart=on-failure\nRestartSec=3\nLimitNOFILE=65536\n"
              "[Install]\nWantedBy=multi-user.target\n")
        atomic(Path("/etc/systemd/system")/(service+".service"),unit,0o644)

def main():
    cert,key=ensure_identity()
    BASE.mkdir(mode=0o700,parents=False)
    try:
        for role in TARGETS:
            make_configs(role,cert,key)
        cmd("systemctl","daemon-reload")
        for role in TARGETS:
            for service in services(role):
                cmd("systemctl","enable","--now",service,timeout=18)
        for role,(_,tls,router,backhaul,socks) in TARGETS.items():
            must(all(is_active(s) for s in services(role)),
                 role+" staging services not active")
            must(listening(tls) and listening(router) and listening(backhaul),
                 role+" staging ports not accepting")
        print("MAYA1_TWO_BACKHAUL_STAGING_READY")
        print("Production Backhaul, Mieru, Xray and HAProxy are unchanged.")
        for role,(ip,tls,router,bh,socks) in TARGETS.items():
            print(f"{role}: foreign={ip} TLS_PORT={tls} STAGE_SOCKS={socks}")
            print(f"  PRIVATE BUNDLE: {BASE/role/'foreign-bundle.env'}")
        print("NEXT: copy separate bundle to the matching fresh foreign VPS.")
        print("Open firewall/provider ingress: only foreign1 ->18447, foreign2 ->18448.")
        print("Keep current production :21001/:21002 until staged egress is verified.")
    except BaseException:
        print("STAGING_ERROR: production services unchanged.",file=sys.stderr)
        print("Review staging units and directory; do not rerun blindly.",file=sys.stderr)
        raise

if __name__=="__main__":
    try:main()
    except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired,socket.gaierror) as e:
        print("STOP:",str(e)[:400],file=sys.stderr)
        sys.exit(1)
