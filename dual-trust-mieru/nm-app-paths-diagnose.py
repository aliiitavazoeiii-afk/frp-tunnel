#!/usr/bin/env python3
"""READ ONLY application path diagnostics for Iran Naive/Mieru live SOCKS ports.

Tests real HTTPS targets separately for Naive and Mieru and small/large
DNS-over-UDP through SOCKS5 UDP ASSOCIATE. All outputs are aggregated and
contain no user IPs, subscription data, proxy secrets or configs.
Does not restart/stop/reload services, modify route selection or touch files.
"""
import argparse
import concurrent.futures
import importlib.util
import os
import pathlib
import random
import socket
import struct
import subprocess
import sys
import time

TARGETS=(
    ("TG_API","https://api.telegram.org/"),
    ("TG_WEB","https://web.telegram.org/"),
    ("YT_HOME","https://www.youtube.com/"),
    ("YT_IMAGE","https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg"),
    ("IG_CONTROL","https://www.instagram.com/"),
)
PATHS=(("NAIVE",7991),("MIERU",7992),("MIERU_NATIVE",7994),("DUAL",7990))
DNS_RESOLVERS=("1.1.1.1","8.8.8.8")
# Public Telegram DC IPv4 test endpoints, not private user/chat addresses.
# SOCKS CONNECT proves TCP reachability only, NOT MTProto authentication.
TG_DC_IPS=("149.154.167.50","149.154.167.91")
STAGES={7:"connection",28:"timeout",35:"SSL handshake",52:"empty response",
        56:"read error",60:"certificate error",97:"proxy error"}

def run_http(target,port,limit):
    label,url=target
    started=time.monotonic()
    cmd=["curl","-q","-4","-sS","-L","--max-redirs","3",
         "--socks5-hostname",f"127.0.0.1:{port}",
         "--connect-timeout","4","--max-time",str(limit),
         "--output","/dev/null","--write-out","%{http_code}|%{size_download}|%{time_total}",
         url]
    try:
        env={k:v for k,v in os.environ.items()
             if k.lower() not in ("http_proxy","https_proxy","all_proxy","no_proxy")}
        result=subprocess.run(cmd,capture_output=True,text=True,
                              timeout=limit+3,env=env)
        values=result.stdout.strip().split("|")
        code=int(values[0]) if len(values)==3 and values[0].isdigit() else 0
        size=int(float(values[1])) if len(values)==3 else 0
        delay=round(float(values[2])*1000) if len(values)==3 else round((time.monotonic()-started)*1000)
        if result.returncode:
            status="ERR_"+str(result.returncode)
            cause=STAGES.get(result.returncode,"request failed")
        elif 200<=code<400:
            status="HTTP_"+str(code)
            cause="HTTP response"
        else:
            status="HTTP_"+str(code)
            cause="HTTP denial/response, not necessarily blocked"
        return {"name":label,"port":port,"status":status,"code":code,"bytes":size,
                "ms":delay,"cause":cause}
    except (ValueError,OSError,subprocess.TimeoutExpired):
        return {"name":label,"port":port,"status":"ERR_TIMEOUT","code":0,
                "bytes":0,"ms":round((time.monotonic()-started)*1000),
                "cause":"timeout"}
def telegram_dc_connect(mod,port,dest,timeout):
    control=None
    start=time.monotonic()
    try:
        control,_,_=mod.socks_control(port,1,dest,443,timeout)
        return {"proxy":port,"dc":dest,"ok":True,
                "ms":round((time.monotonic()-start)*1000),"error":""}
    except (OSError,RuntimeError,socket.timeout) as exc:
        return {"proxy":port,"dc":dest,"ok":False,
                "ms":round((time.monotonic()-start)*1000),
                "error":str(exc)[:60]}
    finally:
        if control is not None:control.close()

def load_diag():
    file=pathlib.Path(__file__).with_name("nm-mieru-udp-diagnose.py")
    if not file.is_file():raise RuntimeError("companion UDP diagnostics missing")
    spec=importlib.util.spec_from_file_location("nm_mieru_app_udp",file)
    mod=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def build_dns_query(pad_to):
    """RFC 6891 EDNS OPT, optional RFC 7830 padding to 1200 bytes."""
    qid=random.randrange(65536)
    question=b"\x07example\x03com\x00"+struct.pack("!HH",1,1)
    header=struct.pack("!HHHHHH",qid,0x0100,1,0,0,1)
    # OPT pseudo-RR: NAME=0, type=41, UDP payload size 1232, TTL flags=0
    rr_header=b"\0"+struct.pack("!HHI",41,1232,0)
    base=header+question+rr_header
    if pad_to==0:
        opt=struct.pack("!H",0)
        data=base+opt
    else:
        remaining=pad_to-len(base)-2-4
        if remaining<0:raise ValueError("requested padding smaller than basic DNS packet")
        option=struct.pack("!HH",12,remaining)+bytes(remaining)
        data=base+struct.pack("!H",len(option))+option
        if len(data)!=pad_to:raise ValueError("bad EDNS padded packet size")
    return qid,data

