#!/usr/bin/env python3
"""Read-only Maya1 dual-Backhaul quality audit (never modifies a service).

Compare cold 256 KiB single-request metrics to 1 MiB repeated transfers.
The production paths are probed only once each as a reference.
Not a cutover or configuration-changing command.
"""
import os
import re
import statistics
import subprocess
import sys
from datetime import datetime, timezone

EXPECTED = {
    "NEW_BH1": (21101, "82.152.132.159", 3),
    "NEW_BH2": (21102, "152.237.230.77", 3),
    "OLD_BH1_REFERENCE": (21001, None, 1),
    "OLD_MIERU_REFERENCE": (21002, None, 1),
}
BULK_URL = "https://speed.cloudflare.com/__down?bytes="
TRACE_URL = "https://www.cloudflare.com/cdn-cgi/trace"
REQUIRED_SPEED_BPS = 96 * 1024
REQUIRED_BYTES = 1048576

def curl(port, url, extra=(), timeout=24):
    argv = ["curl", "-q", "-4", "--noproxy", "",
            "--socks5-hostname", "127.0.0.1:" + str(port),
            "--connect-timeout", "5", "--max-time", str(timeout),
            "--retry", "0", "--max-redirs", "0", "--fail", "--silent",
            "--show-error", *extra, url]
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout+3)
    except (OSError, subprocess.TimeoutExpired) as error:
        class Failure:
            returncode = 124
            stdout = ""
            stderr = str(error)
        return Failure()

def egress(port):
    r = curl(port, TRACE_URL, timeout=16)
    if r.returncode != 0:
        return "ERROR: " + r.stderr.strip()[-130:]
    match = re.search(r"(?m)^ip=(\d{1,3}(?:\.\d{1,3}){3})$",r.stdout)
    return match.group(1) if match else "ERROR: response missing ip="

def bulk(port,size):
    fmt="%{http_code} %{size_download} %{speed_download} %{time_total} %{time_starttransfer} %{time_connect} %{time_appconnect}"
    r = curl(port, BULK_URL+str(size),
             ("--output","/dev/null","--write-out",fmt),timeout=24)
    try:
        http,count,speed,total,ttfb,tcp,tls = r.stdout.strip().split()
        count=int(float(count))
        elapsed=float(total)
        ttfb=float(ttfb)
        speed=float(speed)
        return {
            "ok": r.returncode==0 and http=="200" and count==size,
            "http":http, "bytes":count,
            "speed_kib_s":round(speed/1024,1),
            "time_s":round(elapsed,3),
            "ttfb_s":round(ttfb,3),
            "transfer_kib_s":round(count/max(0.001,elapsed-ttfb)/1024,1),
            "error":r.stderr.strip()[-110:] if r.returncode else "",
        }
    except (ValueError,TypeError):
        return {"ok":False,"http":"?","bytes":0,"error":r.stderr.strip()[-110:] or "malformed curl stats"}

def quality_ok(row):
    return bool(row.get("ok") and row["bytes"]==REQUIRED_BYTES
                and row["time_s"]<=12
                and row["ttfb_s"]<=8
                and row["speed_kib_s"]*1024>=REQUIRED_SPEED_BPS)

def fmt(row):
    return ("PASS" if row["ok"] else "FAIL") + " " + " ".join(
        str(key)+"="+str(row.get(key,"?"))
        for key in ("http","bytes","speed_kib_s","time_s","ttfb_s","transfer_kib_s","error"))

def main():
    print("MAYA1 READ-ONLY NETWORK QUALITY AUDIT; no service changes",flush=True)
    print("UTC:",datetime.now(timezone.utc).isoformat(),flush=True)
    failures=[]
    for name,(port,ip,repeats) in EXPECTED.items():
        print("\n==",name,"SOCKS",port,"==",flush=True)
        observed=egress(port)
        print("IP",observed,"EXPECTED",ip or "(reference only)",flush=True)
        if ip is not None and observed!=ip:
            failures.append(name+": egress")
        one=bulk(port,262144)
        print("256KiB (cold):",fmt(one),flush=True)
        runs=[]
        for i in range(repeats):
            row=bulk(port,REQUIRED_BYTES)
            runs.append(row)
            print("1MiB",str(i+1)+"/"+str(repeats)+":",fmt(row),flush=True)
        count=sum(quality_ok(row) for row in runs)
        if name.startswith("NEW_"):
            print("NEW_PATH_1M_QUALITY:",count,"/",repeats,flush=True)
            if count<2:failures.append(name+": fewer than 2 of 3 one-MiB transfers met 96KiB/s + TTFB/total bounds")
        else:
            print("REFERENCE_PATH_1M:", "PASS" if any(x["ok"] for x in runs) else "FAIL",flush=True)
    if failures:
        print("\nAUDIT_NEW_PATH_QUALITY_NOT_VERIFIED:", "; ".join(failures),flush=True)
        return 1
    print("\nAUDIT_NEW_PATH_QUALITY_VERIFIED_1M_2_OF_3",flush=True)
    print("NOTE: This does not alter the existing 256KiB health-controller policy.",flush=True)
    return 0

if __name__=="__main__":
    sys.exit(main())
