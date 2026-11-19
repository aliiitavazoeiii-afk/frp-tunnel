#!/usr/bin/env python3
"""Optional, explicitly confirmed Maya3 Backhaul1 client pool-guard cutover.

Changes ONLY the FOREIGN Backhaul1 client binary and its systemd service.
Never edits Iran Xray, Backhaul2, HAProxy configuration, TLS/SNI or WS options.
Live primary sessions necessarily disconnect on the foreign-client restart;
preflight verifies the other lane before setting Backhaul1 weight=0.
"""
from __future__ import annotations
import contextlib
import fcntl
import ipaddress
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.path.insert(0, "/opt/dual-ha/helper")
import dual
from dual_swap_v3 import get_weight, set_weight, probe

PRIMARY="152.237.230.140"
SECOND="82.152.132.112"
IRAN="185.215.230.221"
CANDIDATE="/opt/dual-ha/bin/backhaul-poolguard-v1"
SSH= ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
      "-o", "ConnectTimeout=10", "root@"+PRIMARY]
LOCK=Path("/run/maya3-poolguard-cutover.lock")

def run(argv, *, timeout=30, input_=None):
    r=subprocess.run(argv,input=input_,capture_output=True,text=True,timeout=timeout)
    if r.returncode:
        raise RuntimeError("Command failed ("+str(r.returncode)+"): "+r.stderr[-600:])
    return r.stdout

def confirm_live():
    assert os.geteuid()==0, "Root required"
    assert dual.iran_ip()==IRAN, "Wrong Iran host"
    assert dual.read_bundle()["BH_FOREIGN_IP"]==PRIMARY, "Primary changed"
    from json import loads
    m=loads(Path("/etc/dual-ha/bh2-experiment/state.json").read_text())
    assert m["mode"]=="active" and m["foreign_ip"]==SECOND, "Secondary changed"
    assert get_weight("mieru")>0, "Secondary path operator-disabled"
    for name in ("dual-ha-v2-gateway","dual-ha-v2-health","dual-ha-backhaul",
                 "dual-ha-bh2-server"):
        assert subprocess.run(["systemctl","is-active","--quiet",name]).returncode==0, name+" not active"
    print("Checking secondary health before touching primary...",flush=True)
    assert probe(21002,SECOND,label="SURVIVING BACKHAUL2"),"Backhaul2 real transfer gate failed"
    return get_weight("backhaul")

def foreign_python(program,*, timeout=40):
    return run(SSH+["python3","-"],input_=program,timeout=timeout).strip()

CHECK=r'''
import pathlib,subprocess
original=pathlib.Path('/opt/dual-ha/bin/backhaul')
candidate=pathlib.Path('/opt/dual-ha/bin/backhaul-poolguard-v1')
assert original.is_file() and not original.is_symlink()
assert candidate.is_file() and not candidate.is_symlink()
assert original.stat().st_size>100000 and candidate.stat().st_size>100000
assert candidate.stat().st_mode&0o111
unit=subprocess.run(['systemctl','cat','dual-ha-backhaul-client'],
                    capture_output=True,text=True,check=True).stdout
assert 'ExecStart=/opt/dual-ha/bin/backhaul -c /etc/dual-ha/backhaul-foreign.toml' in unit
assert subprocess.run(['systemctl','is-active','--quiet','dual-ha-backhaul-client']).returncode==0
assert subprocess.run(['systemctl','is-active','--quiet','danted']).returncode==0
print('FOREIGN_CANDIDATE_VALID')
'''
ACTIVATE=r'''
import os,pathlib,shutil,subprocess,time
src=pathlib.Path('/opt/dual-ha/bin/backhaul')
candidate=pathlib.Path('/opt/dual-ha/bin/backhaul-poolguard-v1')
base=pathlib.Path('/root/dual-backhaul-backups')
base.mkdir(mode=0o700,parents=True,exist_ok=True)
snapshot=base/('poolguard-old-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'.bin')
assert not snapshot.exists()
shutil.copy2(src,snapshot); snapshot.chmod(0o700)
tmp=src.with_name(src.name+'.poolguard.next')
assert not tmp.exists()
shutil.copy2(candidate,tmp);tmp.chmod(0o755)
os.replace(tmp,src)
result=subprocess.run(['systemctl','restart','dual-ha-backhaul-client'],
                    capture_output=True,text=True,timeout=30)
if result.returncode:
    shutil.copy2(snapshot,src.with_name(src.name+'.prior.next'))
    os.replace(src.with_name(src.name+'.prior.next'),src)
    subprocess.run(['systemctl','restart','dual-ha-backhaul-client'],timeout=30)
    raise SystemExit('RESTART_FAILED_RESTORED_PREVIOUS_BINARY')
assert subprocess.run(['systemctl','is-active','--quiet','dual-ha-backhaul-client']).returncode==0
print('POOLGUARD_ACTIVE')
print('BACKUP='+str(snapshot))
'''
RESTORE=r'''
import os,pathlib,shutil,subprocess,sys
src=pathlib.Path('/opt/dual-ha/bin/backhaul')
snapshot=pathlib.Path(sys.argv[1])
assert snapshot.parent==pathlib.Path('/root/dual-backhaul-backups')
assert snapshot.name.startswith('poolguard-old-') and snapshot.suffix=='.bin'
assert snapshot.is_file() and not snapshot.is_symlink()
tmp=src.with_name(src.name+'.poolguard.rollback.next')
shutil.copy2(snapshot,tmp);tmp.chmod(0o755)
os.replace(tmp,src)
subprocess.run(['systemctl','restart','dual-ha-backhaul-client'],check=True,timeout=30)
print('OLD_CLIENT_BINARY_RESTORED')
'''
def ssh_restore(snapshot):
    import shlex
    return run(SSH+["python3 - "+shlex.quote(snapshot)], input_=RESTORE,timeout=40)

