#!/usr/bin/env python3
"""Maya1 new dual-Backhaul helper; read-only status, health, jitter and logs.

Actual new SOCKS: 21101/21102. Legacy Backhaul/Mieru services preserved.
This helper deliberately never dispatches legacy dual rotate/replace commands,
because those would modify the wrong production ports after this migration.
TTY colors are suppressed for NO_COLOR and restricted SSH automation.
"""
from datetime import datetime,timezone
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time
import socket
import io
import csv

IRAN="94.184.4.38"
ROOT=Path("/etc/dual-ha/maya1-next")
HEALTH=Path("/run/dual-ha-v2/health.json")
SOCK="/run/dual-ha-v2/haproxy.sock"
LANES={"backhaul1":("backhaul",21101,"82.152.132.159","bh1"),
       "backhaul2":("mieru",21102,"152.237.230.77","bh2")}
_COLOR=sys.stdout.isatty() and not os.environ.get("NO_COLOR") and os.environ.get("TERM","")!="dumb"
C={"green":"\033[1;32m","red":"\033[1;31m","amber":"\033[1;33m","cyan":"\033[1;36m"}
def paint(value,color):
    return C[color]+str(value)+"\033[0m" if _COLOR else str(value)

def state(role):
    backend,port,ip,folder=LANES[role]
    data=json.loads((ROOT/folder/"state.json").read_text())
    if data.get("iran_ip")!=IRAN or data.get("foreign_ip")!=ip or data.get("staging_socks")!=port:
        raise RuntimeError("Maya1 staging identity mismatch "+role)
    return backend,port,ip

def api():
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
        s.settimeout(3);s.connect(SOCK);s.sendall(b"show stat\n");s.shutdown(socket.SHUT_WR)
        chunks=[];length=0
        while True:
            v=s.recv(8192)
            if not v:break
            chunks.append(v);length+=len(v)
            if length>1024*1024:raise RuntimeError("HAProxy stats too large")
    lines=b"".join(chunks).decode(errors="replace").splitlines()
    if not lines or not lines[0].startswith("# pxname,"):
        raise RuntimeError("HAProxy stats unavailable")
    found={}
    for row in csv.DictReader(io.StringIO("\n".join(lines[1:])),
                              fieldnames=lines[0].lstrip("# ").split(",")):
        if row.get("pxname")=="dual_egress" and row.get("svname") in ("backhaul","mieru"):
            found[row["svname"]]=row
    return found

def cache():
    try:
        d=json.loads(HEALTH.read_text())
        ts=datetime.fromisoformat(d["updated_utc"])
        age=(datetime.now(timezone.utc)-ts).total_seconds()
        if age<0 or age>30 or d.get("policy")!="two-backhaul-bulk-v1":
            return {},None
        return d.get("paths",{}),int(age)
    except (OSError,ValueError,TypeError,KeyError):
        return {},None

def status_label(row,info,age,ip,port):
    if age is None or not isinstance(info,dict) or not isinstance(row,dict):
        return "UNKNOWN","amber"
    if row.get("addr")!="127.0.0.1:"+str(port) or info.get("expected_foreign_ip")!=ip:
        return "UNKNOWN","amber"
    if row.get("status") not in ("UP",) or info.get("available") is False or (
        type(info.get("passed_probes")) is int and info["passed_probes"]<2):
        return "DOWN","red"
    try:enabled=int(row.get("weight","0"))>0
    except ValueError:enabled=False
    if not enabled:return "DISABLED","amber"
    if (info.get("available") is True and info.get("passed_probes",0)>=2
            and info.get("bulk_pass") is True):
        return "UP","green"
    return "UNKNOWN","amber"

def status():
    rows=api();info,age=cache()
    print("\n  DUAL BACKHAUL | MAYA1 | HAProxy leastconn")
    print("  ---------------------------------------------------------------")
    print("  IRAN: "+IRAN+" | REALITY/x-ui: "+
          ("active" if subprocess.run(["systemctl","is-active","--quiet","x-ui"]).returncode==0 else "not-active"))
    for role in LANES:
        backend,port,ip=state(role)
        row=rows.get(backend,{})
        item=info.get(backend,{})
        result,color=status_label(row,item,age,ip,port)
        print("  %-9s foreign=%s  SOCKS=%s %s" %
              (role.upper(),paint(ip,"cyan"),port,paint(result,color)))
        print("        active=%s total=%s weight=%s | HTTPS=%s/3 | BULK=%s | bytes=%s speed=%s B/s" %
              (row.get("scur","?"),row.get("stot","?"),row.get("weight","?"),
               item.get("passed_probes","?"),item.get("bulk_pass","not measured"),
               item.get("bulk_last",{}).get("bytes","?"),
               item.get("bulk_last",{}).get("speed_bps","?")))
    print("  Controller cache age: "+(str(age) if age is not None else "stale")+"s")
    print("  ---------------------------------------------------------------")
    print("  Historical backend name 'mieru' actually carries BACKHAUL2.")
    print("  Old Backhaul+Mieru retained for emergency rollback; not current routing.")

