#!/usr/bin/env python3
"""Maya1 read-only preflight, reversible two-Backhaul HAProxy live cutover.

NEVER touches Xray/:443, original Backhaul/Mieru services/ports, remote VPSs,
TLS/WSS files or anti-DPI settings. Backend names and leastconn preserved.
Modes: preflight STAGED_CONTROLLER, switch STAGED_CONTROLLER, rollback.
Cutover changes HAProxy two runtime targets, its persisted config, and ONLY the
dual-ha-v2-health controller service. Existing streams are not migrated.
"""
import csv
from datetime import datetime,timezone
import fcntl
import io
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time

IRAN="94.184.4.38"
ROOT=Path("/etc/dual-ha/maya1-next")
BKP=Path("/root/dual-backhaul-backups")
MARK=ROOT/"cutover-state.json"
LOCK=Path("/run/maya1-dual-cutover.lock")
CFG=Path("/etc/dual-ha/v2/haproxy.cfg")
CTR=Path("/opt/dual-ha/controller.py")
STAT=Path("/run/dual-ha-v2/health.json")
SOCK=Path("/run/dual-ha-v2/haproxy.sock")
NEW={"backhaul":(21101,"82.152.132.159","bh1"),
     "mieru":(21102,"152.237.230.77","bh2")}
OLD={"backhaul":21001,"mieru":21002}
EXPECTED={"backhaul":"server backhaul 127.0.0.1:21001 check disabled",
          "mieru":"server mieru 127.0.0.1:21002 check disabled"}
SERVICE="dual-ha-v2-health"

def must(condition,why):
    if not condition:raise RuntimeError("STOP: "+why)

