#!/usr/bin/env python3
"""Guarded one-route production change: Mieru UDP via native Mieru SOCKS 7994.
A shared Xray Bridge restart affects Naive AND Mieru active connections.
Operator approval required; tested backup and automatic rollback on failure.
"""
import argparse, concurrent.futures, copy, datetime, fcntl, hashlib, importlib.util
import json, os, pathlib, subprocess, sys, tempfile, time, urllib.request

DIR=pathlib.Path("/etc/dual-trust-mieru/iran")
CONFIG=DIR/"xudp.json"
XRAY="/usr/local/lib/dual-trust-mieru/xray"
STATE=pathlib.Path("/var/lib/dual-trust-mieru/naive-mieru/mieru-udp-native")
BACKUP=STATE/"original.json"
RECORD=STATE/"record.json"
LOCK="/run/dual-trust-mieru-autoheal.lock"
SVC="dual-xudp-bridge.service"
HOME=pathlib.Path(__file__).resolve().parent
DNS=("1.1.1.1","8.8.8.8","9.9.9.9")

def hashof(data): return hashlib.sha256(data).hexdigest()
def data_bytes(value):return (json.dumps(value,indent=2,ensure_ascii=False)+"\n").encode()
def atom(path,raw):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,tmp=tempfile.mkstemp(prefix="."+path.name+".",dir=path.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,"wb") as f:
            f.write(raw);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
def known(obj):
    ins=obj.get("inbounds",[])
    outs=obj.get("outbounds",[])
    rules=obj.get("routing",{}).get("rules",[])
    if len(ins)!=2 or len(outs)!=4 or len(rules)!=4:
        raise RuntimeError("unexpected bridge topology: abort")
    mapping={x.get("tag"):x for x in ins}
    if set(mapping)!={"trust-in","mieru-in"}:
        raise RuntimeError("unexpected inbounds")
    for role,port in (("trust-in",7991),("mieru-in",7992)):
        item=mapping[role]
        if item.get("protocol")!="socks" or item.get("listen")!="127.0.0.1" or item.get("port")!=port or item.get("settings",{}).get("udp") is not True:
            raise RuntimeError("unexpected input "+role)
    out={x.get("tag"):x for x in outs}
    if set(out)!={"xudp-trust","xudp-mieru","carrier-trust","carrier-mieru"}:
        raise RuntimeError("unexpected Xray outbounds")
    for name,port in (("carrier-trust",7993),("carrier-mieru",7994)):
        item=out[name]
        if item.get("protocol")!="socks" or item.get("settings",{}).get("address")!="127.0.0.1" or item.get("settings",{}).get("port")!=port:
            raise RuntimeError("unexpected SOCKS proxy "+name)
    expected={("trust-in","tcp"):"carrier-trust",
              ("trust-in","udp"):"xudp-trust",
              ("mieru-in","tcp"):"carrier-mieru"}
    observed={}
    for rule in rules:
        key=(tuple(rule.get("inboundTag",[])),rule.get("network"))
        if rule.get("type")!="field" or len(key[0])!=1 or key in observed:
            raise RuntimeError("unexpected Xray routing rule")
        observed[key]=rule
    expected_keys={( (name,), proto):target for (name,proto),target in expected.items()}
    wanted=(("mieru-in",),"udp")
    if set(observed)!=set(expected_keys)|{wanted}:
        raise RuntimeError("unknown rule set")
    for key,target in expected_keys.items():
        if observed[key].get("outboundTag")!=target:
            raise RuntimeError("non-Mieru routing differs: abort")
    active=observed[wanted].get("outboundTag")
    if active not in ("xudp-mieru","carrier-mieru"):
        raise RuntimeError("invalid Mieru UDP outbound")
    return active
def proposed(raw):
    data=json.loads(raw)
    if known(data)!="xudp-mieru":raise RuntimeError("not original Mieru XUDP config")
    changed=copy.deepcopy(data)
    for rule in changed["routing"]["rules"]:
        if rule.get("inboundTag")==["mieru-in"] and rule.get("network")=="udp":
            rule["outboundTag"]="carrier-mieru"
    if known(changed)!="carrier-mieru":raise RuntimeError("invalid proposed route")
    return data_bytes(changed)