def udp_dns_sample(mod,port,ip,pad_to,timeout):
    start=time.monotonic()
    control=None
    try:
        control,relay,relay_port=mod.socks_control(port,3,"0.0.0.0",0,timeout)
        if relay in ("0.0.0.0","::"):relay="127.0.0.1"
        qid,query=build_dns_query(pad_to)
        request=b"\0\0\0\1"+socket.inet_aton(ip)+struct.pack("!H",53)+query
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(request,(relay,relay_port))
            response,_=sock.recvfrom(65535)
        mod.dns_check_reply(mod.parse_udp_packet(response),qid)
        return {"port":port,"resolver":ip,"size":len(query),"ok":True,
                "ms":round((time.monotonic()-start)*1000),"error":""}
    except (OSError,RuntimeError,ValueError,socket.timeout) as ex:
        msg="timeout" if isinstance(ex,TimeoutError) else str(ex)
        return {"port":port,"resolver":ip,"size":pad_to or 40,"ok":False,
                "ms":round((time.monotonic()-start)*1000),
                "error":str(msg)[:52]}
    finally:
        if control is not None:control.close()

def run_test(rounds,timeout):
    print("=== TELEGRAM / YOUTUBE / INSTAGRAM PATH DIAGNOSTICS ===",flush=True)
    print("READ-ONLY: tests proxy SOCKS ports; NO client config, service or pool changes.",flush=True)
    print("HTTPS response is NOT evidence Telegram MTProto or YouTube video streaming works.",flush=True)
    jobs=[(p,t) for _,p in PATHS for t in TARGETS for _ in range(rounds)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        http_results=list(executor.map(lambda x:run_http(x[1],x[0],timeout),jobs))
    print("\n=== HTTPS APPLICATION ENDPOINTS ===")
    for label,port in PATHS:
        print(f"\n{label} :{port}")
        for name,_ in TARGETS:
            hits=[r for r in http_results if r["port"]==port and r["name"]==name]
            summary=" ".join(f"{r['status']}:{r['ms']}ms:{r['bytes']}B" for r in hits)
            print(" ",f"{name:<12}",summary,flush=True)
    print("\n=== TELEGRAM MTProto TCP443 REACHABILITY ===",flush=True)
    print("This only tests SOCKS TCP CONNECT to sample Telegram DCs, not app login/messages.")
    mod=load_diag()
    dc_jobs=[(port,dest) for _,port in PATHS for dest in TG_DC_IPS for _ in range(rounds)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        dc_results=list(executor.map(lambda x:telegram_dc_connect(mod,x[0],x[1],timeout),
                                     dc_jobs))
    for name,port in PATHS:
        print(f" {name} :{port}",flush=True)
        for dc in TG_DC_IPS:
            hit=[x for x in dc_results if x["proxy"]==port and x["dc"]==dc]
            count=sum(x["ok"] for x in hit)
            print(f"  {dc} :443 {count}/{len(hit)} "+
                  " ".join("PASS" if x["ok"] else "FAIL:"+x["error"] for x in hit),flush=True)
    print("\n=== UDP SMALL vs LARGE DNS PACKET PROBES ===")
    print("1200B is a synthetic padded DNS request, NOT a real QUIC/Telegram handshake.")
    udp_jobs=[(p,ip,pad) for _,p in PATHS for ip in DNS_RESOLVERS
              for pad in (0,1200) for _ in range(rounds)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        results=list(executor.map(lambda x:udp_dns_sample(mod,x[0],x[1],x[2],timeout),
                                  udp_jobs))
    for label,port in PATHS:
        print(f"\n{label} :{port}",flush=True)
        for pad in (0,1200):
            for ip in DNS_RESOLVERS:
                hit=[r for r in results if r["port"]==port and r["resolver"]==ip and
                     (r["size"]==1200)==(pad==1200)]
                ok=sum(r["ok"] for r in hit)
                extra=" ".join("PASS" if r["ok"] else "FAIL:"+r["error"] for r in hit)
                print(f"  {'PAD1200' if pad else 'SMALL':<8} {ip} {ok}/{len(hit)} {extra}",flush=True)
    print("\nDONE: no user traffic or routing modified.")
    print("If HTTPS works on each path but real apps fail, inspect actual client")
    print("sessions, client-side DNS/IPv6, QUIC/MTProto and large media transfers.")
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--rounds",type=int,default=2)
    p.add_argument("--timeout",type=int,default=9)
    args=p.parse_args()
    if not 1<=args.rounds<=3 or not 5<=args.timeout<=15:
        p.error("rounds 1..3 and timeout 5..15")
    if os.geteuid()!=0:p.error("root required")
    run_test(args.rounds,args.timeout)
if __name__=="__main__":
    try:main()
    except (ValueError,RuntimeError,OSError) as e:
        print("DIAGNOSTIC ABORT:",type(e).__name__,str(e)[:130],file=sys.stderr)
        sys.exit(1)
