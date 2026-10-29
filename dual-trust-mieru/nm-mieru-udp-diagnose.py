#!/usr/bin/env python3
"""Read-only UDP/XUDP layer diagnostic on production Iran OR Mieru foreign.

No service restarts, routing/config writes, inbound listeners or secrets.
Iran: probe SOCKS5 UDP ASSOCIATE on :7991/:7992/:7994/:7990,
      and reach Mieru foreign loopback Xray :2443 via Mieru SOCKS :7994.
Foreign: direct outbound DNS to 3 resolvers and local TCP :2443.
"""
import argparse, collections, concurrent.futures, os, random, socket, struct, subprocess, sys, time

RESOLVERS=("1.1.1.1","8.8.8.8","9.9.9.9")
PORTS=(7991,7992,7994,7990)
LABELS={7991:"NAIVE_XUDP",7992:"MIERU_XUDP",7994:"MIERU_DIRECT_SOCKS_UDP",7990:"DUAL_SELECTED"}
QNAME=b"\x07example\x03com\x00"
UDP_PORT=53
def exact(sock, n):
    buf=b""
    while len(buf)<n:
        data=sock.recv(n-len(buf))
        if not data: raise RuntimeError("SOCKS control closed")
        buf+=data
    return buf
def socks_control(port,command,host,remote_port,timeout):
    s=socket.create_connection(("127.0.0.1",port),timeout)
    s.settimeout(timeout)
    try:
        s.sendall(b"\x05\x01\x00")
        if exact(s,2)!=b"\x05\x00":raise RuntimeError("SOCKS auth rejected")
        s.sendall(b"\x05"+bytes((command,0,1))+socket.inet_aton(host)+struct.pack("!H",remote_port))
        header=exact(s,4)
        if header[0]!=5:raise RuntimeError("invalid SOCKS version")
        if header[1]:
            raise RuntimeError(f"SOCKS reply={header[1]}")
        if header[3]==1:
            addr=socket.inet_ntoa(exact(s,4))
        elif header[3]==3:
            count=exact(s,1)[0]
            addr=exact(s,count).decode("ascii")
        elif header[3]==4:
            addr=socket.inet_ntop(socket.AF_INET6,exact(s,16))
        else:raise RuntimeError("invalid SOCKS address type")
        bindport=struct.unpack("!H",exact(s,2))[0]
        return s,addr,bindport
    except BaseException:
        s.close()
        raise
def dns_question():
    qid=random.randrange(65536)
    packet=struct.pack("!HHHHHH",qid,0x0100,1,0,0,0)+QNAME+struct.pack("!HH",1,1)
    return qid,packet
def dns_check_reply(data,qid):
    if len(data)<12:raise RuntimeError("short DNS response")
    rid,flags,qdcount,ancount,_,_=struct.unpack("!HHHHHH",data[:12])
    if rid!=qid:raise RuntimeError("DNS transaction mismatch")
    if not flags&0x8000:raise RuntimeError("not a DNS response")
    rcode=flags&15
    if rcode:raise RuntimeError(f"DNS RCODE={rcode}")
    if qdcount!=1 or not ancount:raise RuntimeError("DNS response has no A answers")
    return True
def parse_udp_packet(raw):
    if len(raw)<10 or raw[0:2]!=b"\x00\x00":
        raise RuntimeError("invalid SOCKS UDP envelope")
    if raw[2]!=0:
        raise RuntimeError("fragmented UDP reply")
    atyp=raw[3]
    if atyp==1:
        start=10
    elif atyp==3:
        if len(raw)<5:raise RuntimeError("short UDP domain envelope")
        start=7+raw[4]
    elif atyp==4:
        start=22
    else:raise RuntimeError("invalid UDP response type")
    if len(raw)<start+12:raise RuntimeError("short UDP/DNS response")
    return raw[start:]
def attempt_socks_udp(port,resolver,timeout):
    start=time.monotonic()
    control=None
    try:
        control,bind,udpport=socks_control(port,3,"0.0.0.0",0,timeout)
        if not udpport:raise RuntimeError("UDP associate returned port 0")
        if bind in ("0.0.0.0","::"):bind="127.0.0.1"
        qid,dns=dns_question()
        envelope=b"\x00\x00\x00\x01"+socket.inet_aton(resolver)+struct.pack("!H",UDP_PORT)+dns
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as u:
            u.settimeout(timeout)
            u.sendto(envelope,(bind,udpport))
            data,_=u.recvfrom(65535)
        dns_check_reply(parse_udp_packet(data),qid)
        return {"port":port,"resolver":resolver,"ok":True,
                "ms":round((time.monotonic()-start)*1000),"stage":"RESPONSE"}
    except (OSError,ValueError,RuntimeError,socket.timeout) as exc:
        msg=str(exc)
        if isinstance(exc,(socket.timeout,TimeoutError)):msg="timeout"
        return {"port":port,"resolver":resolver,"ok":False,
                "ms":round((time.monotonic()-start)*1000),"stage":msg[:75]}
    finally:
        if control is not None:control.close()
