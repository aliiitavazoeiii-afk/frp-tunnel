#!/usr/bin/env python3
"""Maya3: drain Backhaul2 (HAProxy legacy name mieru) from HAProxy, keep Backhaul only.

Use dry-run (default) or --apply. No Xray, HAProxy, or tunnel daemon reload.
No Backhaul2 process shutdown while existing connections are present.
Safely persist startup policy and pause the old auto-REENABLE health controller.
"""
import csv
import datetime as dt
import io
import ipaddress
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile

IP="185.215.230.221"
SOCK=Path("/run/dual-ha-v2/haproxy.sock")
CFG=Path("/etc/dual-ha/v2/haproxy.cfg")
BUNDLE=Path("/etc/dual-ha/backhaul-bundle.env")
CONTROLLER="dual-ha-v2-health.service"
BACKUP_ROOT=Path("/root/dual-ha-maya3-backhaul-only")
PORT_BH=21001
PORT_MIERU=21002
BH1_IP="152.237.230.140"
BH2_IP="82.152.132.112"
BH2_STATE=Path("/etc/dual-ha/bh2-experiment/state.json")

def guard(condition,message):
    if not condition:
        raise RuntimeError("STOP: "+message)

def command(argv,timeout=20):
    return subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                          text=True,timeout=timeout)

def system(*args):
    return command(["systemctl",*args],timeout=12)

def haproxy(payload):
    guard(SOCK.is_socket(),"HAProxy stats socket absent: "+str(SOCK))
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(SOCK))
        connection.sendall((payload+"\n").encode())
        connection.shutdown(socket.SHUT_WR)
        chunks=[]
        n=0
        while True:
            part=connection.recv(65536)
            if not part:break
            chunks.append(part)
            n+=len(part)
            guard(n<1024*1024,"HAProxy response exceeded safe bound")
    msg=b"".join(chunks).decode(errors="replace")
    if payload=="show stat":
        guard(msg.startswith("# pxname,"),"HAProxy CSV unexpected")
    else:
        guard(not re.search(r"error|unknown command|no such|not found",msg,re.I),
              "HAProxy rejected the operation "+msg[:140])
    return msg

def states():
    lines=haproxy("show stat").splitlines()
    fields=lines[0][2:].split(",")
    out={}
    for row in csv.DictReader(io.StringIO("\n".join(lines[1:])),fieldnames=fields):
        if row.get("pxname")=="dual_egress" and row.get("svname") in ("backhaul","mieru"):
            out[row["svname"]]=row
    guard(set(out)=={"backhaul","mieru"},"unexpected HAProxy backend IDs")
    guard(out["backhaul"]["addr"]=="127.0.0.1:"+str(PORT_BH),
          "Backhaul HAProxy target is not :21001")
    guard(out["mieru"]["addr"]=="127.0.0.1:"+str(PORT_MIERU),
          "Backhaul2 HAProxy target is not :21002")
    return out

def new_config(src):
    # Fail closed on unknown HAProxy config; never alter x-ui/reality or any other backend.
    guard(src.count("bind 127.0.0.1:18080")==1,"unexpected gateway listener")
    guard(src.count("balance leastconn")==1,"unexpected balance algorithm")
    lines=src.splitlines(keepends=True)
    results=[]
    found={"backhaul":0,"mieru":0}
    for line in lines:
        for name,port in (("backhaul",PORT_BH),("mieru",PORT_MIERU)):
            if re.search(r"^\s*server\s+"+name+r"\s+",line):
                guard(found[name]==0,"duplicate backend definition "+name)
                guard(re.fullmatch(r"\s*server\s+"+name+
                     r"\s+127\.0\.0\.1:"+str(port)+r"\s+check(?:\s+disabled)?\s*\n?",line),
                     "unexpected HAProxy backend options "+name)
                found[name]+=1
                line=("  server "+name+" 127.0.0.1:"+str(port)+
                      (" check\n" if name=="backhaul" else " check disabled\n"))
        results.append(line)
    guard(found=={"backhaul":1,"mieru":1},"missing expected HAProxy backend definitions")
    return "".join(results)

