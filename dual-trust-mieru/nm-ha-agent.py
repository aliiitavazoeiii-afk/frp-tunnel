#!/usr/bin/env python3
"""Conservative Naive/Mieru HA agent; only role-local restart + Mihomo Selector API.
No x-ui, XUDP bridge, or dispatcher service restarts. Fail closed on uncertainty.
"""
import argparse, concurrent.futures, datetime as dt, fcntl, json, os, pathlib, subprocess
import tempfile, time, urllib.error, urllib.request, sys

ROOT=pathlib.Path("/etc/dual-trust-mieru/iran")
STATE=pathlib.Path("/var/lib/dual-trust-mieru/naive-mieru/ha")
CONFIG=ROOT/"dispatcher.yaml"
SECRET=ROOT/"controller.secret"
BASE="http://127.0.0.1:19090"
LOCK="/run/dual-trust-mieru-autoheal.lock"
ROLES=("naive","mieru")
PORT={"naive":(7993,7991),"mieru":(7994,7992)}
SERVICE={"naive":"nm-naive-client.service","mieru":"dual-mieru-carrier.service"}
NODE={"naive":"XUDP-TRUST","mieru":"XUDP-MIERU"}
AUTO="DUAL-AUTO"
SELECTOR="DUAL"
# SHARD_AWARE_HA_V1: NEVER restart the local gateway instead of failed backend.
SHARD_OVERLAY=pathlib.Path("/etc/systemd/system/nm-naive-client.service.d/90-naive-shards.conf")
SHARD_PORTS={"a":17993,"b":17994}
SHARD_UNITS={"a":"nm-naive-shard-a.service","b":"nm-naive-shard-b.service"}
SHARD_RESTART_COOLDOWN=1800  # seconds; avoid repeated interruptions on flapping links.
SHARD_DEGRADED_RECOVERY_CYCLES=5  # persistent partial outage (~several minutes)


