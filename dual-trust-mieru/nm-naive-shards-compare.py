#!/usr/bin/env python3
"""Lightweight production-safe A/B: original Naive vs two-client shadow gateway.

Run after staging. No route changes or service restarts.
Does not print credentials, destination host IP or user flows.
"""
import argparse
import concurrent.futures
import os
import pathlib
import statistics
import subprocess
import sys
import time

PORTFILE=pathlib.Path("/etc/dual-trust-mieru/naive-shards/stage-port")
TARGETS=(
    ("NAIVE_SINGLE",7993),
    ("NAIVE_SHARDS_SHADOW",None),
    ("MIERU_REFERENCE",7994),
)
SITES=(
    ("gstatic","https://www.gstatic.com/generate_204",{"204"}),
    ("telegram","https://api.telegram.org/",{"200","301","302"}),
)
def active(name):
    x=subprocess.run(["systemctl","is-active","--quiet",name+".service"],
                     timeout=4,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return x.returncode==0
def run_one(task):
    name,port,site,url,accepted=task
    try:
        env={k:v for k,v in os.environ.items()
             if k.lower() not in ("http_proxy","https_proxy","all_proxy","no_proxy")}
        cp=subprocess.run(
            ["curl","-q","-4","-sS","--socks5-hostname",f"127.0.0.1:{port}",
             "--connect-timeout","4","--max-time","9","-o","/dev/null",
             "-w","%{http_code}|%{time_total}",url],
            capture_output=True,text=True,timeout=11,env=env)
        code,duration=cp.stdout.strip().split("|",1)
        passed=cp.returncode==0 and code in accepted
        ms=round(float(duration)*1000) if passed else None
        return (name,site,passed,ms)
    except (ValueError,OSError,subprocess.TimeoutExpired):
        return (name,site,False,None)
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--rounds",type=int,default=24)
    p.add_argument("--gap",type=float,default=2.0)
    args=p.parse_args()
    if os.geteuid()!=0: p.error("run as root")
    if not 6<=args.rounds<=120 or not 1<=args.gap<=30:
        p.error("rounds 6..120, gap 1..30 seconds")
    if not PORTFILE.is_file():
        p.error("shadow gateway not staged; run nm-naive-shards-maintenance.sh stage")
    port=int(PORTFILE.read_text().strip())
    if not 1025<=port<=65535:
        p.error("invalid staged port")
    for svc in ("nm-naive-client","nm-naive-shard-a","nm-naive-shard-b",
                "nm-naive-staging-gw","dual-mieru-carrier","dual-dispatcher","x-ui"):
        if not active(svc):
            p.error(f"required service not running: {svc}")
    overlay=pathlib.Path("/etc/systemd/system/nm-naive-client.service.d/90-naive-shards.conf")
    if overlay.exists():
        p.error("sharding already LIVE; original client no longer at 7993")
    targets=[(n,port if n=="NAIVE_SHARDS_SHADOW" else direct)
             for n,direct in TARGETS]
    measurements={(name,site):[] for name,_ in targets for site,_,_ in SITES}
    print("=== NAIVE SINGLE vs SHADOW SHARDS — SAFE A/B ===",flush=True)
    print(f"Production unchanged; staged gateway :{port}; {args.rounds} paired rounds.",flush=True)
    print("Two destinations per path, results reflect synthetic requests only.",flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        for i in range(1,args.rounds+1):
            start=time.monotonic()
            jobs=[(name,prt,site,url,accepted)
                  for name,prt in targets for site,url,accepted in SITES]
            result=list(executor.map(run_one,jobs))
            bad=[]
            for name,site,success,ms in result:
                measurements[name,site].append((success,ms))
                if not success or ms>=2500:
                    bad.append(f"{name}/{site}={'FAIL' if not success else str(ms)+'ms'}")
            if bad:
                print(f"round {i}: "+", ".join(bad),flush=True)
            elif i%6==0:
                print(f"completed {i}/{args.rounds}",flush=True)
            if i<args.rounds:
                time.sleep(max(0,args.gap-(time.monotonic()-start)))
    print("\n=== FINAL A/B RESULTS ===")
    for name,_ in targets:
        all_results=[r for site,_,_ in SITES for r in measurements[name,site]]
        ok=[ms for success,ms in all_results if success and ms is not None]
        good=len(ok)
        p95=round(sorted(ok)[min(len(ok)-1, max(0, (len(ok)*95+99)//100-1))]) if ok else "N/A"
        avg=round(statistics.mean(ok)) if ok else "N/A"
        print(f"{name:<22} success={good}/{len(all_results)} mean={avg}ms p95={p95}ms")
        for site,_,_ in SITES:
            part=measurements[name,site]
            print(f"  {site}: {sum(x[0] for x in part)}/{len(part)} successes")
    print("A/B complete. NO production route/service/config modifications.")
    print("Even a good short A/B does not prove behavior under hours of real load.")
if __name__=="__main__":
    try:main()
    except (OSError,ValueError,subprocess.TimeoutExpired) as ex:
        print("ABORT:",type(ex).__name__,str(ex)[:160],file=sys.stderr)
        sys.exit(1)
