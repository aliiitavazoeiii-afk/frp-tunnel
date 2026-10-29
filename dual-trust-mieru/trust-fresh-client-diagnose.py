#!/usr/bin/env python3
"""Ephemeral read-only TrustTunnel differential on Iran dual/triple host.

Starts an isolated fresh Trust client ONLY at 127.0.0.1:17983 using the exact
current live Trust configuration apart from the local SOCKS listener.
No production carrier restart, no controller/dispatcher changes, no x-ui edit.
No client credentials/config/logs are printed.
"""
import argparse
import concurrent.futures
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

CONFIG=pathlib.Path("/etc/dual-trust-mieru/iran/trust-client.toml")
BIN=pathlib.Path("/usr/local/lib/dual-trust-mieru/trusttunnel_client")
CANDIDATE_PORT=17983
CURRENT_PORT=7993
MIERU_PORT=7994
ORIG_LINE='address = "127.0.0.1:7993"'
NEW_LINE='address = "127.0.0.1:17983"'
URLS=(
    ("GSTATIC","https://www.gstatic.com/generate_204",{"204"}),
    ("TELEGRAM_API","https://api.telegram.org/",{"200","301","302"}),
)

def candidate_config(text):
    # Fail closed on any unrecognized or duplicate local SOCKS listener;
    # never mutate endpoint host, username, password, cert, TLS profile.
    if text.count("[listener.socks]") != 1 or text.count(ORIG_LINE) != 1:
        raise ValueError("Unexpected Trust live SOCKS config: abort")
    if ("upstream_protocol = \"http2\"" not in text
        or "skip_verification = false" not in text
        or "[endpoint]" not in text):
        raise ValueError("Unexpected Trust transport/TLS configuration: abort")
    return text.replace(ORIG_LINE,NEW_LINE,1)

def port_available():
    with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1",CANDIDATE_PORT))
            return True
        except OSError:
            return False

def service_alive():
    result=subprocess.run(["systemctl","is-active","--quiet","dual-trust-client.service"],
                          timeout=5,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return result.returncode==0

def check_http(port,site,timeout):
    name,url,valid=site
    started=time.monotonic()
    try:
        cmd=["curl","-q","-4","-sS","--socks5-hostname",f"127.0.0.1:{port}",
             "--connect-timeout",str(min(5,timeout)),
             "--max-time",str(timeout),
             "-o","/dev/null","-w","%{http_code}|%{time_total}",url]
        env={k:v for k,v in os.environ.items()
             if k.lower() not in ("http_proxy","https_proxy","all_proxy","no_proxy")}
        r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                         timeout=timeout+2,text=True,env=env)
        fields=r.stdout.strip().split("|")
        code=fields[0] if fields else "000"
        sec=float(fields[1]) if len(fields)>1 else time.monotonic()-started
        return {"name":name,"port":port,"ok":r.returncode==0 and code in valid,
                "code":code,"elapsed_ms":int(sec*1000),"curl_exit":r.returncode}
    except (OSError,ValueError,subprocess.TimeoutExpired):
        return {"name":name,"port":port,"ok":False,"code":"000",
                "elapsed_ms":int((time.monotonic()-started)*1000),"curl_exit":"TIMEOUT"}

def wait_listener(proc):
    for _ in range(75):
        if proc.poll() is not None:
            raise RuntimeError("candidate Trust Client exited early; no production changes")
        try:
            with socket.create_connection(("127.0.0.1",CANDIDATE_PORT),0.2):
                return
        except OSError:
            time.sleep(0.12)
    raise RuntimeError("candidate Trust SOCKS listener failed to start")

def probe_paths(rounds,timeout):
    paths=(("TRUST_LIVE",CURRENT_PORT),
           ("TRUST_FRESH_SHADOW",CANDIDATE_PORT),
           ("MIERU_CONTROL",MIERU_PORT))
    stats={(name,site[0]):[] for name,_ in paths for site in URLS}
    print("=== TRUST LIVE vs FRESH SHADOW vs MIERU ===",flush=True)
    print("Isolated additional Trust Client :17983, original :7993 unchanged.",flush=True)
    print("Read-only route comparison; real user load not reproduced.",flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        for i in range(1,rounds+1):
            started=time.monotonic()
            tasks=[(label,port,site) for label,port in paths for site in URLS]
            rows=list(executor.map(lambda t:(t[0],check_http(t[1],t[2],timeout)),tasks))
            bad=[]
            for label,row in rows:
                stats[label,row["name"]].append(row)
                if not row["ok"] or row["elapsed_ms"]>2500:
                    bad.append(f'{label}/{row["name"]}='+
                               ("FAIL" if not row["ok"] else str(row["elapsed_ms"])+"ms"))
            if bad:
                print(f"round {i}: "+", ".join(bad),flush=True)
            elif i%3==0:
                print(f"completed {i}/{rounds}",flush=True)
            if i<rounds:
                time.sleep(max(0,1.5-(time.monotonic()-started)))
    print("\nRESULTS:",flush=True)
    for label,_ in paths:
        all_values=[row for site in URLS for row in stats[label,site[0]]]
        success=[row["elapsed_ms"] for row in all_values if row["ok"]]
        avg=round(sum(success)/len(success)) if success else "N/A"
        print(f"{label:<20} success={len(success)}/{len(all_values)} avg_success={avg}ms",
              flush=True)
        for site in URLS:
            rows=stats[label,site[0]]
            print(f"  {site[0]}: {sum(x['ok'] for x in rows)}/{len(rows)}",flush=True)

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--rounds",type=int,default=8)
    p.add_argument("--timeout",type=int,default=8)
    args=p.parse_args()
    if os.geteuid()!=0:p.error("run as root")
    if not 4<=args.rounds<=24 or not 5<=args.timeout<=12:
        p.error("rounds 4..24, timeout 5..12")
    if not CONFIG.is_file() or not BIN.is_file() or not os.access(BIN,os.X_OK):
        raise RuntimeError("expected TrustTunnel files absent")
    if not service_alive():raise RuntimeError("Trust live service inactive; abort")
    if not port_available():raise RuntimeError("test port 17983 occupied; abort")
    config=candidate_config(CONFIG.read_text())
    proc=None
    with tempfile.TemporaryDirectory(prefix="trust-shadow-",dir="/run") as folder:
        os.chmod(folder,0o700)
        cfg=pathlib.Path(folder)/"trust-shadow.toml"
        fd=os.open(cfg,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,"w") as file:file.write(config)
        try:
            with open(os.devnull,"w") as null:
                proc=subprocess.Popen([str(BIN),"--config",str(cfg)],
                                     stdin=subprocess.DEVNULL,
                                     stdout=null,stderr=null,
                                     close_fds=True,start_new_session=True)
            wait_listener(proc)
            time.sleep(2)
            if proc.poll() is not None:raise RuntimeError("Trust shadow exited after startup")
            probe_paths(args.rounds,args.timeout)
        finally:
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:proc.wait(timeout=7)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=4)
            print("Shadow Trust process stopped; private temporary configuration removed.",
                  flush=True)
if __name__=="__main__":
    try:main()
    except (OSError,RuntimeError,ValueError,subprocess.TimeoutExpired) as exc:
        print("TRUST SHADOW ABORT:",type(exc).__name__,str(exc)[:160],file=sys.stderr)
        sys.exit(1)
