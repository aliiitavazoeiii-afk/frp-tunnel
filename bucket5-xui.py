#!/usr/bin/env python3
import hashlib, json, os, sqlite3, sys
from pathlib import Path

DB=Path("/etc/x-ui/x-ui.db")
RUNTIME=Path("/usr/local/x-ui/bin/config.json")
MAP=Path("/var/lib/anytls-tunnel/bucket5-users.json")
BUCKETS=10
XUDP_BASE=18101
LEGACY_PORT=7891

def fail(msg):
    print("ERROR:",msg,file=sys.stderr); raise SystemExit(2)

def discover_runtime():
    if not RUNTIME.exists(): fail("x-ui runtime config missing")
    cfg=json.loads(RUNTIME.read_text())
    ins=[]
    for i in cfg.get("inbounds",[]):
        try: port=int(i.get("port",0))
        except Exception: continue
        if port==443 and str(i.get("listen","")) not in ("127.0.0.1","::1","localhost"):
            ins.append(i)
    if len(ins)!=1: fail(f"expected exactly one public :443 inbound, found {len(ins)}")
    inbound=ins[0]
    tag=inbound.get("tag")
    if not tag: fail("public inbound has no tag")
    clients=(inbound.get("settings") or {}).get("clients") or []
    emails=[]
    missing=[]
    for c in clients:
        email=str(c.get("email") or "").strip()
        cid=str(c.get("id") or "")
        if not email:
            missing.append(cid[:8] or "?")
        else:
            emails.append(email)
    if missing: fail(f"{len(missing)} active clients have empty email; sample={missing[:5]}")
    if len(set(emails))!=len(emails): fail("duplicate client emails found; user-based routing would be ambiguous")
    if not emails: fail("no active VLESS client emails discovered")
    return cfg,tag,sorted(emails)

def read_mapping(profile,emails):
    old={}
    if MAP.exists():
        try:
            obj=json.loads(MAP.read_text())
            if obj.get("profile")==profile:
                old={k:int(v) for k,v in (obj.get("users") or {}).items() if 1<=int(v)<=BUCKETS}
        except Exception:
            old={}
    mapping=dict(old)
    new=[e for e in emails if e not in mapping]
    if not old:
        ordered=sorted(emails,key=lambda e:hashlib.sha256((profile+"|"+e).encode()).hexdigest())
        mapping={e:(i%BUCKETS)+1 for i,e in enumerate(ordered)}
    else:
        counts={i:0 for i in range(1,BUCKETS+1)}
        for e in emails:
            if e in mapping: counts[mapping[e]]+=1
        for e in sorted(new,key=lambda x:hashlib.sha256((profile+"|"+x).encode()).hexdigest()):
            b=min(counts,key=lambda n:(counts[n],n))
            mapping[e]=b; counts[b]+=1
    MAP.parent.mkdir(parents=True,exist_ok=True)
    tmp=MAP.with_suffix(".new")
    tmp.write_text(json.dumps({"version":1,"profile":profile,"users":mapping},indent=2,sort_keys=True))
    os.chmod(tmp,0o600); os.replace(tmp,MAP)
    return mapping

def db_template():
    con=sqlite3.connect(DB)
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row: con.close(); fail("xrayTemplateConfig missing")
    cfg=json.loads(row[0])
    return con,cfg

def desired_outbound(tag,port):
    return {
      "tag":tag,"protocol":"socks","targetStrategy":"AsIs",
      "settings":{"servers":[{"address":"127.0.0.1","port":port,"users":[]}]},
      "mux":{"enabled":False}
    }

def sync(profile):
    _,inbound_tag,emails=discover_runtime()
    mapping=read_mapping(profile,emails)
    con,cfg=db_template()
    try:
        con.execute("BEGIN IMMEDIATE")
        obs=cfg.setdefault("outbounds",[])
        obs[:]=[o for o in obs if not str(o.get("tag","")).startswith("anytls-bucket-")]
        legacy=[o for o in obs if o.get("tag")=="anytls-tunnel"]
        if len(legacy)>1: fail("multiple anytls-tunnel outbounds")
        if legacy:
            legacy[0].clear(); legacy[0].update(desired_outbound("anytls-tunnel",LEGACY_PORT))
        else:
            obs.append(desired_outbound("anytls-tunnel",LEGACY_PORT))
        for b in range(1,BUCKETS+1):
            obs.append(desired_outbound(f"anytls-bucket-{b:02d}",XUDP_BASE+b-1))

        routing=cfg.setdefault("routing",{})
        rules=routing.setdefault("rules",[])
        def owned(r):
            ot=str(r.get("outboundTag",""))
            return ot=="anytls-tunnel" or ot.startswith("anytls-bucket-")
        rules[:]=[r for r in rules if not owned(r)]
        inserted=[]
        for b in range(1,BUCKETS+1):
            users=sorted(e for e in emails if mapping[e]==b)
            if users:
                inserted.append({
                    "type":"field","inboundTag":[inbound_tag],"user":users,
                    "outboundTag":f"anytls-bucket-{b:02d}"
                })
        inserted.append({"type":"field","inboundTag":[inbound_tag],"outboundTag":"anytls-tunnel"})
        rules[:0]=inserted
        con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",
                    (json.dumps(cfg,separators=(",",":")),))
        con.commit()
    finally:
        con.close()
    counts={b:sum(1 for e in emails if mapping[e]==b) for b in range(1,BUCKETS+1)}
    print(json.dumps({"inbound":inbound_tag,"users":len(emails),"bucket_counts":counts},indent=2))

def audit():
    _,tag,emails=discover_runtime()
    print(json.dumps({"inbound":tag,"users":len(emails),"emails_ok":True},indent=2))

def verify(profile):
    cfg,tag,emails=discover_runtime()
    obs={o.get("tag"):o for o in cfg.get("outbounds",[])}
    for b in range(1,BUCKETS+1):
        t=f"anytls-bucket-{b:02d}"
        if t not in obs: fail(f"runtime missing {t}")
        st=obs[t].get("settings") or {}
        servers=st.get("servers") or []
        if not servers or int(servers[0].get("port") or 0)!=XUDP_BASE+b-1:
            fail(f"{t} wrong runtime port")
        if obs[t].get("targetStrategy")!="AsIs": fail(f"{t} targetStrategy is not AsIs")
    if "anytls-tunnel" not in obs: fail("runtime missing legacy anytls-tunnel")
    rules=cfg.get("routing",{}).get("rules",[])
    covered=set()
    for b in range(1,BUCKETS+1):
        t=f"anytls-bucket-{b:02d}"
        for r in rules:
            if r.get("outboundTag")==t and tag in (r.get("inboundTag") or []):
                covered.update(r.get("user") or [])
    if set(emails)!=covered:
        fail(f"runtime user coverage mismatch: active={len(emails)} covered={len(covered)}")
    fallback=any(r.get("outboundTag")=="anytls-tunnel" and tag in (r.get("inboundTag") or []) for r in rules)
    if not fallback: fail("runtime fallback route missing")
    print(f"RUNTIME OK: {len(emails)} users -> 10 stable buckets; fallback enabled for new users")

if __name__=="__main__":
    if os.geteuid()!=0: fail("run as root")
    if len(sys.argv)<2: fail("usage: bucket5-xui.py audit|sync|verify [maya1|maya3]")
    cmd=sys.argv[1]
    profile=sys.argv[2] if len(sys.argv)>2 else ""
    if cmd=="audit": audit()
    elif cmd in ("sync","verify"):
        if profile not in ("maya1","maya3"): fail("profile must be maya1 or maya3")
        globals()[cmd](profile)
    else: fail("unknown command")
