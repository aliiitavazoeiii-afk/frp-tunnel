#!/usr/bin/env python3
import json, os, shlex, subprocess, time
from pathlib import Path
from urllib.parse import urlencode, quote
from urllib.request import Request, urlopen

P="anytls-tunnel"
C=Path(f"/etc/{P}")
D=C/"deploy.env"
E=C/"bucket5.env"
STATE=Path(f"/var/lib/{P}/bucket5-state.json")
PROBE="/usr/local/sbin/anytls-bucket5-probe"
NODES=[f"F{i}" for i in range(1,6)]
BUCKETS=[f"BUCKET-{i:02d}" for i in range(1,11)]
FAIL_THRESHOLD=2
RECOVER_QUICK_THRESHOLD=2
MOVE_COOLDOWN=600
MIN_SWAP_DIFF_BPS=500_000
MIN_SWAP_RATIO=1.8

def log(s):
    print(time.strftime("[%Y-%m-%d %H:%M:%S] ")+s, flush=True)

def load_env(path):
    d={}
    for raw in Path(path).read_text().splitlines():
        line=raw.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k,v=line.split("=",1)
        try:
            parts=shlex.split(v,posix=True); d[k]=parts[0] if parts else ""
        except Exception:
            d[k]=v.strip("'\"")
    return d