def call(argv,timeout=30,check=True):
    r=subprocess.run(argv,capture_output=True,text=True,timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(argv[0]+" returned "+str(r.returncode)+": "+r.stderr[-180:])
    return r

def active(unit):
    return call(["systemctl","is-active","--quiet",unit],6,False).returncode==0

def api(command):
    must(SOCK.is_socket(),"HAProxy admin socket not found")
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
        s.settimeout(4)
        s.connect(str(SOCK))
        s.sendall((command+"\n").encode())
        s.shutdown(socket.SHUT_WR)
        chunks=[];length=0
        while True:
            data=s.recv(32768)
            if not data:break
            chunks.append(data);length+=len(data)
            must(length<=1024*1024,"HAProxy API response too large")
    output=b"".join(chunks).decode(errors="replace")
    if command=="show stat":
        must(output.lstrip().startswith("# pxname,"),"unexpected HAProxy stats format")
    else:
        must(not re.search(r"(?im)^(?:unknown|error|no such|permission|cannot|failed|invalid)",output.strip()),
             "HAProxy rejected runtime command: "+output[:100])
    return output

def live_rows():
    rows=api("show stat").splitlines()
    cols=rows[0].lstrip("# ").split(",")
    found={}
    for r in csv.DictReader(io.StringIO("\n".join(rows[1:])),fieldnames=cols):
        if r.get("pxname")=="dual_egress" and r.get("svname") in NEW:
            found[r["svname"]]=r
    must(set(found)==set(NEW),"expected two HAProxy backends not found")
    return found

def match_addr(row,port):
    # Require source-of-truth live stats; avoid silently switching an unknown configuration.
    return row.get("addr")=="127.0.0.1:"+str(port)

def ensure_core():
    must(os.geteuid()==0,"root required")
    must(ROOT.is_dir() and not ROOT.is_symlink(),"Maya1 staging tree missing")
    original=Path("/etc/dual-ha/backhaul-bundle.env")
    must(original.is_file() and
         "BH_IRAN_IP='"+IRAN+"'" in original.read_text(),"not Maya1")
    for name in ("x-ui","dual-ha-backhaul","dual-ha-backhaul-router",
                 "dual-ha-backhaul-tls","dual-ha-mieru","dual-ha-v2-gateway",SERVICE):
        must(active(name),"required current service unavailable: "+name)
    for role,(_,ip,directory) in NEW.items():
        meta=json.loads((ROOT/directory/"state.json").read_text())
        must(meta.get("role")==directory and meta.get("foreign_ip")==ip
             and meta.get("iran_ip")==IRAN,"staging state mismatch "+directory)
        for type_name in ("backhaul","router","tls"):
            must(active("maya1-next-"+directory+"-"+type_name),
                 "staged Backhaul service unavailable "+directory+"/"+type_name)
    must(CFG.is_file() and CTR.is_file(),"HAProxy/health controller files absent")
    unit=call(["systemctl","show",SERVICE,"-p","ExecStart","--value"],8).stdout
    must(str(CTR) in unit,"unexpected health controller unit ExecStart")

def preflight_controller(file):
    must(file.is_file() and file.resolve()!=CTR.resolve(),"staged controller file missing or is live controller")
    text=file.read_text()
    must('PATHS = {"backhaul": 21101, "mieru": 21102}' in text and
         '"82.152.132.159"' in text and '"152.237.230.77"' in text and
         "runtime_targets_match(" in text and
         "BULK_BYTES = 1048576" in text and
         "BULK_REQUIRED_PASSES = 2" in text and
         "BULK_MAX_SECONDS = 12" in text and
         "BULK_MAX_TTFB = 8" in text,
         "staged controller source identity/policy invalid")
    call(["python3","-m","py_compile",str(file)],8)
    # A probe failure is expected to exit nonzero. Preserve its JSON stdout:
    # previous check=True discarded the useful per-path diagnostics.
    status=call(["python3",str(file),"--diagnose"],timeout=70,check=False)
    start=status.stdout.find("{")
    if start<0:
        print("CONTROLLER_DIAGNOSTIC_STDERR:",status.stderr.strip()[-500:],flush=True)
        raise RuntimeError("staged controller did not provide JSON diagnostics")
    try:
        d=json.loads(status.stdout[start:])
    except (ValueError,TypeError) as e:
        raise RuntimeError("staged controller JSON malformed") from e
    failed=[]
    for role,(_,ip,_) in NEW.items():
        result=d.get(role)
        if not isinstance(result,dict):
            failed.append(role+": missing diagnostic")
            continue
        print("CANARY",role,ip,
              "HTTPS",result.get("http_probes"),"/3",
              "SHORT_OK",result.get("https_healthy"),
              "BULK_OK",result.get("bulk_ok"),
              "BULK",result.get("bulk",{}),
              flush=True)
        if not (result.get("foreign_ip")==ip and
                result.get("http_probes",0)>=2 and
                result.get("https_healthy") is True and
                result.get("bulk_ok") is True and
                result.get("bulk",{}).get("bytes")==1048576 and
                result.get("bulk",{}).get("sample_pass",0)>=2):
            failed.append(role)
    # Runtime should still point to old production endpoints BEFORE the cutover.
    if d.get("runtime_targets_match") is not False:
        raise RuntimeError("HAProxy state changed unexpectedly during preflight")
    if status.returncode!=0 or failed:
        print("STAGED_CONTROLLER_DIAGNOSTIC_EXIT=",status.returncode,flush=True)
        if status.stderr.strip():
            print("STAGED_CONTROLLER_DIAGNOSTIC_NOTE:",status.stderr.strip()[-350:],flush=True)
        raise RuntimeError("staged health probes failed: "+", ".join(failed or ["controller"]))

def persistent_text(existing,from_ports,to_ports):
    out=existing
    for role in NEW:
        before=f"server {role} 127.0.0.1:{from_ports[role]} check disabled"
        after=f"server {role} 127.0.0.1:{to_ports[role]} check disabled"
        must(out.count(before)==1,"unexpected HAProxy config line for "+role)
        out=out.replace(before,after,1)
    must("balance leastconn" in out and "bind 127.0.0.1:18080" in out,
         "original HAProxy gateway policy/port mismatch")
    return out

def validate_cfg(contents):
    with tempfile.TemporaryDirectory(prefix=".maya1-haproxy-check-",dir="/root") as td:
        file=Path(td)/"haproxy.cfg"
        file.write_text(contents)
        call(["/usr/sbin/haproxy","-c","-f",str(file)],timeout=12)

def strict_preflight(controller):
    ensure_core()
    rows=live_rows()
    must(all(match_addr(rows[r],OLD[r]) for r in OLD),"HAProxy no longer uses both old ports")
    must(all(rows[r].get("status")=="UP" and
             int(rows[r].get("weight","0"))>0 for r in OLD),
         "existing HAProxy backend not healthy or not in load balancing")
    existing=CFG.read_text()
    for line in EXPECTED.values():
        must(existing.count(line)==1,"live HAProxy config differs from expected")
    candidate=persistent_text(existing,OLD,{r:NEW[r][0] for r in NEW})
    validate_cfg(candidate)
    preflight_controller(controller)
    for r in OLD:
        print("CURRENT",r,"->",rows[r]["addr"],"status",rows[r]["status"],
              "connections",rows[r].get("scur","?"))
    print("PREFLIGHT_PASS: two tested stage paths and reversible HAProxy configs")

def atomic_bytes(path,data):
    fd,temp=tempfile.mkstemp(prefix=".maya1-next-",dir=str(path.parent))
    try:
        os.fchmod(fd,path.stat().st_mode & 0o777)
        with os.fdopen(fd,"wb") as f:
            f.write(data);f.flush();os.fsync(f.fileno())
        os.replace(temp,path)
    finally:
        if os.path.exists(temp):os.unlink(temp)

def save_marker(backup,phase):
    data={"format":"MAYA1_NEXT_V1","backup":str(backup),"phase":phase,
          "iran":IRAN,"ts":int(time.time())}
    fd,temp=tempfile.mkstemp(prefix=".cutover-",dir=str(ROOT))
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,"w") as f:
            json.dump(data,f);f.flush();os.fsync(f.fileno())
        os.replace(temp,MARK)
    finally:
        if os.path.exists(temp):os.unlink(temp)