def verify_backhaul(port=PORT_BH):
    r=command(["curl","-q","-4","--noproxy","","--socks5-hostname",
        "127.0.0.1:"+str(port),"--connect-timeout","5","--max-time","18",
        "--fail","--silent","--show-error",
        "https://www.cloudflare.com/cdn-cgi/trace"],timeout=21)
    guard(r.returncode==0,"Backhaul HTTPS Cloudflare canary failed (no routing changed)")
    m=re.search(r"(?m)^ip=(\d{1,3}(?:\.\d{1,3}){3})\s*$",r.stdout)
    guard(m is not None and ipaddress.IPv4Address(m.group(1)).is_global,
          "Backhaul external IPv4 could not be verified")
    print("BACKHAUL_EGRESS_IP=",m.group(1),flush=True)
    return m.group(1)

def verify_identity():
    guard(os.geteuid()==0,"must run as root")
    guard(BUNDLE.is_file() and not BUNDLE.is_symlink(),"Backhaul bundle missing")
    src=BUNDLE.read_text()
    guard(re.search(r"(?m)^BH_IRAN_IP='185\.215\.230\.221'$",src),
          "THIS IS NOT MAYA3 (expected 185.215.230.221)")
    guard(re.search(r"(?m)^BH_FOREIGN_IP='152\.237\.230\.140'$",src),
          "Maya3 Backhaul1 configured foreign IP mismatch")
    guard(BH2_STATE.is_file() and not BH2_STATE.is_symlink(),
          "Maya3 Backhaul2 identity file missing")
    import json
    state=json.loads(BH2_STATE.read_text())
    guard(state.get("mode")=="active" and
          state.get("foreign_ip")==BH2_IP and state.get("primary_ip")==BH1_IP,
          "Maya3 Backhaul2 assignment unexpected")
    for svc in ("dual-ha-backhaul.service","dual-ha-bh2-server.service",
                "dual-ha-bh2-router.service","dual-ha-bh2-tls.service",
                "dual-ha-v2-gateway.service","x-ui.service"):
        guard(system("is-active","--quiet",svc).returncode==0,
              "required service not active "+svc)
    # The V3 controller would automatically re-enable Backhaul2 if left running.
    # Require known-good V3 policy before making an intentional single-lane change.
    import json
    from datetime import datetime, timezone
    health_file=Path("/run/dual-ha-v2/health.json")
    guard(health_file.is_file() and not health_file.is_symlink(),
          "V3 health cache not found")
    health=json.loads(health_file.read_text())
    guard(health.get("policy")=="two-backhaul-3site-10m-v3" and
          health.get("check_interval_s")==600,
          "unexpected health controller policy; refusing to disable")
    guard(system("is-active","--quiet",CONTROLLER).returncode==0,
          "V3 controller is not active")
    measured=datetime.fromisoformat(health["updated_utc"])
    age=(datetime.now(timezone.utc)-measured).total_seconds()
    guard(0<=age<780,"V3 health cache stale or future-dated")
    guard(health["paths"]["backhaul"].get("passed_probes",0)>=2,
          "Backhaul1 V3 HTTPS health not confirmed")
    print("V3_BACKHAUL1_HEALTH_CONFIRMED","age_seconds="+str(int(age)),
          "https="+str(health["paths"]["backhaul"].get("passed_probes"))+"/3")
    guard(CFG.is_file() and not CFG.is_symlink(),"HAProxy config missing")
    rows=states()
    bh=rows["backhaul"]
    guard(bh["status"].startswith("UP") and int(bh.get("weight","0"))>0,
          "Backhaul must be UP with positive weight")
    print("LIVE_BACKHAUL",bh["status"],"active="+bh.get("scur","?"),flush=True)
    print("LIVE_BACKHAUL2",rows["mieru"].get("status"),
          "active="+rows["mieru"].get("scur","?"),flush=True)
    expected_egress=verify_backhaul()
    guard(expected_egress==BH1_IP,
          "Backhaul1 SOCKS egress IP unexpected; refuse changes")
    orig=CFG.read_text()
    target=new_config(orig)
    with tempfile.TemporaryDirectory(prefix="maya3-haproxy-validate-",dir="/root") as td:
        candidate=Path(td)/"haproxy.cfg"
        candidate.write_text(target)
        r=command(["/usr/sbin/haproxy","-c","-f",str(candidate)],timeout=20)
        guard(r.returncode==0,"HAProxy config validation failed: "+r.stderr[-200:])
    print("PERSISTENT_BACKHAUL_ONLY_CONFIG_VALID",flush=True)
    return orig,target,rows,expected_egress