def default_state(profile):
    mapping={}
    for i,b in enumerate(BUCKETS): mapping[b]=NODES[i//2]
    return {
        "version":1,"profile":profile,"mapping":mapping,
        "health":{n:True for n in NODES},
        "fail_count":{n:0 for n in NODES},
        "recover_count":{n:0 for n in NODES},
        "last_move":0,"last_sample":0,"prev_conn":{},
        "last_bucket_bps":{b:0 for b in BUCKETS},
        "last_bucket_active":{b:0 for b in BUCKETS}
    }

def read_state(profile):
    if STATE.exists():
        try:
            s=json.loads(STATE.read_text())
            if s.get("profile")==profile and all(b in s.get("mapping",{}) for b in BUCKETS): return s
        except Exception: pass
    return default_state(profile)

def save_state(s):
    STATE.parent.mkdir(parents=True,exist_ok=True)
    tmp=STATE.with_suffix(".new")
    tmp.write_text(json.dumps(s,indent=2,sort_keys=True))
    os.chmod(tmp,0o600); os.replace(tmp,STATE)

class API:
    def __init__(self,port,secret):
        self.base=f"http://127.0.0.1:{port}"
        self.headers={"Authorization":f"Bearer {secret}"}
    def req(self,path,method="GET",data=None,timeout=12):
        body=None; headers=dict(self.headers)
        if data is not None:
            body=json.dumps(data).encode(); headers["Content-Type"]="application/json"
        r=Request(self.base+path,data=body,headers=headers,method=method)
        with urlopen(r,timeout=timeout) as resp:
            raw=resp.read(); return json.loads(raw) if raw else None
    def get(self,path,timeout=12): return self.req(path,timeout=timeout)
    def put(self,path,data): return self.req(path,"PUT",data)
    def delete(self,path): return self.req(path,"DELETE")
    def select(self,group,node): self.put(f"/proxies/{quote(group,safe='')}",{"name":node})
    def delay(self,node,url,expected):
        qs=urlencode({"url":url,"timeout":"8000","expected":expected})
        try:
            obj=self.get(f"/proxies/{quote(node,safe='')}/delay?{qs}",timeout=10)
            return isinstance(obj,dict) and isinstance(obj.get("delay"),(int,float))
        except Exception: return False

def quick_health(api,node):
    tests=[
        ("https://www.gstatic.com/generate_204","204"),
        ("https://www.youtube.com/","200-499"),
        ("https://www.instagram.com/","200-499"),
    ]
    return all(api.delay(node,u,e) for u,e in tests)

def full_probe(node):
    try:
        p=subprocess.run([PROBE,node],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
        if p.returncode==0:
            log(f"{node} full recovery probe = OK"); return True
        log(f"{node} full recovery probe = FAIL: {p.stdout[-500:].strip()}")
    except Exception as e: log(f"{node} full recovery probe exception: {e}")
    return False

def bucket_from_conn(c):
    for x in c.get("chains") or []:
        if x in BUCKETS: return x
    name=str((c.get("metadata") or {}).get("inboundName") or "")
    if name.startswith("bucket-") and name.endswith("-carrier"):
        mid=name[len("bucket-"):-len("-carrier")]
        try:
            b=f"BUCKET-{int(mid):02d}"
            if b in BUCKETS: return b
        except Exception: pass
    return None

def sample_connections(api,s,now):
    obj=api.get("/connections") or {}; conns=obj.get("connections") or []
    prev=s.get("prev_conn") or {}; last=float(s.get("last_sample") or 0)
    dt=max(1.0,now-last) if last else 0
    cur={}; bucket_bytes={b:0 for b in BUCKETS}; active={b:0 for b in BUCKETS}
    for c in conns:
        cid=str(c.get("id",""))
        if not cid: continue
        total=int(c.get("upload") or 0)+int(c.get("download") or 0); cur[cid]=total
        b=bucket_from_conn(c)
        if not b: continue
        active[b]+=1
        if cid in prev and total>=int(prev[cid]): bucket_bytes[b]+=total-int(prev[cid])
    bps={b:(bucket_bytes[b]/dt if dt else 0.0) for b in BUCKETS}
    s["prev_conn"]=cur; s["last_sample"]=now; s["last_bucket_bps"]=bps; s["last_bucket_active"]=active
    return conns,bps,active,dt>0

def drain_bucket(api,conns,bucket):
    ids=[str(c["id"]) for c in conns if c.get("id") and bucket_from_conn(c)==bucket]
    closed=0
    for cid in ids:
        try: api.delete(f"/connections/{quote(cid,safe='')}"); closed+=1
        except Exception: pass
    log(f"{bucket}: drained {closed} existing connections for controlled migration")

def node_counts(mapping):
    d={n:0 for n in NODES}
    for n in mapping.values():
        if n in d: d[n]+=1
    return d

def node_loads(mapping,bps,active):
    out={n:{"bps":0.0,"active":0} for n in NODES}
    for b,n in mapping.items():
        if n in out:
            out[n]["bps"]+=float(bps.get(b,0)); out[n]["active"]+=int(active.get(b,0))
    return out

def choose_target(healthy,counts,loads,profile):
    order=NODES if profile=="maya1" else ["F3","F4","F5","F1","F2"]
    rank={n:i for i,n in enumerate(order)}
    return min(healthy,key=lambda n:(counts[n],loads[n]["bps"],loads[n]["active"],rank[n]))

def change_bucket(api,s,conns,bucket,target,reason):
    old=s["mapping"].get(bucket)
    if old==target: return False
    api.select(bucket,target); s["mapping"][bucket]=target
    log(f"{bucket}: {old} -> {target} ({reason})"); drain_bucket(api,conns,bucket)
    return True

def normalize_legacy(api,healthy,loads,profile):
    if not healthy: target="REJECT"
    else:
        order=NODES if profile=="maya1" else ["F3","F4","F5","F1","F2"]
        rank={n:i for i,n in enumerate(order)}
        target=min(healthy,key=lambda n:(loads[n]["bps"],loads[n]["active"],rank[n]))
    try: api.select("LEGACY",target)
    except Exception as e: log(f"WARNING: LEGACY select failed: {e}")

def main():
    if os.geteuid()!=0: raise SystemExit("run as root")
    if not D.exists() or not E.exists(): raise SystemExit("missing deploy.env or bucket5.env")
    d=load_env(D); e=load_env(E); profile=e.get("PROFILE")
    if profile not in ("maya1","maya3"): raise SystemExit("invalid PROFILE")
    api=API(d["LOCAL_CONTROLLER_PORT"],d["CONTROLLER_SECRET"])
    s=read_state(profile); now=int(time.time())
    conns,bps,active,have_delta=sample_connections(api,s,now)

    for n in NODES:
        ok=quick_health(api,n)
        if s["health"].get(n,True):
            if ok: s["fail_count"][n]=0
            else:
                s["fail_count"][n]=int(s["fail_count"].get(n,0))+1
                log(f"{n} quick health failed ({s['fail_count'][n]}/{FAIL_THRESHOLD})")
                if s["fail_count"][n]>=FAIL_THRESHOLD:
                    s["health"][n]=False; s["recover_count"][n]=0; log(f"{n} marked UNHEALTHY")
        else:
            if ok:
                s["recover_count"][n]=int(s["recover_count"].get(n,0))+1
                log(f"{n} recovery quick pass ({s['recover_count'][n]}/{RECOVER_QUICK_THRESHOLD})")
                if s["recover_count"][n]>=RECOVER_QUICK_THRESHOLD and full_probe(n):
                    s["health"][n]=True; s["fail_count"][n]=0; s["recover_count"][n]=0
                    log(f"{n} restored HEALTHY after full isolated probe")
            else: s["recover_count"][n]=0

    healthy=[n for n in NODES if s["health"].get(n)]
    mapping=s["mapping"]; counts=node_counts(mapping); loads=node_loads(mapping,bps,active)
    normalize_legacy(api,healthy,loads,profile)

    if not healthy:
        for b in BUCKETS: change_bucket(api,s,conns,b,"REJECT","no healthy Foreign node")
        save_state(s); log("FAIL-CLOSED: no Foreign node healthy"); return

    failed_buckets=[b for b,n in list(mapping.items()) if n not in healthy]
    for b in failed_buckets:
        counts=node_counts(mapping); loads=node_loads(mapping,bps,active)
        target=choose_target(healthy,counts,loads,profile)
        change_bucket(api,s,conns,b,target,"health failover")

    counts=node_counts(mapping); loads=node_loads(mapping,bps,active)
    can_move=(now-int(s.get("last_move") or 0) >= MOVE_COOLDOWN)
    if len(healthy)==5 and can_move:
        over=[n for n in NODES if counts[n]>2]; under=[n for n in NODES if counts[n]<2]
        if over and under:
            src=max(over,key=lambda n:counts[n])
            dst=min(under,key=lambda n:(counts[n],loads[n]["bps"],loads[n]["active"]))
            candidates=[b for b,n in mapping.items() if n==src]
            b=min(candidates,key=lambda x:(bps.get(x,0),active.get(x,0)))
            if change_bucket(api,s,conns,b,dst,"return to 2-buckets-per-node"):
                s["last_move"]=now; save_state(s); return

    counts=node_counts(mapping); loads=node_loads(mapping,bps,active)
    can_move=(now-int(s.get("last_move") or 0) >= MOVE_COOLDOWN)
    if len(healthy)==5 and have_delta and can_move and all(counts[n]==2 for n in NODES):
        high=max(NODES,key=lambda n:loads[n]["bps"]); low=min(NODES,key=lambda n:loads[n]["bps"])
        hi=loads[high]["bps"]; lo=loads[low]["bps"]; ratio=(hi/max(lo,1.0)); diff=hi-lo
        if diff>=MIN_SWAP_DIFF_BPS and ratio>=MIN_SWAP_RATIO:
            hb=max((b for b,n in mapping.items() if n==high),key=lambda b:bps.get(b,0))
            lb=min((b for b,n in mapping.items() if n==low),key=lambda b:bps.get(b,0))
            hbv=bps.get(hb,0.0); lbv=bps.get(lb,0.0)
            new_hi=hi-hbv+lbv; new_lo=lo-lbv+hbv
            if abs(new_hi-new_lo) <= diff*0.75:
                api.select(hb,low); api.select(lb,high); mapping[hb]=low; mapping[lb]=high
                log(f"LOAD SWAP: {hb} {high}->{low}, {lb} {low}->{high}")
                drain_bucket(api,conns,hb); drain_bucket(api,conns,lb); s["last_move"]=now

    for b,target in mapping.items():
        try:
            obj=api.get(f"/proxies/{quote(b,safe='')}")
            if (obj or {}).get("now")!=target: api.select(b,target)
        except Exception as ex: log(f"WARNING: could not enforce {b}->{target}: {ex}")

    save_state(s); counts=node_counts(mapping); loads=node_loads(mapping,bps,active)
    summary=" ".join(f"{n}:{counts[n]}b/{loads[n]['bps']/125000:.1f}Mbps/{loads[n]['active']}c/{'UP' if s['health'][n] else 'DOWN'}" for n in NODES)
    log("STATE "+summary)

if __name__=="__main__": main()
