#!/usr/bin/env python3
"""Maya3 dual Backhaul read-only jitter/TCP telemetry; NEVER mutates the tunnel.
Examples:
    sudo python3 dual-backhaul-jitter-audit.py --samples 24
    sudo python3 dual-backhaul-jitter-audit.py --samples 24 --load 1
    sudo python3 dual-backhaul-jitter-audit.py --verify
No SOCKS credentials, bundles or user traffic are captured.
"""
from __future__ import annotations
import argparse
import concurrent.futures as cf
import csv
import io
import json
from pathlib import Path
import re
import socket
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone

PORTS={"backhaul1":21001,"backhaul2":21002,"gateway":18080}
TARGETS = {
    "cloudflare_trace":"https://www.cloudflare.com/cdn-cgi/trace",
    "instagram_robots":"https://www.instagram.com/robots.txt",
}
DOWNLOAD="https://speed.cloudflare.com/__down?bytes=1048576"
CONTROL="/run/dual-ha-v2/haproxy.sock"
WFORMAT="%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{speed_download}"
VIRTUAL="second_backend_named_mieru_is_backhaul2"

def run(argv, timeout=18):
    try:
        return subprocess.run(argv, capture_output=True,text=True,
                              timeout=timeout,check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return type("Result",(),{"returncode":124, "stdout":"",
                  "stderr":str(exc)})()

def sample(port,url,timeout=15):
    cmd=["curl","-q","-4","--noproxy","","--socks5-hostname",
         "127.0.0.1:"+str(port),"--silent","--show-error",
         "--connect-timeout","5","--max-time",str(timeout),"--retry","0",
         "--max-redirs","0","--output","/dev/null","--write-out",WFORMAT,url]
    r=run(cmd,timeout+2)
    values=r.stdout.strip().split()
    out={"ok":False,"http":0,"connect_ms":None,"tls_ms":None,
         "ttfb_ms":None,"total_ms":None,"bytes":0,"Bps":0,
         "curl_exit":r.returncode,"reason":""}
    try:
        code,connect,tls,first,total,nbytes,speed=values
        out.update(http=int(code),connect_ms=round(float(connect)*1000,2),
            tls_ms=round(float(tls)*1000,2),ttfb_ms=round(float(first)*1000,2),
            total_ms=round(float(total)*1000,2),bytes=int(float(nbytes)),
            Bps=round(float(speed)))
        # For Instagram a 403, 429 or other HTTP response still establishes
        # a SOCKS -> TLS path, though it is NOT app success.
        out["ok"]=r.returncode==0 and int(code)>0 and float(first)>0
        out["reason"]="ok" if out["ok"] else "http_or_transport_error"
    except (ValueError,TypeError):
        out["reason"]="curl_exit_"+str(r.returncode)
    return out

def percentile(data, p):
    if not data:
        return None
    s=sorted(data)
    i=(len(s)-1)*p/100.0
    lo=int(i)
    hi=min(lo+1,len(s)-1)
    return round(s[lo]+(s[hi]-s[lo])*(i-lo),1)

def summary(samples):
    good=[s for s in samples if s["ok"]]
    series=[s["ttfb_ms"] for s in good if s["ttfb_ms"] is not None]
    return {
        "count":len(samples),"ok":len(good),"fail":len(samples)-len(good),
        "ttfb_p50_ms":percentile(series,50),
        "ttfb_p95_ms":percentile(series,95),
        "ttfb_p99_ms":percentile(series,99),
        "ttfb_max_ms":max(series) if series else None,
        "ttfb_over_800ms":sum(x>800 for x in series),
        "ttfb_over_1400ms":sum(x>1400 for x in series),
        "http_codes":{str(code):sum(x["http"]==code for x in samples)
                      for code in sorted({x["http"] for x in samples})},
        "errors":[s["reason"] for s in samples if not s["ok"]],
    }

def haproxy_snapshot():
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(3)
            s.connect(CONTROL)
            s.sendall(b"show stat\n")
            s.shutdown(socket.SHUT_WR)
            chunks=[]
            while True:
                x=s.recv(65536)
                if not x: break
                chunks.append(x)
                if sum(map(len,chunks))>1024*1024:
                    raise ValueError("HAProxy response too large")
        lines=b"".join(chunks).decode(errors="replace").splitlines()
        fields=lines[0].lstrip("# ").split(",")
        result={}
        for r in csv.DictReader(io.StringIO("\n".join(lines[1:])),fieldnames=fields):
            if r.get("pxname")=="dual_egress" and r.get("svname") in ("backhaul","mieru"):
                result[r["svname"]] = {
                    k:r.get(k) for k in ("status","weight","scur","stot","bin","bout",
                                         "econ","eresp","wretr","wredis","chkfail")
                }
        return result
    except (OSError,ValueError,IndexError) as exc:
        return {"error":type(exc).__name__}

def tcp_stats():
    # Only established carrier socket telemetry. No packet payload capture.
    data={}
    for port in (18443,18445):
        r=run(["ss","-tni","state","established",f"( sport = :{port} or dport = :{port} )"],8)
        lines=r.stdout.splitlines()
        vals=[]
        for row in lines:
            if re.search(r"(?:rtt:|retrans:|bytes_retrans:|rto:|delivery_rate|cwnd:)",row):
                stats={}
                for key,pat in (
                    ("rtt_ms",r"\brtt:([\d.]+)/"),
                    ("rto_ms",r"\brto:(\d+)"),
                    ("retrans",r"\bretrans:(\d+)/(\d+)"),
                    ("bytes_retrans",r"\bbytes_retrans:(\d+)"),
                    ("cwnd",r"\bcwnd:(\d+)"),
                ):
                    match=re.search(pat,row)
                    if match:
                        stats[key]=match.group(1)
                if stats:
                    vals.append(stats)
        data[str(port)] = {
            "socket_rows":sum(1 for l in lines if "ESTAB" in l or re.search(r":\d{4,5}\b",l)),
            "transport_samples":len(vals),
            "rtt_p50_ms":percentile([float(v["rtt_ms"]) for v in vals if "rtt_ms" in v],50),
            "rtt_p95_ms":percentile([float(v["rtt_ms"]) for v in vals if "rtt_ms" in v],95),
            "max_retrans_count":max([int(v["retrans"].split("/")[0]) for v in vals
                                   if "retrans" in v]+[0]),
            "sum_bytes_retrans":sum(int(v.get("bytes_retrans",0)) for v in vals),
        }
    return data

def sys_counters():
    out={}
    r=run(["nstat","-az"],8)
    for line in r.stdout.splitlines():
        p=line.split()
        if len(p)>=2 and p[0] in (
            "TcpRetransSegs","TcpExtTCPLostRetransmit","TcpExtTCPTimeouts",
            "TcpExtTCPRenoRecovery","TcpExtTCPSackRecovery","TcpExtListenOverflows",
            "TcpExtTCPMemoryPressures","TcpExtTCPRcvQDrop"
        ):
            with __import__("contextlib").suppress(ValueError):
                out[p[0]]=int(p[1])
    return out

def no_secrets_config():
    paths={
      "backhaul1_iran":"/etc/dual-ha/backhaul-iran.toml",
      "backhaul2_iran":"/etc/dual-ha/bh2-experiment/iran.toml",
    }
    allowed={"transport","keepalive_period","heartbeat","nodelay","channel_size",
             "mux_con","mux_version","mux_framesize","mux_recievebuffer",
             "mux_streambuffer"}
    summary={}
    for k,v in paths.items():
        try:
            lines=Path(v).read_text().splitlines()
            values={}
            for line in lines:
                m=re.fullmatch(r"([a-z_]+) = ([^\s#]+)",line.strip())
                if m and m.group(1) in allowed:
                    values[m.group(1)]=m.group(2)
            summary[k]=values
        except OSError:
            summary[k]={"error":"unavailable"}
    return summary

def check_host():
    d=json.loads(Path("/etc/dual-ha/bh2-experiment/state.json").read_text())
    bundle=Path("/etc/dual-ha/backhaul-bundle.env").read_text()
    if not (d.get("mode")=="active" and d.get("foreign_ip") and
            "BH_IRAN_IP='185.215.230.221'" in bundle):
        raise RuntimeError("This diagnostic is for Maya3's active two-Backhaul mode only")

def print_summary(name, values):
    print("\n"+name)
    for target in TARGETS:
        s=summary(values[target])
        print("  %-19s ok=%2d/%2d ttfb P50=%s P95=%s MAX=%s ms >800ms=%d >1400ms=%d codes=%s" %
             (target,s["ok"],s["count"],s["ttfb_p50_ms"],s["ttfb_p95_ms"],
              s["ttfb_max_ms"],s["ttfb_over_800ms"],s["ttfb_over_1400ms"],
              s["http_codes"]),flush=True)
        if s["fail"]:
            print("    FAILURES:",s["fail"],"curl errors:",s["errors"][:8])

def audit(n,interval,load):
    check_host()
    start=datetime.now(timezone.utc).isoformat()
    print("READ ONLY | Maya3 | no service restart / change | "+start,flush=True)
    print("Will issue %d sequential request rounds per endpoint, three paths in parallel." % n,flush=True)
    print("Stats: TTFB percentiles are application TLS/HTTP timings, not ICMP ping.",flush=True)
    print("SOCKS ports: 21001 Backhaul1, 21002 Backhaul2, 18080 leastconn gateway.")
    print("HAProxy before:",json.dumps(haproxy_snapshot()))
    print("Non-secret transport settings:",json.dumps(no_secrets_config(),ensure_ascii=False))
    tcp_before=tcp_stats()
    counters_before=sys_counters()
    print("Carrier TCP before:",json.dumps(tcp_before),flush=True)
    measurements={path:{target:[] for target in TARGETS} for path in PORTS}
    load_results={x:[] for x in PORTS}

    def one_round(role):
        port=PORTS[role]
        result={}
        for target,url in TARGETS.items():
            result[target]=sample(port,url)
        return result

    # Curl subprocesses for distinct paths run in parallel so spikes across
    # paths can be compared at approximately the same point in time.
    with cf.ThreadPoolExecutor(max_workers=3) as pool:
        for i in range(n):
            f={role:pool.submit(one_round,role) for role in PORTS}
            for role in PORTS:
                res=f[role].result()
                for target,value in res.items():
                    measurements[role][target].append(value)
            if load and i in (n//3,2*n//3):
                # Bounded 1-MiB transfers; not a saturation/stress test.
                for role in ("backhaul1","backhaul2"):
                    result=sample(PORTS[role], DOWNLOAD,timeout=20)
                    load_results[role].append(result)
            if (i+1)%max(1,n//4)==0:
                print("  progress %s/%s" % (i+1,n),flush=True)
            if i<n-1:
                time.sleep(interval)

    after_tcp=tcp_stats()
    after_counters=sys_counters()
    print("\n=== READ-ONLY JITTER RESULTS ===",flush=True)
    for role in PORTS:
        print_summary(role,measurements[role])
    print("\nHAProxy after:",json.dumps(haproxy_snapshot()))
    print("Carrier TCP after:",json.dumps(after_tcp))
    print("Global TCP counter changes (all server traffic, not lane-specific):",
          json.dumps({k:after_counters.get(k,0)-v for k,v in counters_before.items()}))
    print("Bulk samples:",json.dumps(load_results))
    results={
        "started_at":start, "finished_at":datetime.now(timezone.utc).isoformat(),
        "samples":n,"interval_seconds":interval,
        "paths":{role:{name:summary(rows) for name,rows in groups.items()}
                 for role,groups in measurements.items()},
        "details":measurements,"bulk":load_results,
        "tcp_before":tcp_before,"tcp_after":after_tcp,
        "global_tcp_delta":{k:after_counters.get(k,0)-v for k,v in counters_before.items()},
        "haproxy_after":haproxy_snapshot(),
        "transport_settings":no_secrets_config(),
    }
    save=Path("/root/dual-backhaul-jitter-audit.json")
    try:
        save.write_text(json.dumps(results,indent=2,ensure_ascii=False)+"\n")
        save.chmod(0o600)
        print("\nSaved detailed non-secret report:",save)
    except OSError as exc:
        print("Report save failed:",type(exc).__name__)
    if all(sum(1 for s in measurements[x]["cloudflare_trace"] if s["ok"])<n//2 for x in PORTS):
        print("WARNING: all routes failed most probe requests; public test origin may be blocked.")
    print("No changes made to HAProxy, Backhaul, anti-DPI or kernel settings.",flush=True)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--samples",type=int,default=24)
    parser.add_argument("--interval",type=float,default=0.5)
    parser.add_argument("--load",type=int,choices=(0,1),default=0)
    parser.add_argument("--verify",action="store_true")
    args=parser.parse_args()
    if args.verify:
        print("READ_ONLY_AUDIT_READY")
        return 0
    if not 8<=args.samples<=80:
        parser.error("--samples must be between 8 and 80")
    if not 0.1<=args.interval<=3.0:
        parser.error("--interval must be between 0.1 and 3")
    audit(args.samples,args.interval,args.load)
    return 0

if __name__=="__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError,ValueError) as ex:
        print("AUDIT ERROR:",str(ex),file=sys.stderr)
        sys.exit(1)
