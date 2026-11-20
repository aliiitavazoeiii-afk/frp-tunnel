#!/usr/bin/env python3
"""Read-only Maya1 WSSMux concurrency canary. NO live HAProxy config changes.

Four parallel exact 1-MiB HTTPS downloads PER NEW LANE, eight requests total.
Measures completed transfers and aggregate (not per-client) throughput.
Never checks or loads the production 21001/21002 SOCKS.
"""
import concurrent.futures
import re
import subprocess
import sys
import time

LANES={"BACKHAUL1":(21101,"82.152.132.159"),
       "BACKHAUL2":(21102,"152.237.230.77")}
FLOWS_PER_LANE=4
BYTES=1048576
LIMIT_SECONDS=45
URL="https://speed.cloudflare.com/__down?bytes=1048576"

def command(port,url,extra=(),timeout=LIMIT_SECONDS):
    args=["curl","-q","-4","--noproxy","",
          "--socks5-hostname","127.0.0.1:"+str(port),
          "--connect-timeout","6","--max-time",str(timeout),
          "--retry","0","--max-redirs","0","--fail","-sS",
          *extra,url]
    try:
        return subprocess.run(args,capture_output=True,text=True,timeout=timeout+3)
    except (OSError,subprocess.TimeoutExpired) as e:
        class Result:
            returncode=124
            stdout=""
            stderr=str(e)
        return Result()

def identity(port,ip):
    r=command(port,"https://www.cloudflare.com/cdn-cgi/trace",timeout=15)
    return r.returncode==0 and "ip="+ip in r.stdout.splitlines()

def sample(port):
    r=command(port,URL,
             ("-o","/dev/null","-w",
              "%{http_code} %{size_download} %{time_total} %{time_starttransfer}"),
             timeout=LIMIT_SECONDS)
    try:
        code,n,elapsed,ttfb=r.stdout.strip().split()
        amount=int(float(n));elapsed=float(elapsed);ttfb=float(ttfb)
        ok=r.returncode==0 and code=="200" and amount==BYTES and 0<elapsed<=LIMIT_SECONDS
        return {"ok":ok,"bytes":amount,"total_s":round(elapsed,3),
                "ttfb_s":round(ttfb,3),"http":code,"error":r.stderr.strip()[-110:]}
    except (ValueError,TypeError):
        return {"ok":False,"bytes":0,"total_s":None,"ttfb_s":None,
                "http":"?","error":r.stderr.strip()[-110:]}

def summarize(samples,wall_s):
    good=sum(bool(s["ok"]) for s in samples)
    total_bytes=sum(s["bytes"] for s in samples if s["ok"])
    # Throughput across ALL simultaneous requests, NOT a fabricated single-user speed.
    aggregate=round(total_bytes/max(0.001,wall_s)/1024,1)
    return {"ok":good==FLOWS_PER_LANE,
            "passed":good,"required":FLOWS_PER_LANE,
            "bytes_verified":total_bytes,"wall_s":round(wall_s,2),
            "aggregate_kib_s":aggregate,"requests":samples}

def main():
    print("MAYA1_CONCURRENCY_READ_ONLY; no HAProxy, controller or service changes",flush=True)
    print("Scope: 4x1MiB per staged path, simultaneous; maximum "+str(LIMIT_SECONDS)+"s per request",flush=True)
    for role,(port,ip) in LANES.items():
        ok=identity(port,ip)
        print("EGRESS",role,ip,"PASS" if ok else "FAIL",flush=True)
        if not ok:
            print("STOP: egress mismatch; no concurrent test started",flush=True)
            return 1
    started=time.monotonic()
    # All lanes launch together; executor bounded to 8 flows.
    jobs=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=FLOWS_PER_LANE*len(LANES)) as pool:
        for role,(port,_) in LANES.items():
            for n in range(1,FLOWS_PER_LANE+1):
                jobs.append((role,n,pool.submit(sample,port)))
        results={role:[] for role in LANES}
        for role,n,future in jobs:
            try:res=future.result()
            except Exception as e:
                res={"ok":False,"bytes":0,"total_s":None,"ttfb_s":None,
                     "http":"?","error":repr(e)[:110]}
            results[role].append(res)
            print(role,"flow",n, "PASS" if res["ok"] else "FAIL",
                  "bytes="+str(res["bytes"]),"elapsed_s="+str(res["total_s"]),
                  "ttfb_s="+str(res["ttfb_s"]), "error="+str(res["error"]),
                  flush=True)
    wall=time.monotonic()-started
    all_ok=True
    for role in LANES:
        summary=summarize(results[role],wall)
        all_ok=all_ok and summary["ok"]
        print(role, "CONCURRENT_SUCCESS="+str(summary["passed"])+"/4",
              "AGGREGATE_KiB_S="+str(summary["aggregate_kib_s"]),
              "TOTAL_WALL_S="+str(summary["wall_s"]),flush=True)
    if all_ok:
        print("MAYA1_NEW_PATHS_CONCURRENCY_CANARY_PASS",flush=True)
        print("This limited test is not proof of 400-client capacity.",flush=True)
        return 0
    print("MAYA1_NEW_PATHS_CONCURRENCY_CANARY_FAIL; DO NOT CUTOVER",flush=True)
    return 1

if __name__=="__main__":
    sys.exit(main())