def runtime_change(ports):
    for role,port in ports.items():
        answer=api(f"set server dual_egress/{role} addr 127.0.0.1 port {port}")
        after=live_rows()
        must(match_addr(after[role],port),
             "HAProxy runtime port did not change: "+role+" "+repr(answer))
        print("HAProxy",role,"now",after[role]["addr"],flush=True)
    must(all(match_addr(live_rows()[r],p) for r,p in ports.items()),
         "HAProxy runtime endpoints differ after cutover")

def check_gateway():
    r=call(["curl","-q","-4","--noproxy","","--socks5-hostname","127.0.0.1:18080",
            "--connect-timeout","5","--max-time","15","-fsS",
            "https://www.cloudflare.com/cdn-cgi/trace"],timeout=18,check=False)
    ips={"ip="+NEW[r][1] for r in NEW}
    must(r.returncode==0 and any(x in ips for x in r.stdout.splitlines()),
         "HAProxy gateway egress is not one of new Backhaul IPs")

def wait_controller(seconds=100):
    stop=time.monotonic()+seconds
    while time.monotonic()<stop:
        if active(SERVICE):
            try:
                doc=json.loads(STAT.read_text())
                age=(datetime.now(timezone.utc)-
                     datetime.fromisoformat(doc["updated_utc"])).total_seconds()
                if (doc.get("policy")=="two-backhaul-bulk-v1"
                        and 0<=age<15
                        and all(doc["paths"][r]["expected_foreign_ip"]==NEW[r][1] and
                                doc["paths"][r]["passed_probes"]>=2 and
                                doc["paths"][r]["bulk_pass"] is True and
                                doc["paths"][r]["bulk_last"].get("bytes")==1048576 and
                                doc["paths"][r]["bulk_last"].get("sample_pass",0)>=2
                                for r in NEW)):
                    return
            except (OSError,ValueError,KeyError,TypeError):
                pass
        time.sleep(2)
    raise RuntimeError("new controller failed to publish fresh verified dual-Backhaul status")

def backup():
    BKP.mkdir(mode=0o700,parents=True,exist_ok=True)
    dst=BKP/("maya1-cutover-"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
             +"-"+secrets.token_hex(3))
    dst.mkdir(mode=0o700)
    shutil.copy2(CFG,dst/"haproxy.cfg")
    shutil.copy2(CTR,dst/"controller.py")
    return dst