def iso():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
def atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd,tmp=tempfile.mkstemp(prefix="."+path.name+".",dir=path.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,"w") as file:
            file.write(content);file.flush();os.fsync(file.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
def api(method,path,data=None):
    token=SECRET.read_text().strip()
    body=None if data is None else json.dumps(data).encode()
    req=urllib.request.Request(BASE+path,data=body,method=method,
        headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"})
    with urllib.request.urlopen(req,timeout=7) as res:
        blob=res.read()
        return json.loads(blob) if blob else {}
def group():
    return api("GET","/proxies/DUAL")
def armed(g):
    return g.get("type")=="Selector" and set(g.get("all",[]))=={AUTO,NODE["naive"],NODE["mieru"]}
def validate_services():
    for svc in ("x-ui.service","dual-dispatcher.service","dual-xudp-bridge.service"):
        if subprocess.run(["systemctl","is-active","--quiet",svc],timeout=5).returncode:
            raise RuntimeError("shared production service inactive: "+svc)
def curl(port,url):
    cmd=["curl","-q","-4","-sS","--socks5-hostname",f"127.0.0.1:{port}",
         "--connect-timeout","3","--max-time","7","-o","/dev/null",
         "-w","%{http_code}|%{time_total}",url]
    try:
        proc=subprocess.run(cmd,capture_output=True,text=True,timeout=9)
        code,delay=proc.stdout.strip().split("|")
        expected={"204"} if "generate_204" in url else {"200","301","302"}
        if proc.returncode==0 and code in expected:
            return {"ok":True,"ms":round(float(delay)*1000),"code":int(code)}
    except (OSError,ValueError,subprocess.TimeoutExpired):
        pass
    return {"ok":False,"ms":None,"code":None}
def sharding_live():
    """Allow shard actions ONLY with the precise reviewed live unit override."""
    if not SHARD_OVERLAY.exists():
        return False
    expected=(
        "ExecStart=/usr/local/lib/dual-trust-mieru/mihomo "
        "-d /var/lib/dual-trust-mieru/naive-shards/live "
        "-f /etc/dual-trust-mieru/naive-shards/live.yaml"
    )
    contents=SHARD_OVERLAY.read_text()
    if contents.count(expected)!=1 or "ExecStart=\n" not in contents:
        raise RuntimeError("Unknown Naive shard gateway override; refuse HA role action")
    # Deliberately DO NOT require each backend systemd unit to be active:
    # a dead unit is exactly what shard-specific HA must detect and repair.
    # probe_shards() checks per-backend data-plane reachability independently.
    return True

def probe_shards():
    """Require BOTH unrelated HTTPS endpoints to fail before marking a shard DOWN."""
    jobs={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for name,port in SHARD_PORTS.items():
            jobs[name,"gstatic"]=pool.submit(curl,port,"https://www.gstatic.com/generate_204")
            jobs[name,"telegram"]=pool.submit(curl,port,"https://api.telegram.org/")
        out={}
        for name in SHARD_PORTS:
            probes={k:jobs[name,k].result() for k in ("gstatic","telegram")}
            good=all(x["ok"] for x in probes.values())
            down=not any(x["ok"] for x in probes.values())
            out[name]={"health":"HEALTHY" if good else "DOWN" if down else "DEGRADED",
                       "probes":probes}
    return out

def shard_defaults():
    return {name:{"failed_cycles":0,"degraded_cycles":0,"healthy_cycles":0,
                  "last_restart_epoch":0,"last_restart_at":None,
                  "incident":0,"status":"UNKNOWN"}
            for name in SHARD_PORTS}

def effective_sharded_health(gateway_health, shards):
    """Avoid declaring the whole Naive role DOWN if a real backend is healthy.

    The production gateway uses RR, so a small number of probes can all pick
    a failing backend by chance. Conversely, if both backends are healthy but
    gateway is fully DOWN, that is a genuine gateway-local outage.
    """
    health=[shards[name]["health"] for name in SHARD_PORTS]
    if any(x=="HEALTHY" for x in health) and not all(x=="HEALTHY" for x in health):
        return "DEGRADED"
    if all(x=="HEALTHY" for x in health):
        return gateway_health
    if gateway_health=="HEALTHY":
        return "DEGRADED"  # cached/partial traffic cannot prove both shards work
    return gateway_health

def probe_all():
    # A failed gstatic alone is not sufficient: also require an independent
    # Telegram failure before classifying a role DOWN.
    tasks={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for role in ROLES:
            direct,split=PORT[role]
            for name,port,url in (
                ("direct",direct,"https://www.gstatic.com/generate_204"),
                ("split",split,"https://www.gstatic.com/generate_204"),
                ("telegram",split,"https://api.telegram.org/")):
                tasks[role,name]=pool.submit(curl,port,url)
        out={}
        for role in ROLES:
            p={name:tasks[role,name].result() for name in ("direct","split","telegram")}
            # Avoid dropping a working carrier due to one blocked probe endpoint.
            is_down=not p["direct"]["ok"] and not p["split"]["ok"] and not p["telegram"]["ok"]
            is_good=p["direct"]["ok"] and p["split"]["ok"]
            out[role]={"health":"DOWN" if is_down else "HEALTHY" if is_good else "DEGRADED",
                       "probes":p}
    return out
def base_state():
    return {"schema":1,"sequence":0,"updated_at":None,"selected":"UNKNOWN",
            "roles":{r:{"failed_cycles":0,"healthy_cycles":0,"restart_attempted":False,
                        "status":"UNKNOWN","last_restart_at":None,"incident":0} for r in ROLES},
            "both_down_alerted":False,"events":[]}
def load():
    p=STATE/"state.json"
    return json.loads(p.read_text()) if p.exists() else base_state()
def save(s):
    atomic(STATE/"state.json",json.dumps(s,indent=2,sort_keys=True)+"\n")
def event(s,kind,role=None,detail=None):
    e={"seq":s["sequence"]+1,"at":iso(),"kind":kind,
       "role":role,"detail":detail or ""}
    s["sequence"]=e["seq"]
    s.setdefault("events",[]).append(e)
    s["events"]=s["events"][-60:]
    with (STATE/"events.jsonl").open("a") as file:
        file.write(json.dumps(e,separators=(",",":"))+"\n")
    os.chmod(STATE/"events.jsonl",0o600)
def status_document(s,measurements,selected,policy,shards=None):
    bundles={"naive":pathlib.Path("/etc/dual-trust-mieru/naive-mieru/bundle.json"),
             "mieru":ROOT/"mieru-bundle.json"}
    ips={}
    for role,p in bundles.items():
        try: ips[role]=json.loads(p.read_text()).get("public_ip")
        except (ValueError,OSError):ips[role]=None
    roles={}
    for role in ROLES:
        prior=s["roles"][role]
        roles[role]={"status":prior["status"],"health":measurements[role]["health"],
                     "foreign_ip":ips[role],"failed_cycles":prior["failed_cycles"],
                     "healthy_cycles":prior["healthy_cycles"],
                     "last_restart_at":prior.get("last_restart_at"),
                     "probes":measurements[role]["probes"],"incident":prior.get("incident",0)}
    # Local-only service state, without exposing process or authentication details.
    services={}
    for service in ("x-ui","dual-dispatcher","dual-xudp-bridge",
                    "nm-naive-client","dual-mieru-carrier"):
        try:
            services[service]=subprocess.run(
                ["systemctl","is-active","--quiet",service+".service"],
                timeout=4).returncode==0
        except (OSError,subprocess.TimeoutExpired):
            services[service]=False
    shard_public={}
    if shards is not None:
        for name,item in shards.items():
            prior=s.get("shards",{}).get(name,{})
            shard_public[name]={"health":item["health"],"probes":item["probes"],
                                "status":prior.get("status","UNKNOWN"),
                                "failed_cycles":prior.get("failed_cycles",0),
                                "degraded_cycles":prior.get("degraded_cycles",0),
                                "last_restart_at":prior.get("last_restart_at"),
                                "incident":prior.get("incident",0)}
    return {"schema":1,"server_id":os.environ.get("NM_HA_SERVER_ID","maya11"),
            "updated_at":iso(),"services":services,
            "policy":policy,"pool_selection":selected,
            "automatic_failover":policy=="ARMED","roles":roles,
            "naive_shards":{"mode":"LIVE" if shards is not None else "SINGLE",
                            "backends":shard_public},
            "last_event_seq":s["sequence"],"recent_events":s.get("events",[])[-60:]}
def select(target,expected_current):
    g=group()
    if not armed(g):
        raise RuntimeError("UNSAFE: DUAL is no longer expected Selector; no routing changes")
    if g.get("now") != expected_current:
        raise RuntimeError("UNSAFE: DUAL selection changed externally; refuse to override")
    if target==expected_current:return expected_current
    api("PUT","/proxies/DUAL",{"name":target})
    after=group()
    if after.get("now")!=target:raise RuntimeError("Selector API did not confirm "+target)
    return target
def live_once(dry_run=False):
    STATE.mkdir(parents=True,exist_ok=True,mode=0o700)
    with open(LOCK,"a+") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        validate_services()
        s=load()
        g=group()
        policy="ARMED" if armed(g) else "UNARMED"
        # Failure to read Controller/credentials fails closed before any restart.
        current=g.get("now","UNKNOWN")
        measurements=probe_all()
        # Shadow-stage has NO effect on HA. Only the live unit override enables
        # per-backend shard health/restarts. Shared lock serializes cutover.
        sharded=sharding_live()
        shards=probe_shards() if sharded else None
        if sharded:
            s.setdefault("shards",shard_defaults())
            # A small RR sample can hit the bad backend repeatedly. Avoid
            # unnecessary full-Naive quarantine while one shard is proven good.
            measurements["naive"]["health"]=effective_sharded_health(
                measurements["naive"]["health"],shards)
        for role in ROLES:
            st=s["roles"][role]
            measured=measurements[role]["health"]
            if measured=="DOWN":
                st["failed_cycles"]=min(100,st["failed_cycles"]+1)
                st["healthy_cycles"]=0
            elif measured=="HEALTHY":
                st["healthy_cycles"]=min(100,st["healthy_cycles"]+1)
                st["failed_cycles"]=0
            else:
                # Partial reachability is not proof of filtering.
                st["failed_cycles"]=0
                st["healthy_cycles"]=0
        if policy=="ARMED" and not dry_run:
            if sharded:
                for name,observation in shards.items():
                    part=s["shards"].setdefault(name,shard_defaults()[name])
                    health=observation["health"]
                    if health=="DOWN":
                        part["failed_cycles"]=min(100,part["failed_cycles"]+1)
                        part["degraded_cycles"]=0
                        part["healthy_cycles"]=0
                    elif health=="HEALTHY":
                        part["healthy_cycles"]=min(100,part["healthy_cycles"]+1)
                        part["failed_cycles"]=0
                        part["degraded_cycles"]=0
                    else:
                        part["failed_cycles"]=0
                        part["degraded_cycles"]=min(100,part.get("degraded_cycles",0)+1)
                        part["healthy_cycles"]=0
                    peer="b" if name=="a" else "a"
                    # A single failed shard can be repaired while the other Naive
                    # shard and independent Mieru are both alive.
                    eligible=((
                                  part["failed_cycles"]>=2
                                  or part.get("degraded_cycles",0)>=SHARD_DEGRADED_RECOVERY_CYCLES
                              )
                              and shards[peer]["health"]=="HEALTHY"
                              and time.time()-part["last_restart_epoch"]>=SHARD_RESTART_COOLDOWN)
                    # Independent Naive backend recovery must not depend on
                    # an unrelated Mieru outage: that creates a cascading failure.
                    if not eligible:
                        continue
                    part["incident"]+=1
                    part["last_restart_epoch"]=time.time()
                    part["last_restart_at"]=iso()
                    event(s,"RESTARTING_NAIVE_SHARD","naive",name)
                    save(s)  # write attempt before restart, enforce cooldown across crashes
                    try:
                        result=subprocess.run(["systemctl","restart",SHARD_UNITS[name]],timeout=15)
                        time.sleep(3)
                        checked=probe_shards()[name]
                        shards[name]=checked
                        if result.returncode==0 and checked["health"]=="HEALTHY":
                            part["failed_cycles"]=0
                            part["degraded_cycles"]=0
                            part["healthy_cycles"]=1
                            event(s,"NAIVE_SHARD_RECOVERED","naive",name)
                        else:
                            event(s,"NAIVE_SHARD_STILL_DOWN","naive",name)
                    except (OSError,subprocess.TimeoutExpired) as exc:
                        event(s,"NAIVE_SHARD_RESTART_ERROR","naive",name+":"+type(exc).__name__)
                # Live backend actions may change Naive gateway probe results.
                measurements["naive"]=probe_all()["naive"]
                measurements["naive"]["health"]=effective_sharded_health(
                    measurements["naive"]["health"],shards)
                if measurements["naive"]["health"]=="HEALTHY":
                    s["roles"]["naive"]["failed_cycles"]=0
                    s["roles"]["naive"]["healthy_cycles"]=max(1,s["roles"]["naive"]["healthy_cycles"])
            for role in ROLES:
                st=s["roles"][role]
                peer="mieru" if role=="naive" else "naive"
                if st["failed_cycles"]<2 or st["restart_attempted"]:
                    continue
                if sharded and role=="naive":
                    # If both independent backend processes are healthy but
                    # the shared gateway fails all three application probes
                    # twice, the gateway itself is the likely bad component.
                    # Restart ONLY it, at most once per 30 minutes.
                    all_backends_healthy=all(shards[x]["health"]=="HEALTHY"
                                            for x in SHARD_PORTS)
                    last=s.get("naive_gateway_last_restart_epoch",0)
                    if (not all_backends_healthy
                        or measurements["mieru"]["health"]!="HEALTHY"
                        or time.time()-last<SHARD_RESTART_COOLDOWN):
                        if st["failed_cycles"]==2:
                            event(s,"NAIVE_GATEWAY_RESTART_SKIPPED",role,
                                  "backend unhealthy, peer unhealthy, or cooldown")
                        continue
                    s["naive_gateway_last_restart_epoch"]=time.time()
                    st["restart_attempted"]=True
                    st["incident"]+=1
                    st["last_restart_at"]=iso()
                    event(s,"RESTARTING_NAIVE_GATEWAY",role,
                          "both backends healthy but gateway fully down twice")
                    save(s)
                    try:
                        proc=subprocess.run(["systemctl","restart",SERVICE[role]],timeout=15)
                        time.sleep(4)
                        check=probe_all()[role]
                        check["health"]=effective_sharded_health(check["health"],shards)
                        measurements[role]=check
                        if proc.returncode==0 and check["health"]=="HEALTHY":
                            st["failed_cycles"]=0
                            st["healthy_cycles"]=1
                            event(s,"NAIVE_GATEWAY_RECOVERED",role)
                        else:
                            event(s,"NAIVE_GATEWAY_STILL_DOWN",role,check["health"])
                    except (OSError,subprocess.TimeoutExpired) as exc:
                        event(s,"NAIVE_GATEWAY_RESTART_ERROR",role,type(exc).__name__)
                    continue
                if measurements[peer]["health"]!="HEALTHY":
                    if st["failed_cycles"]==2:
                        event(s,"PEER_NOT_HEALTHY_NO_RESTART",role,"fail-safe: no blind restart")
                    continue
                st["restart_attempted"]=True
                st["incident"]+=1
                st["last_restart_at"]=iso()
                event(s,"RESTARTING_CARRIER",role,"2 consecutive full-path failures; peer healthy")
                save(s)  # persist attempt BEFORE action, so no restart loop after crash
                try:
                    proc=subprocess.run(["systemctl","restart",SERVICE[role]],timeout=15)
                    time.sleep(4)
                    check=probe_all()[role]
                    measurements[role]=check
                    if proc.returncode==0 and check["health"]=="HEALTHY":
                        st["failed_cycles"]=0;st["healthy_cycles"]=1
                        event(s,"CARRIER_RECOVERED_AFTER_RESTART",role)
                    else:
                        event(s,"CARRIER_STILL_DOWN_AFTER_RESTART",role,check["health"])
                except (OSError,subprocess.TimeoutExpired) as exc:
                    event(s,"CARRIER_RESTART_ERROR",role,type(exc).__name__)
            # Both down: send exactly one incident event, never endlessly spam panel.
            all_down=all(s["roles"][r]["failed_cycles"]>=2 for r in ROLES)
            if all_down and not s.get("both_down_alerted",False):
                event(s,"BOTH_PATHS_UNAVAILABLE",None,"all role probes failed in consecutive sweeps")
                s["both_down_alerted"]=True
            elif not all_down and s.get("both_down_alerted",False):
                event(s,"AT_LEAST_ONE_PATH_RECOVERED")
                s["both_down_alerted"]=False
            # Apply selection after all restart attempts; never switch to a sick peer.
            n=s["roles"]["naive"];m=s["roles"]["mieru"]
            failed=[r for r in ROLES if s["roles"][r]["failed_cycles"]>=2]
            good=[r for r in ROLES if measurements[r]["health"]=="HEALTHY"]
            wanted=current
            if len(failed)==1 and len(good)==1 and failed[0]!=good[0]:
                wanted=NODE[good[0]]
            elif (len(good)==2
                  and all(s["roles"][r]["healthy_cycles"]>=3 for r in ROLES)
                  and (not sharded or all(s["shards"][name]["healthy_cycles"]>=3 for name in SHARD_PORTS))):
                wanted=AUTO
            if wanted!=current:
                current=select(wanted,current)
                event(s,"POOL_SELECTION_CHANGED",None,wanted)
            for role in ROLES:
                st=s["roles"][role]
                if st["healthy_cycles"]>=3 and st["restart_attempted"]:
                    st["restart_attempted"]=False
                    st["failed_cycles"]=0
                    event(s,"ROLE_RECOVERED",role)
        if sharded:
            for name,obs in shards.items():
                part=s["shards"][name]
                current_shard=obs["health"]
                if part["status"]!=current_shard:
                    event(s,"NAIVE_SHARD_STATUS_CHANGE","naive",
                          name+":"+part["status"]+" -> "+current_shard)
                    part["status"]=current_shard
        for role in ROLES:
            st=s["roles"][role]
            if policy!="ARMED":
                state="MONITOR_ONLY"
            elif st["failed_cycles"]>=2 and current!=AUTO and current!=NODE[role]:
                state="QUARANTINED"
            elif measurements[role]["health"]=="DOWN":
                state="SUSPECT"
            elif measurements[role]["health"]=="DEGRADED":
                state="DEGRADED"
            elif st["healthy_cycles"]<3 and st["restart_attempted"]:
                state="RECOVERING"
            else:
                state="HEALTHY"
            if state!=st["status"]:
                event(s,"STATUS_CHANGE",role,st["status"]+" -> "+state)
                st["status"]=state
        s["updated_at"]=iso()
        s["selected"]=current
        save(s)
        public=status_document(s,measurements,current,policy if not dry_run else "DRY_RUN",shards)
        atomic(STATE/"status.json",json.dumps(public,indent=2,sort_keys=True)+"\n")
        print(f"HA {public['updated_at']} {policy} selected={current} "+ 
              " ".join(f"{r}={public['roles'][r]['status']}" for r in ROLES),flush=True)
def bootstrap(allow_live=False):
    # One-time config reload to introduce a stable Selector above the existing RR.
    # Afterwards ONLY PUT /proxies/DUAL; no reload needed for health failover.
    STATE.mkdir(parents=True,exist_ok=True,mode=0o700)
    with open(LOCK,"a+") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        validate_services()
        g=group()
        if armed(g):
            print("ALREADY ARMED; no configuration change")
            return
        if g.get("type")!="LoadBalance" or set(g.get("all",[]))!={NODE["naive"],NODE["mieru"]}:
            raise RuntimeError("Unexpected production DUAL group: refusing bootstrap")
        active=api("GET","/connections").get("connections")
        if not isinstance(active,list):raise RuntimeError("Cannot establish active connection count")
        if active and not allow_live:
            raise RuntimeError(f"{len(active)} active dispatcher flows; refusing first-time reload. "
                "Retry during zero flows or use --allow-active-reload after accepting session interruption.")
        if active and allow_live:
            if not sys.stdin.isatty():
                raise RuntimeError("Active session reload requires an interactive terminal confirmation")
            print(f"WARNING: {len(active)} active connections. One-time dispatcher config reload")
            print("MAY INTERRUPT EXISTING USER SESSIONS, including BOTH Naive and Mieru.")
            answer=input("Type RELOAD-WITH-ACTIVE-USERS to accept this one-time risk: ").strip()
            if answer!="RELOAD-WITH-ACTIVE-USERS":
                raise RuntimeError("Live bootstrap canceled; production untouched")
        source=CONFIG.read_text()
        start=source.index("proxy-groups:\n")
        end=source.index("rules:\n",start)
        exact=source[start:end]
        expected='''proxy-groups:
  - name: DUAL
    type: load-balance
    proxies:
      - XUDP-TRUST
      - XUDP-MIERU
    url: "https://www.gstatic.com/generate_204"
    expected-status: 204
    interval: 30
    lazy: false
    timeout: 3000
    max-failed-times: 1
    strategy: round-robin
'''
        if exact!=expected:
            raise RuntimeError("Production dispatcher.yaml differs from reviewed version; refusing")
        replace='''proxy-groups:
  - name: DUAL-AUTO
    type: load-balance
    proxies:
      - XUDP-TRUST
      - XUDP-MIERU
    url: "https://www.gstatic.com/generate_204"
    expected-status: 204
    interval: 30
    lazy: false
    timeout: 3000
    max-failed-times: 1
    strategy: round-robin
  - name: DUAL
    type: select
    proxies:
      - DUAL-AUTO
      - XUDP-TRUST
      - XUDP-MIERU
    default-selected: DUAL-AUTO
'''
        dest=source[:start]+replace+source[end:]
        with tempfile.TemporaryDirectory(prefix="nm-ha-verify-") as temp:
            cfg=pathlib.Path(temp)/"dispatcher.yaml"
            cfg.write_text(dest);cfg.chmod(0o600)
            cmd=["/usr/local/lib/dual-trust-mieru/mihomo","-t","-d",str(ROOT/"dispatcher-data"),
                 "-f",str(cfg)]
            if subprocess.run(cmd,timeout=20).returncode:
                raise RuntimeError("Mihomo config validation failed; production untouched")
        if not allow_live and api("GET","/connections").get("connections"):
            raise RuntimeError("New flows arrived; refusing reload")
        backup=STATE/"dispatcher-before-ha.yaml"
        if backup.exists():raise RuntimeError("Immutable HA rollback backup already exists; review before retry")
        atomic(backup,source)
        try:
            # Documented controller config reload (possible active-session interruption).
            api("PUT","/configs",{"payload":dest})
            if not armed(group()):
                raise RuntimeError("Controller did not confirm Selector after reload")
            selected=group().get("now")
            if selected!=AUTO:
                api("PUT","/proxies/DUAL",{"name":AUTO})
            atomic(CONFIG,dest)
            print("BOOTSTRAP SUCCESS: DUAL Selector -> DUAL-AUTO, Naive, Mieru.")
            print("Only future HA switches use /proxies/DUAL (no dispatcher reload).")
        except BaseException:
            # Restore both file AND runtime whenever possible. Fail loudly otherwise.
            try:
                api("PUT","/configs",{"payload":source})
                atomic(CONFIG,source)
            except Exception:
                print("CRITICAL: runtime rollback uncertain! Examine /proxies/DUAL",flush=True)
            raise

def main():
    p=argparse.ArgumentParser()
    p.add_argument("mode",choices=("once","dry-run","bootstrap","status"))
    p.add_argument("--allow-active-reload",action="store_true")
    a=p.parse_args()
    if os.geteuid()!=0:raise SystemExit("Run as root")
    if a.mode=="bootstrap":bootstrap(a.allow_active_reload)
    elif a.mode=="status":
        f=STATE/"status.json"
        print(f.read_text() if f.exists() else "NO HA STATUS YET")
    else:live_once(dry_run=a.mode=="dry-run")
if __name__=="__main__":
    try:main()
    except (RuntimeError,OSError,ValueError,KeyError,urllib.error.URLError,subprocess.TimeoutExpired,
            BlockingIOError) as e:
        print("HA ERROR:",type(e).__name__,str(e)[:300],flush=True)
        raise SystemExit(1)