def probe(port,ip):
    opts=["curl","-q","-4","--noproxy","","--socks5-hostname",
          "127.0.0.1:"+str(port),"--connect-timeout","5","--max-time","25","-fsS"]
    r=subprocess.run([*opts,"https://www.cloudflare.com/cdn-cgi/trace"],
                     capture_output=True,text=True,timeout=28)
    if r.returncode or "ip="+ip not in r.stdout.splitlines():
        return False,"wrong egress or timeout"
    r=subprocess.run([*opts,"-o","/dev/null","-w",
                      "%{http_code} %{size_download} %{time_total}",
                      "https://speed.cloudflare.com/__down?bytes=1048576"],
                     capture_output=True,text=True,timeout=28)
    try:
        code,count,elapsed=r.stdout.strip().split()
        valid=r.returncode==0 and code=="200" and int(float(count))==1048576
        return valid,"bytes="+count+" time="+elapsed+"s"
    except (ValueError,TypeError):
        return False,"download failed"

def health():
    status()
    for role in LANES:
        _,port,ip=state(role)
        ok,detail=probe(port,ip)
        print(role.upper(),paint("PASS" if ok else "FAIL","green" if ok else "red"),detail)

def jitter(samples=12):
    if not 8<=samples<=60:raise ValueError("samples must be 8-60")
    for role in LANES:
        _,port,ip=state(role)
        points=[]
        for i in range(samples):
            opts=["curl","-q","-4","--noproxy","","--socks5-hostname",
                  "127.0.0.1:"+str(port),"--connect-timeout","5","--max-time","10",
                  "-fsS","-o","/dev/null","-w","%{time_total}",
                  "https://www.gstatic.com/generate_204"]
            try:
                r=subprocess.run(opts,capture_output=True,text=True,timeout=12)
                if r.returncode==0:points.append(float(r.stdout)*1000)
            except (OSError,ValueError,subprocess.TimeoutExpired):
                pass
        if points:
            ordered=sorted(points)
            p95=ordered[min(len(ordered)-1,int(.95*(len(ordered)-1)))]
            print(role.upper(),len(points),"/",samples," HTTPS ms",
                  "P50",round(statistics.median(points)),"P95",round(p95),
                  "MAX",round(max(points)))
        else:
            print(role.upper(),"NO SAMPLES")
    print("HTTPS elapsed time is not ICMP ping.")

def logs():
    for unit in ("dual-ha-v2-health","maya1-next-bh1-backhaul","maya1-next-bh2-backhaul",
                 "maya1-next-bh1-tls","maya1-next-bh2-tls"):
        r=subprocess.run(["journalctl","-u",unit,"-n","10","--no-pager","-o","short-iso"],
                         capture_output=True,text=True,timeout=10)
        print("\n== "+unit+" ==")
        for line in r.stdout.splitlines():
            if any(word in line.lower() for word in ("token=","password","secret=",
                                                      "privatekey","/assets/","/socket/")):
                continue
            print(line[:350])

def menu():
    while True:
        status()
        print("\n  [1] Status [2] Live health [3] Jitter [4] Logs [0] Exit")
        x=input("  dual > ").strip()
        if x=="0":return
        if x=="1":status()
        elif x=="2":health()
        elif x=="3":jitter()
        elif x=="4":logs()
        else:print("Choose 0-4")

def main():
    if os.geteuid()!=0:raise RuntimeError("Run sudo dual")
    args=sys.argv[1:]
    if not args:
        if sys.stdin.isatty():menu()
        else:status()
    elif args==["status"]:status()
    elif args==["health"]:health()
    elif args==["logs"]:logs()
    elif args==["jitter"]:jitter()
    elif len(args)==2 and args[0]=="jitter":jitter(int(args[1]))
    else:raise RuntimeError("Usage: sudo dual [status|health|logs|jitter [8..60]]. "
                            "Foreign IP rotation is NOT activated for staged Maya1 lanes; "
                            "legacy dual replace would operate on the WRONG ports.")
if __name__=="__main__":
    try:main()
    except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired) as e:
        print("ERROR",str(e)[:250],file=sys.stderr);sys.exit(1)
