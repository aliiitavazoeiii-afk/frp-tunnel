#!/usr/bin/env python3
"""Read-only current & newly observed connections for Naive/Mieru pool."""
import argparse
import json
import pathlib
import time
import urllib.request
from collections import Counter

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--seconds",type=int,default=30)
    args=p.parse_args()
    if args.seconds < 0 or args.seconds > 120: raise SystemExit("seconds must be 0..120")
    secret=pathlib.Path("/etc/dual-trust-mieru/iran/controller.secret").read_text().strip()
    def snapshot():
        req=urllib.request.Request("http://127.0.0.1:19090/connections",
                                   headers={"Authorization":"Bearer "+secret})
        with urllib.request.urlopen(req,timeout=8) as res:
            blob=json.load(res)
        connections=blob.get("connections")
        if not isinstance(connections,list):raise RuntimeError("controller response missing connections")
        result={}
        for c in connections:
            chain=c.get("chains") or []
            if "XUDP-TRUST" in chain or "XUDP-NAIVE" in chain: role="NAIVE"
            elif "XUDP-MIERU" in chain:role="MIERU"
            else:role="OTHER"
            if c.get("id"):result[c["id"]]=role
        return result
    first=snapshot()
    count=Counter(first.values())
    print("=== ACTIVE AT START ===")
    print("TOTAL:",len(first),"NAIVE:",count["NAIVE"],"MIERU:",count["MIERU"],"OTHER:",count["OTHER"])
    if args.seconds == 0:return
    print(f"=== OBSERVING NEWLY SEEN CONNECTIONS FOR {args.seconds}s ===",flush=True)
    seen=set(first);new=Counter()
    start=time.monotonic()
    while time.monotonic()-start < args.seconds:
        time.sleep(min(5,max(0.1,args.seconds-(time.monotonic()-start))))
        now=snapshot()
        for cid,role in now.items():
            if cid not in seen:
                seen.add(cid)
                new[role]+=1
    n=new["NAIVE"]+new["MIERU"]
    print("NAIVE NEW:",new["NAIVE"],"MIERU NEW:",new["MIERU"],"OTHER:",new["OTHER"])
    if n: print(f"OBSERVED NEW SHARE: Naive {100*new['NAIVE']/n:.1f}% / Mieru {100*new['MIERU']/n:.1f}%")
    print("NOTE: sampling omits connections that open and close between samples.")
if __name__=="__main__":
    try:main()
    except Exception as e:raise SystemExit("STATS ERROR: "+str(e))