def save_config(src):
    st=CFG.stat()
    fd,path=tempfile.mkstemp(dir=str(CFG.parent),prefix=".maya3-haproxy-")
    try:
        os.fchmod(fd,st.st_mode & 0o777)
        os.fchown(fd,st.st_uid,st.st_gid)
        with os.fdopen(fd,"w") as file:
            file.write(src)
            file.flush()
            os.fsync(file.fileno())
        os.replace(path,CFG)
    finally:
        if os.path.exists(path):os.unlink(path)

def apply(orig,target,before,expected_egress):
    was_running=system("is-active","--quiet",CONTROLLER).returncode==0
    enabled=system("is-enabled",CONTROLLER).stdout.strip()
    print("CONTROLLER_BEFORE", "active" if was_running else "inactive",
          "enabled="+enabled,flush=True)
    BACKUP_ROOT.mkdir(mode=0o700,parents=True,exist_ok=True)
    folder=BACKUP_ROOT/(dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")+
                        "-"+str(os.getpid()))
    folder.mkdir(mode=0o700)
    shutil.copy2(CFG,folder/"haproxy.cfg.before")
    (folder/"controller-before.txt").write_text(
        "active="+str(was_running)+"\nenabled="+enabled+"\n")
    print("BACKUP",folder,flush=True)
    changes=False
    try:
        # Do this before draining, otherwise the old health service might reenable.
        changes=True
        r=system("disable","--now",CONTROLLER)
        guard(r.returncode==0,"unable to disable old controller "+r.stderr[-140:])
        # Persist prior to live switch, without reload or restart.
        if target!=orig:save_config(target)
        haproxy("set server dual_egress/mieru state drain")
        after=states()
        guard(after["backhaul"]["status"].startswith("UP") and
              int(after["backhaul"].get("weight","0"))>0,
              "Backhaul unexpectedly unavailable after draining Mieru")
        guard(after["mieru"]["status"].startswith(("DRAIN","NOLB")),
              "Backhaul2 drain state was not confirmed: "+after["mieru"]["status"])
        gateway_egress=verify_backhaul(18080)
        guard(gateway_egress==expected_egress,
              "Gateway egress does not match verified Backhaul-only path")
        guard(system("is-active","--quiet",CONTROLLER).returncode!=0,
              "health controller reactivated")
        print("MAYA3_BACKHAUL_ONLY_LIVE",flush=True)
        print("BACKHAUL",after["backhaul"]["status"],
              "active="+after["backhaul"].get("scur","?"),flush=True)
        print("BACKHAUL2",after["mieru"]["status"],
              "active="+after["mieru"].get("scur","?"),flush=True)
        print("NEW_CONNECTIONS_VIA_BACKHAUL_ONLY=TRUE")
        print("BACKHAUL2_PROCESS_LEFT_RUNNING_FOR_EXISTING_SESSIONS=TRUE")
        print("HAProxy_XRAY_BACKHAUL_RESTARTED=NO")
        print("CONTROLLER_V3_AUTOREENABLE=OFF")
        print("REBOOT_POLICY_BACKHAUL_ONLY=TRUE")
        print("BACKUP="+str(folder/"haproxy.cfg.before"))
    except Exception:
        if changes:
            try:
                if CFG.read_text()!=orig:save_config(orig)
                haproxy("set server dual_egress/mieru state ready")
                if was_running:
                    system("start",CONTROLLER)
                if enabled=="enabled":
                    system("enable",CONTROLLER)
                print("ROLLBACK_ATTEMPTED_AFTER_ERROR; inspect live status",
                      file=sys.stderr)
            except Exception as error:
                print("ROLLBACK_ERROR: "+str(error)[:160],file=sys.stderr)
        raise

def main():
    guard(len(sys.argv)==2 and sys.argv[1] in ("--check","--apply"),
          "Usage: sudo python3 maya3-backhaul-only-safe.py --check|--apply")
    orig,target,rows,expected_egress=verify_identity()
    if sys.argv[1]=="--check":
        print("MAYA3_BACKHAUL_ONLY_PREFLIGHT_PASS")
        print("NO_CHANGES_MADE=TRUE")
        return
    apply(orig,target,rows,expected_egress)

if __name__=="__main__":
    try:main()
    except (RuntimeError,ValueError,KeyError,OSError,subprocess.TimeoutExpired) as e:
        print("MAYA3_BACKHAUL_ONLY_ERROR:",str(e)[:380],file=sys.stderr)
        sys.exit(1)