def test_xray(raw):
    with tempfile.TemporaryDirectory(prefix="nm-mieru-validate-") as d:
        f=pathlib.Path(d)/"xudp.json";atom(f,raw)
        cp=subprocess.run([XRAY,"run","-test","-c",str(f)],timeout=20,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if cp.returncode:raise RuntimeError("Xray validation failed")
def active(svc):
    return subprocess.run(["systemctl","is-active","--quiet",svc],timeout=5).returncode==0
def services():
    for name in ("x-ui","nm-naive-client","dual-mieru-carrier",
                 "dual-dispatcher","dual-xudp-bridge"):
        if not active(name+".service"):raise RuntimeError("service inactive: "+name)
    if not active("nm-ha.timer"):raise RuntimeError("HA timer inactive")
def pool():
    secret=(DIR/"controller.secret").read_text().strip()
    req=urllib.request.Request("http://127.0.0.1:19090/proxies/DUAL",
                                headers={"Authorization":"Bearer "+secret})
    with urllib.request.urlopen(req,timeout=5) as r:
        answer=json.load(r)
    if answer.get("type")!="Selector":raise RuntimeError("unknown DUAL group type")
    return answer.get("now","UNKNOWN")
def flow_count():
    secret=(DIR/"controller.secret").read_text().strip()
    req=urllib.request.Request("http://127.0.0.1:19090/connections",
                                headers={"Authorization":"Bearer "+secret})
    with urllib.request.urlopen(req,timeout=5) as r:
        data=json.load(r)
    connections=data.get("connections")
    if not isinstance(connections,list):
        raise RuntimeError("cannot verify active connection count")
    return len(connections)
def probe():
    if pool()!="DUAL-AUTO":raise RuntimeError("DUAL selector not balanced")
    if not (HOME/"nm-mieru-udp-diagnose.py").is_file():
        raise RuntimeError("missing read-only UDP probe companion")
    spec=importlib.util.spec_from_file_location("mieru_udp_prober",HOME/"nm-mieru-udp-diagnose.py")
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    tasks=[(p,ip) for p in (7991,7992,7990) for ip in DNS for _ in range(2)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=9) as tp:
        result=list(tp.map(lambda x:mod.attempt_socks_udp(x[0],x[1],5),tasks))
    ok=True
    for p in (7991,7992,7990):
        hits=[x for x in result if x["port"]==p]
        count=sum(x["ok"] for x in hits)
        print(f"UDP :{p} -> {count}/{len(hits)}",flush=True)
        if count<5:ok=False
    for p in (7991,7992,7990):
        try:
            cp=subprocess.run(["curl","-q","-4","-sS","--socks5-hostname",
                f"127.0.0.1:{p}","--connect-timeout","4","--max-time","9",
                "-o","/dev/null","-w","%{http_code}","https://www.gstatic.com/generate_204"],
                capture_output=True,text=True,timeout=11)
            passed=cp.returncode==0 and cp.stdout.strip()=="204"
        except (OSError,subprocess.TimeoutExpired):passed=False
        print(f"HTTPS :{p} -> {'PASS' if passed else 'FAIL'}",flush=True)
        if not passed:ok=False
    return ok
def restart(raw):
    atom(CONFIG,raw)
    if subprocess.run(["systemctl","restart",SVC],timeout=35).returncode:
        raise RuntimeError("shared bridge restart failed")
    time.sleep(2)
    services()
def preflight():
    services()
    if pool()!="DUAL-AUTO":raise RuntimeError("Selector isn't DUAL-AUTO")
    if BACKUP.exists() or RECORD.exists():
        raise RuntimeError("existing managed backup detected: run status first")
    original=CONFIG.read_bytes()
    candidate=proposed(original)
    test_xray(candidate)
    return original,candidate
def plan():
    original,candidate=preflight()
    print("PLAN ONLY: update Mieru UDP outbound xudp-mieru -> carrier-mieru")
    print("Unchanged: Naive TCP/UDP, Mieru TCP, dispatcher, HA, x-ui.")
    print("Current active Mihomo flows:",flow_count())
    print("Original digest:",hashof(original))
    print("Candidate digest:",hashof(candidate))
    print("WARNING: shared Bridge restart interrupts existing user sessions.")
def cutover():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise RuntimeError("interactive TTY required")
    # An independent shadow canary must pass BEFORE acquiring HA maintenance lock.
    canary=HOME/"nm-mieru-native-udp-canary.py"
    if not canary.is_file():raise RuntimeError("shadow canary script missing")
    if subprocess.run([sys.executable,str(canary),"--rounds","3","--timeout","5"],timeout=110).returncode:
        raise RuntimeError("native Mieru canary failed: no live changes")
    with open(LOCK,"a+") as handle:
        fcntl.flock(handle,fcntl.LOCK_EX)
        original,candidate=preflight()
        print("Current active Mihomo flows:",flow_count())
        print("WARNING: restart of shared Xray Bridge can interrupt BOTH Naive and Mieru sessions.")
        print("If postflight fails, automatic rollback requires a SECOND shared Bridge restart.")
        ans=input("Type FIX-MIERU-UDP to accept this risk: ").strip()
        if ans!="FIX-MIERU-UDP":
            print("CANCELLED: unchanged");return
        if CONFIG.read_bytes()!=original or pool()!="DUAL-AUTO":
            raise RuntimeError("production changed during confirmation; aborted")
        STATE.mkdir(parents=True,exist_ok=True,mode=0o700);STATE.chmod(0o700)
        atom(BACKUP,original)
        record={"schema":1,"before":hashof(original),"after":hashof(candidate),
                "status":"APPLYING","at":datetime.datetime.now(datetime.timezone.utc).isoformat()}
        atom(RECORD,data_bytes(record))
        try:
            restart(candidate)
            if not probe():raise RuntimeError("postflight Mieru/Naive UDP+HTTPS not fully healthy")
            record["status"]="LIVE"
            atom(RECORD,data_bytes(record))
            print("SUCCESS: Mieru UDP now routed to native SOCKS; both routes healthy.")
        except BaseException:
            print("CRITICAL: postflight failed. Automatic original configuration rollback now.")
            try:
                restart(original)
                record["status"]="ROLLED_BACK"
                atom(RECORD,data_bytes(record))
                print("Original config restored; verify service and user experience.")
            except BaseException:
                record["status"]="ROLLBACK_FAILED"
                atom(RECORD,data_bytes(record))
                print("CRITICAL: automatic rollback failed; original file preserved:",BACKUP)
            raise
def rollback():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise RuntimeError("interactive TTY required")
    with open(LOCK,"a+") as handle:
        fcntl.flock(handle,fcntl.LOCK_EX)
        if not BACKUP.is_file() or not RECORD.is_file():
            raise RuntimeError("original backup missing")
        meta=json.loads(RECORD.read_text())
        original=BACKUP.read_bytes()
        live=CONFIG.read_bytes()
        if hashof(original)!=meta.get("before") or hashof(live)!=meta.get("after"):
            raise RuntimeError("backup/current config checksum mismatch; abort")
        if known(json.loads(original))!="xudp-mieru" or known(json.loads(live))!="carrier-mieru":
            raise RuntimeError("unexpected rollback topology")
        services();test_xray(original)
        print("WARNING: reverting to previously failing Mieru XUDP and restarting shared Bridge.")
        if input("Type ROLLBACK-MIERU-UDP: ").strip()!="ROLLBACK-MIERU-UDP":
            print("CANCELLED");return
        if CONFIG.read_bytes()!=live:raise RuntimeError("config changed during confirmation")
        restart(original)
        meta["status"]="MANUALLY_ROLLED_BACK"
        atom(RECORD,data_bytes(meta))
        print("Original XUDP bridge restored. Run full health checks.")
def status():
    print("Live Mieru UDP route:",known(json.loads(CONFIG.read_text())))
    print("Bridge active:",active(SVC))
    if RECORD.exists():
        meta=json.loads(RECORD.read_text())
        print("Recorded deployment status:",meta.get("status","UNKNOWN"))
        print("Managed backup available:",BACKUP.is_file())
    else:print("No managed deployment record")
def main():
    p=argparse.ArgumentParser()
    p.add_argument("command",choices=("status","plan","cutover","rollback"))
    args=p.parse_args()
    if os.geteuid()!=0:p.error("root required")
    {"status":status,"plan":plan,"cutover":cutover,"rollback":rollback}[args.command]()
if __name__=="__main__":
    try:main()
    except (OSError,RuntimeError,ValueError,KeyError,subprocess.TimeoutExpired) as error:
        print("MIERU UDP MAINTENANCE ABORTED:",type(error).__name__,str(error)[:180],
              file=sys.stderr)
        sys.exit(1)
