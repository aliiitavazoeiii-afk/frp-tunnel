#!/usr/bin/env python3
"""Maya1 emergency: persist already restored live 21101/21102 routing.

Only edits on-disk HAProxy config after strict live identity and status checks.
NEVER restarts, reloads, kills or mutates a running service or HAProxy socket.
Removing disabled from exactly two staged server entries allows HAProxy native
TCP health checks after a later service restart. Keep old controller disabled.
"""
import csv
import datetime
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

CONFIG=Path("/etc/dual-ha/v2/haproxy.cfg")
SOCKET=Path("/run/dual-ha-v2/haproxy.sock")
MARKER=Path("/etc/dual-ha/maya1-next/cutover-state.json")
ROOT=Path("/etc/dual-ha/maya1-next")
BACKUPS=Path("/root/dual-backhaul-backups")
SERVICE="dual-ha-v2-health.service"
LANES={"backhaul":("bh1",21101,"82.152.132.159"),
       "mieru":("bh2",21102,"152.237.230.77")}

def guard(ok,msg):
    if not ok:raise RuntimeError("STOP: "+msg)

def service_state(*args):
    r=subprocess.run(["systemctl",*args],capture_output=True,text=True,timeout=10)
    return r.returncode,r.stdout.strip()

def runtime_rows():
    guard(SOCKET.is_socket(),"HAProxy socket missing")
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as sk:
        sk.settimeout(4)
        sk.connect(str(SOCKET))
        sk.sendall(b"show stat\n")
        sk.shutdown(socket.SHUT_WR)
        data=b""
        while True:
            x=sk.recv(65536)
            if not x:break
            data+=x
            guard(len(data)<1024*1024,"HAProxy stats too large")
    lines=data.decode(errors="replace").splitlines()
    guard(lines and lines[0].startswith("# pxname,"),"HAProxy stats format unexpected")
    fields=lines[0][2:].split(",")
    results={}
    for row in csv.DictReader(io.StringIO("\n".join(lines[1:])),fieldnames=fields):
        if row.get("pxname")=="dual_egress" and row.get("svname") in LANES:
            results[row["svname"]]=row
    return results

def offline_preview(original):
    guard("balance leastconn" in original and "bind 127.0.0.1:18080" in original,
          "HAProxy listener or policy unexpected")
    out=original
    for backend,(_,port,_) in LANES.items():
        old=f"server {backend} 127.0.0.1:{port} check disabled"
        new=f"server {backend} 127.0.0.1:{port} check"
        guard(out.count(old)==1,"live config backend line mismatch "+backend)
        out=out.replace(old,new,1)
    guard(out!=original,"no changes")
    return out

def preflight():
    guard(os.geteuid()==0,"root required")
    guard(CONFIG.is_file() and not CONFIG.is_symlink(),"HAProxy config missing/symlink")
    guard(MARKER.is_file() and not MARKER.is_symlink(),"Maya1 cutover journal missing")
    marker=json.loads(MARKER.read_text())
    guard(marker.get("format")=="MAYA1_NEXT_V1" and
          marker.get("phase")=="completed" and marker.get("iran")=="94.184.4.38",
          "Maya1 cutover not committed")
    guard(service_state("is-active","--quiet","dual-ha-v2-gateway.service")[0]==0,
          "HAProxy not active")
    guard(service_state("is-active","--quiet",SERVICE)[0]!=0,
          "old speed-based health controller STILL ACTIVE; stop/disable it first")
    guard(service_state("is-enabled",SERVICE)[0]!=0,
          "old health controller still enabled on boot; disable it first")
    for backend,(role,port,ip) in LANES.items():
        meta=json.loads((ROOT/role/"state.json").read_text())
        guard(meta.get("iran_ip")=="94.184.4.38" and
              meta.get("foreign_ip")==ip and meta.get("staging_socks")==port,
              "staging metadata mismatch "+backend)
        for suffix in ("backhaul","router","tls"):
            guard(service_state("is-active","--quiet",
                  "maya1-next-"+role+"-"+suffix+".service")[0]==0,
                  "new staged tunnel service inactive "+role+"/"+suffix)
    live=runtime_rows()
    guard(set(live)==set(LANES),"both HAProxy backends missing")
    for backend,(_,port,ip) in LANES.items():
        row=live[backend]
        guard(row.get("addr")=="127.0.0.1:"+str(port),
              "HAProxy backend points to wrong target "+backend)
        guard(row.get("status")=="UP",
              "HAProxy backend is not UP "+backend+" "+str(row.get("status")))
        print("LIVE",backend,"UP","127.0.0.1:"+str(port),"ACTIVE",row.get("scur"),flush=True)
    original=CONFIG.read_text()
    candidate=offline_preview(original)
    with tempfile.TemporaryDirectory(prefix="maya1-haproxy-check-",dir="/root") as td:
        path=Path(td)/"haproxy.cfg"
        path.write_text(candidate)
        result=subprocess.run(["/usr/sbin/haproxy","-c","-f",str(path)],
                              capture_output=True,text=True,timeout=20)
        guard(result.returncode==0,
              "candidate HAProxy -c rejected: "+result.stderr[-180:])
    return candidate

def apply():
    candidate=preflight()
    BACKUPS.mkdir(parents=True,exist_ok=True,mode=0o700)
    folder=BACKUPS/("maya1-live-persistence-"+
                    datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")+
                    "-"+str(os.getpid()))
    folder.mkdir(mode=0o700)
    shutil.copy2(CONFIG,folder/"haproxy.cfg.before")
    fd,tmp=tempfile.mkstemp(prefix=".haproxy-maya1.",dir=str(CONFIG.parent))
    try:
        st=CONFIG.stat()
        os.fchmod(fd,st.st_mode & 0o777)
        os.fchown(fd,st.st_uid,st.st_gid)
        with os.fdopen(fd,"w") as out:
            out.write(candidate)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp,CONFIG)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
    # Zero socket writes. Confirm runtime unchanged and config exact.
    live=runtime_rows()
    guard(all(live[b].get("status")=="UP" and
              live[b].get("addr")=="127.0.0.1:"+str(LANES[b][1])
              for b in LANES),"live HAProxy changed unexpectedly; inspect immediately")
    guard(CONFIG.read_text()==candidate,"config write mismatch")
    print("MAYA1_HAPROXY_PERSISTENCE_SAVED")
    print("CURRENT_LIVE_HAPROXY_UNCHANGED=TRUE")
    print("HAProxy will use native TCP health checks on next start.")
    print("CONTROLLER_OLD_SPEED_POLICY_REMAINS_OFF=TRUE")
    print("BACKUP="+str(folder/"haproxy.cfg.before"))

def main():
    if len(sys.argv)!=2 or sys.argv[1] not in ("preflight","apply"):
        raise RuntimeError("Usage: maya1-emergency-persist-gateway.py preflight|apply")
    if sys.argv[1]=="preflight":
        preflight()
        print("MAYA1_GATEWAY_PERSISTENCE_PREFLIGHT_PASS")
        print("Live traffic and config unchanged.")
    else:
        apply()

if __name__=="__main__":
    try:main()
    except (OSError,RuntimeError,ValueError,KeyError,
            subprocess.TimeoutExpired) as e:
        print("MAYA1_PERSISTENCE_ERROR:",str(e)[:380],file=sys.stderr)
        sys.exit(1)