def attempt_direct_udp(resolver,timeout):
    start=time.monotonic()
    try:
        qid,packet=dns_question()
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
            s.settimeout(timeout)
            s.sendto(packet,(resolver,UDP_PORT))
            data,_=s.recvfrom(65535)
        dns_check_reply(data,qid)
        return {"resolver":resolver,"ok":True,"ms":round((time.monotonic()-start)*1000),
                "stage":"RESPONSE"}
    except (OSError,ValueError,RuntimeError,socket.timeout) as exc:
        msg=str(exc)
        if isinstance(exc,(socket.timeout,TimeoutError)):msg="timeout"
        return {"resolver":resolver,"ok":False,"ms":round((time.monotonic()-start)*1000),
                "stage":msg[:75]}
def loopback_through_mieru(timeout):
    control=None
    try:
        control,_,_=socks_control(7994,1,"127.0.0.1",2443,timeout)
        return "PASS: Mieru carrier can TCP CONNECT to foreign 127.0.0.1:2443"
    except (OSError,ValueError,RuntimeError,socket.timeout) as exc:
        return f"FAIL: Mieru carrier cannot connect to foreign Xray loopback: {str(exc)[:90]}"
    finally:
        if control is not None:control.close()
def command_status(unit):
    try:
        cp=subprocess.run(["systemctl","is-active","--quiet",unit],timeout=3,
                          stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        return "active" if cp.returncode==0 else "inactive/unknown"
    except (OSError,subprocess.TimeoutExpired):
        return "unknown"
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--mode",choices=("iran","foreign"),default="iran")
    p.add_argument("--rounds",type=int,default=2)
    p.add_argument("--timeout",type=float,default=5.0)
    a=p.parse_args()
    if not 1<=a.rounds<=3 or not 2<=a.timeout<=8:
        p.error("rounds 1..3, timeout 2..8 seconds")
    print("=== MIERU UDP/XUDP READ-ONLY LAYER DIAGNOSTIC ===",flush=True)
    print("No changes: no reloads, restarts, route selection, or config writes.",flush=True)
    print("Every DNS query: example.com A, independent resolvers 1.1.1.1/8.8.8.8/9.9.9.9.",flush=True)
    if a.mode=="iran":
        print("service states:",
              "xray-bridge="+command_status("dual-xudp-bridge.service"),
              "carrier="+command_status("dual-mieru-carrier.service"))
        print("Foreign Xray tunnel prerequisite:",loopback_through_mieru(a.timeout),flush=True)
        tasks=[(port,r) for port in PORTS for r in RESOLVERS for _ in range(a.rounds)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(lambda x:attempt_socks_udp(x[0],x[1],a.timeout),tasks))
        for port in PORTS:
            rows=[r for r in results if r["port"]==port]
            print("\n",LABELS[port],f":{port} success={sum(r['ok'] for r in rows)}/{len(rows)}",flush=True)
            for ip in RESOLVERS:
                hits=[r for r in rows if r["resolver"]==ip]
                print(" ",ip," ".join(("PASS "+str(r["ms"])+"ms") if r["ok"]
                                     else ("FAIL "+str(r["stage"])) for r in hits),flush=True)
        print("\nInterpretation: :7994 UDP is an OPTIONAL diagnostic; failure here")
        print("does NOT establish XUDP failure because Mieru SOCKS UDP and VLESS-XUDP over TCP are distinct.")
    else:
        print("services:", "mita="+command_status("mita.service"),
              "xray="+command_status("dual-xudp-mieru.service"),flush=True)
        try:
            with socket.create_connection(("127.0.0.1",2443),a.timeout):
                print("FOREIGN Xray loopback :2443 TCP: LISTENING",flush=True)
        except OSError as exc:
            print("FOREIGN Xray loopback :2443 TCP: FAILED",str(exc)[:80],flush=True)
        tasks=[r for r in RESOLVERS for _ in range(a.rounds)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            rows=list(pool.map(lambda r:attempt_direct_udp(r,a.timeout),tasks))
        for ip in RESOLVERS:
            hits=[r for r in rows if r["resolver"]==ip]
            print(ip," ".join(("PASS "+str(r["ms"])+"ms") if r["ok"]
                             else ("FAIL "+str(r["stage"])) for r in hits),flush=True)
        print("Foreign UDP egress checks do not prove VLESS-XUDP server transport correctness.")
    print("\nDONE: read-only measurements. Never paste foreign bundle or passwords.",flush=True)
if __name__=="__main__":
    main()