def rollback_inner(path):
    must(path.parent==BKP and path.is_dir() and not path.is_symlink(),
         "untrusted backup path")
    oldcfg=path/"haproxy.cfg";oldctrl=path/"controller.py"
    must(oldcfg.is_file() and oldctrl.is_file(),"incomplete backup")
    validate_cfg(oldcfg.read_text())
    # Stop new health probes before switching the gateway back to old ports.
    call(["systemctl","stop",SERVICE],timeout=15,check=False)
    atomic_bytes(CFG,oldcfg.read_bytes())
    atomic_bytes(CTR,oldctrl.read_bytes())
    for r,p in OLD.items():
        api(f"set server dual_egress/{r} addr 127.0.0.1 port {p}")
    must(all(match_addr(live_rows()[r],p) for r,p in OLD.items()),
         "rollback incomplete: HAProxy live target verification failed")
    call(["systemctl","start",SERVICE],timeout=20)
    must(active(SERVICE),"previous controller failed to restart")
    print("MAYA1_ROLLBACK_SUCCESS: original HAProxy endpoints/controller restored")
    print("No Xray, Backhaul or Mieru service was stopped.")

def switch(controller):
    must(not MARK.exists(),"existing cutover journal present, refusing new switch")
    strict_preflight(controller)
    oldcfg=CFG.read_text()
    candidate=persistent_text(oldcfg,OLD,{r:NEW[r][0] for r in NEW})
    dest=backup()
    print("BACKUP",dest,flush=True)
    save_marker(dest,"prepared")
    try:
        # Gate automation before any endpoint or persistent-file changes.
        call(["systemctl","stop",SERVICE],timeout=15)
        runtime_change({r:NEW[r][0] for r in NEW})
        save_marker(dest,"runtime_changed")
        atomic_bytes(CFG,candidate.encode())
        atomic_bytes(CTR,controller.read_bytes())
        save_marker(dest,"files_changed")
        call(["systemctl","start",SERVICE],timeout=20)
        wait_controller()
        check_gateway()
        save_marker(dest,"completed")
        print("MAYA1_DUAL_BACKHAUL_CUTOVER_SUCCESS")
        print("HAProxy leastconn and production Xray :443 unchanged")
        print("New connections now target SOCKS 21101/21102")
        print("Original Backhaul and Mieru services retained for rollback")
        print("ROLLBACK: sudo python3 /root/maya1-safe-cutover.py rollback")
    except BaseException:
        print("SWITCH_ERROR: automatically attempting rollback to old production",file=sys.stderr,flush=True)
        try:
            rollback_inner(dest)
            MARK.unlink(missing_ok=True)
        except BaseException as err:
            print("ROLLBACK_NEEDS_MANUAL_REVIEW: "+str(err)[:300],file=sys.stderr)
            print("BACKUP: "+str(dest),file=sys.stderr)
        raise

def rollback():
    must(MARK.is_file() and not MARK.is_symlink(),"no cutover marker")
    meta=json.loads(MARK.read_text())
    must(meta.get("format")=="MAYA1_NEXT_V1" and meta.get("iran")==IRAN,
         "invalid rollback marker")
    path=Path(meta["backup"])
    rollback_inner(path)
    MARK.unlink(missing_ok=True)

def main():
    must(len(sys.argv) in (2,3),"Usage: maya1-safe-cutover.py preflight|switch CONTROLLER or rollback")
    role=sys.argv[1]
    must(role in ("preflight","switch","rollback"),"unknown action")
    must((role=="rollback" and len(sys.argv)==2) or
         (role in ("preflight","switch") and len(sys.argv)==3),"incorrect arguments")
    must(os.geteuid()==0,"root required")
    with LOCK.open("a+") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if role=="rollback":
            rollback()
        elif role=="preflight":
            strict_preflight(Path(sys.argv[2]))
        else:
            switch(Path(sys.argv[2]))
if __name__=="__main__":
    try:main()
    except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired) as e:
        print("MAYA1_CUTOVER_ERROR:",str(e)[:400],file=sys.stderr)
        sys.exit(1)