def reverse_sockets():
    r=run(["ss","-Htn","state","established","(",
           "sport","=",":18443",")"],timeout=10)
    count=0
    for line in r.splitlines():
        cols=line.split()
        if len(cols)>=4 and cols[3].rsplit(":",1)[0].strip("[]")==PRIMARY:
            count+=1
    return count

def main():
    original=confirm_live()
    print("FOREIGN1:",PRIMARY,"| FOREIGN2:",SECOND)
    print("Original PRIMARY weight:",original)
    print("Established reverse carrier sockets:",reverse_sockets())
    assert foreign_python(CHECK)=="FOREIGN_CANDIDATE_VALID","Foreign canary binary not verified"
    print("\nWARNING: switching the foreign1 client restarts its existing reverse TLS/MUX")
    print("and disconnects established TCP streams on Backhaul1; only NEW streams")
    print("will use the surviving Backhaul2 until this client passes health checks.")
    word=input("Type CUTOVER BACKHAUL1 to authorize this disruption: ").strip()
    if word!="CUTOVER BACKHAUL1":
        print("CANCELLED: nothing changed")
        return
    snapshot=""
    swapped=False
    weight_zero=False
    with LOCK.open("a+") as fd:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        try:
            assert get_weight("mieru")>0, "Backhaul2 disabled before cutover"
            if original:
                set_weight("backhaul",0)
                weight_zero=True
                print("Primary drained for NEW sessions; existing ones remain",flush=True)
            time.sleep(15)
            print("Remaining old primary active sockets:",reverse_sockets(),flush=True)
            output=foreign_python(ACTIVATE,timeout=55)
            assert "POOLGUARD_ACTIVE" in output,"Candidate foreign restart failed"
            m=re.search(r"(?m)^BACKUP=(/root/dual-backhaul-backups/poolguard-old-[0-9TZ]+\.bin)$",output)
            assert m,"Foreign backup path missing"
            snapshot=m.group(1)
            swapped=True
            print(output,flush=True)
            # Verify egress + complete actual download through the restarted client.
            deadline=time.monotonic()+65
            ok=False
            while time.monotonic()<deadline:
                if probe(21001,PRIMARY,label="POOLGUARD BACKHAUL1"):
                    ok=True;break
                time.sleep(3)
            if not ok:
                raise RuntimeError("New Backhaul1 client did not pass full-transfer egress")
            time.sleep(10)
            n=reverse_sockets()
            print("AFTER NEW CLIENT: reverse TCP ESTABLISHED=",n,flush=True)
            if n>68:
                raise RuntimeError("Reverse physical sockets exceed expected 64+control cap")
            if original>0:
                set_weight("backhaul",original)
            print("SUCCESS: bounded foreign Backhaul1 physical WSSMux pool (<=64)")
            print("Old client binary saved on foreign VPS:",snapshot)
            print("Iran HAProxy leastconn, anti-DPI, Xray and Backhaul2 unchanged.")
        except BaseException:
            print("FAIL: attempting safe restore. Backhaul2 left enabled.",file=sys.stderr)
            if swapped and snapshot:
                with contextlib.suppress(Exception):
                    print(ssh_restore(snapshot),file=sys.stderr)
            if weight_zero:
                # Never send new users to an unproven Backhaul1.
                with contextlib.suppress(Exception):
                    if probe(21001,PRIMARY,label="RECOVERED BACKHAUL1"):
                        set_weight("backhaul",original)
                        print("Original primary weight restored",file=sys.stderr)
                    else:
                        print("BACKHAUL1 remains weight 0; surviving BACKHAUL2 online",file=sys.stderr)
            raise

if __name__=="__main__":
    try:
        main()
    except (OSError,ValueError,RuntimeError,AssertionError,subprocess.TimeoutExpired) as e:
        print("POOLGUARD ERROR:",str(e)[:600],file=sys.stderr)
        sys.exit(1)
