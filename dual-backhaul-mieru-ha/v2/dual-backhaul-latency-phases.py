#!/usr/bin/env python3
"""Read-only SOCKS5 latency phase audit for Maya3 and foreign Backhaul VPS.
Shows the cost of SOCKS negotiation, SOCKS CONNECT, TLS and HTTP first byte.
No systemd, HAProxy, tunnel or anti-DPI changes. No credentials read.
"""
import argparse
import math
import socket
import ssl
import statistics
import struct
import sys
import time

def recv_exact(s,n):
    data=bytearray()
    while len(data)<n:
        chunk=s.recv(n-len(data))
        if not chunk:
            raise EOFError("SOCKS reply ended early")
        data+=chunk
    return bytes(data)

def connect_reply(s):
    header=recv_exact(s,4)
    if header[0]!=5 or header[1]!=0 or header[2]!=0:
        raise ValueError("SOCKS5 CONNECT failed, code="+str(header[1]))
    atyp=header[3]
    if atyp==1: recv_exact(s,4)
    elif atyp==4: recv_exact(s,16)
    elif atyp==3: recv_exact(s,recv_exact(s,1)[0])
    else: raise ValueError("Invalid SOCKS address type")
    recv_exact(s,2)

def one(port,host,path,context):
    timestamps={}
    t0=time.monotonic()
    s=socket.create_connection(("127.0.0.1",port), timeout=12)
    s.settimeout(12)
    timestamps["local_connected"]=time.monotonic()
    try:
        s.sendall(b"\x05\x01\x00")
        if recv_exact(s,2)!=b"\x05\x00":
            raise ValueError("SOCKS5 greeting not accepted")
        timestamps["greeting_done"]=time.monotonic()
        name=host.encode("ascii")
        if len(name)>255: raise ValueError("Hostname too long")
        s.sendall(b"\x05\x01\x00\x03"+bytes([len(name)])+name+struct.pack("!H",443))
        connect_reply(s)
        timestamps["socks_connected"]=time.monotonic()
        tls=context.wrap_socket(s,server_hostname=host)
        timestamps["tls_done"]=time.monotonic()
        try:
            request=(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: curl/8.5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n").encode()
            tls.sendall(request)
            block=tls.recv(4096)
            if not block:
                raise EOFError("HTTP response empty")
            timestamps["first_byte"]=time.monotonic()
        finally:
            tls.close()
    finally:
        s.close()
    def ms(a,b):
        return round(1000*(timestamps[b]-timestamps[a]),2)
    return {
        "local_tcp_ms":ms("local_connected","local_connected") if port else 0,
        "socks_greeting_ms":ms("local_connected","greeting_done"),
        "socks_connect_ms":ms("greeting_done","socks_connected"),
        "tls_ms":ms("socks_connected","tls_done"),
        "http_first_byte_ms":ms("tls_done","first_byte"),
        "total_ms":ms("local_connected","first_byte"),
        "http_prefix":block[:15].decode("ascii",errors="replace").replace("\r","").replace("\n"," ")
    }

def percentile(data,pct):
    if not data: return None
    a=sorted(data)
    k=math.ceil(len(a)*pct/100)-1
    return round(a[max(0,k)],1)

def report(results, failures):
    print("PASSED:",len(results),"FAILED:",len(failures),flush=True)
    for phase in ("socks_greeting_ms","socks_connect_ms","tls_ms","http_first_byte_ms","total_ms"):
        series=[r[phase] for r in results]
        if series:
            print(f"{phase:23s} P50={statistics.median(series):7.1f} ms P95={percentile(series,95):7.1f} ms MAX={max(series):7.1f} ms",flush=True)
    if failures:
        print("ERRORS:",failures[:5],flush=True)
    if results:
        print("HTTP response examples:",sorted(set(r["http_prefix"] for r in results))[:3])
    print("Note: stages are sequential for each sample. These are not ICMP RTTs.")

def main():
    a=argparse.ArgumentParser()
    a.add_argument("--port",type=int,required=True)
    a.add_argument("--samples",type=int,default=15)
    a.add_argument("--host",default="www.instagram.com")
    a.add_argument("--path",default="/robots.txt")
    args=a.parse_args()
    if args.port not in (21001,21002,18080,11080):
        a.error("Only known local SOCKS ports 21001, 21002, 18080, 11080")
    if not (5<=args.samples<=30):
        a.error("samples must be between 5 and 30")
    context=ssl.create_default_context()
    print(f"SOCKS5 LATENCY PHASE AUDIT: 127.0.0.1:{args.port} -> {args.host}{args.path}")
    print("READ-ONLY. No credentials, server restarts or DPI changes.",flush=True)
    results=[]
    failures=[]
    for i in range(args.samples):
        try:
            results.append(one(args.port,args.host,args.path,context))
        except (OSError,ValueError,ssl.SSLError,EOFError) as e:
            failures.append(type(e).__name__+":"+str(e)[:90])
        if (i+1)%5==0:
            print("ROUND:",i+1,"/",args.samples,flush=True)
        if i<args.samples-1: time.sleep(.15)
    report(results,failures)
    return 0 if len(results)>=args.samples*0.7 else 1

if __name__=="__main__":
    sys.exit(main())
