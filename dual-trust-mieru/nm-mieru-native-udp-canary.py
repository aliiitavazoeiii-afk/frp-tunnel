#!/usr/bin/env python3
"""Mieru NATIVE UDP candidate behind an isolated Xray SOCKS bridge.

This is a shadow canary only. It reads live config (never prints it), starts an
ephemeral Xray process on localhost :17992, compares native Mieru SOCKS-UDP
versus existing VLESS/XUDP, then terminates and removes its private temp files.
It DOES NOT change :7992, :7990, x-ui, HA policy, configuration or services.
"""
import argparse, concurrent.futures, importlib.util, json, os, pathlib, socket, subprocess
import sys, tempfile, time

LIVE=pathlib.Path("/etc/dual-trust-mieru/iran/xudp.json")
XRAY="/usr/local/lib/dual-trust-mieru/xray"
DIAG=pathlib.Path(__file__).with_name("nm-mieru-udp-diagnose.py")
CANDIDATE_PORT=17992
TARGETS=("1.1.1.1","8.8.8.8","9.9.9.9")

def candidate_configuration(data):
    if not isinstance(data,dict):
        raise ValueError("expected top-level Xray JSON object")
    if len(data.get("inbounds",[]))!=2:
        raise ValueError("unknown production inbounds")
    inbound=next((x for x in data["inbounds"] if x.get("tag")=="mieru-in"),None)
    proxy=next((x for x in data.get("outbounds",[]) if x.get("tag")=="carrier-mieru"),None)
    if (inbound is None or proxy is None
        or inbound.get("listen")!="127.0.0.1" or inbound.get("port")!=7992
        or inbound.get("protocol")!="socks" or not inbound.get("settings",{}).get("udp")
        or proxy.get("protocol")!="socks"
        or proxy.get("settings",{}).get("address")!="127.0.0.1"
        or proxy.get("settings",{}).get("port")!=7994):
        raise ValueError("live configuration differs from expected Naive/Mieru deployment")
    return {
        "log":{"loglevel":"warning"},
        "inbounds":[{**inbound,"port":CANDIDATE_PORT}],
        "outbounds":[proxy],
        "routing":{"domainStrategy":"AsIs","rules":[
            {"type":"field","inboundTag":["mieru-in"],"network":"tcp,udp",
             "outboundTag":"carrier-mieru"}]},
    }

def free_port():
    for typ in (socket.SOCK_STREAM,socket.SOCK_DGRAM):
        with socket.socket(socket.AF_INET,typ) as s:
            try:s.bind(("127.0.0.1",CANDIDATE_PORT))
            except OSError:return False
    return True

def load_diagnostic():
    if not DIAG.is_file():raise RuntimeError("diagnostic companion missing: "+str(DIAG))
    spec=importlib.util.spec_from_file_location("nm_mieru_udp_diagnostic",DIAG)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def sample(mod,port,resolver,timeout):
    return mod.attempt_socks_udp(port,resolver,timeout)

def http_204(port):
    cmd=["curl","-q","-4","-sS","--socks5-hostname",
         f"127.0.0.1:{port}","--connect-timeout","4","--max-time","8",
         "-o","/dev/null","-w","%{http_code}",
         "https://www.gstatic.com/generate_204"]
    try:
        r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                         timeout=10,text=True)
        return r.returncode==0 and r.stdout.strip()=="204"
    except (OSError,subprocess.TimeoutExpired):return False

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--rounds",type=int,default=3)
    parser.add_argument("--timeout",type=float,default=5.0)
    args=parser.parse_args()
    if not 2<=args.rounds<=8 or not 2<=args.timeout<=8:
        parser.error("rounds 2..8, timeout 2..8s")
    if os.geteuid()!=0:parser.error("root required")
    if not LIVE.is_file() or not os.access(XRAY,os.X_OK):
        parser.error("required production bridge config or Xray binary missing")
    if not free_port():
        parser.error("test TCP/UDP port 17992 already in use; production untouched")
    module=load_diagnostic()
    config=candidate_configuration(json.loads(LIVE.read_text()))
    print("=== MIERU NATIVE UDP SHADOW CANDIDATE ===",flush=True)
    print("Candidate only: 127.0.0.1:17992 -> Xray SOCKS -> Mieru native SOCKS 7994.",flush=True)
    print("Naive XUDP, live Mieru XUDP :7992, dispatcher, x-ui and HA unchanged.",flush=True)
    proc=None
    with tempfile.TemporaryDirectory(prefix="nm-mieru-native-canary-") as d:
        os.chmod(d,0o700)
        cfg=pathlib.Path(d)/"shadow.json"
        fd=os.open(cfg,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,"w") as out:json.dump(config,out)
        checked=subprocess.run([XRAY,"run","-test","-c",str(cfg)],
                               stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,
                               text=True,timeout=12)
        if checked.returncode:
            print("Xray rejected isolated candidate (details kept private).",file=sys.stderr)
            return 2
        try:
            with open(os.devnull,"w") as devnull:
                proc=subprocess.Popen([XRAY,"run","-c",str(cfg)],
                                      stdout=devnull,stderr=devnull,
                                      start_new_session=True)
            for _ in range(40):
                if proc.poll() is not None:raise RuntimeError("Xray candidate exited early")
                try:
                    with socket.create_connection(("127.0.0.1",CANDIDATE_PORT),0.5):break
                except OSError:time.sleep(0.15)
            else:raise RuntimeError("Xray candidate port not ready")
            labels=((7991,"NAIVE_CURRENT_XUDP"),(7992,"MIERU_CURRENT_XUDP"),
                    (7994,"MIERU_NATIVE_DIRECT"),(CANDIDATE_PORT,"MIERU_NATIVE_BRIDGE_CANDIDATE"))
            tasks=[(port,ip) for port,_ in labels for ip in TARGETS for _ in range(args.rounds)]
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results=list(pool.map(lambda x:sample(module,x[0],x[1],args.timeout),tasks))
            print("=== UDP DNS RESULTS ===")
            for port,label in labels:
                rows=[x for x in results if x["port"]==port]
                success=sum(x["ok"] for x in rows)
                print(f"{label:<32} :{port} {success}/{len(rows)}",flush=True)
                for ip in TARGETS:
                    subset=[x for x in rows if x["resolver"]==ip]
                    print(" ",ip," ".join("PASS" if x["ok"] else "FAIL "+x["stage"] for x in subset))
            print("=== HTTPS REGRESSION CANDIDATE VS LIVE ===")
            for port,label in ((7992,"LIVE_MIERU_TCP"),(CANDIDATE_PORT,"CANDIDATE_MIERU_TCP")):
                print(f"{label}: {'PASS' if http_204(port) else 'FAIL'}")
            candidate_ok=all(x["ok"] for x in results if x["port"]==CANDIDATE_PORT)
            print("RESULT:", "SHADOW CAN PROXY TESTED UDP TARGETS" if candidate_ok else
                  "SHADOW UDP UNHEALTHY — DO NOT CUT OVER",flush=True)
            print("Read-only shadow test ends with temporary Xray process terminated.",flush=True)
            return 0 if candidate_ok else 1
        finally:
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)

if __name__=="__main__":
    try:sys.exit(main())
    except (OSError,RuntimeError,ValueError,subprocess.TimeoutExpired) as ex:
        print("CANARY ABORTED:",str(ex)[:180],file=sys.stderr)
        sys.exit(2)
