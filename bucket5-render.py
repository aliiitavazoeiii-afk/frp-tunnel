#!/usr/bin/env python3
import json, os, shlex, sys
from pathlib import Path

BUCKETS=10
MIHOMO_BASE=7901
XUDP_BASE=8101
LEGACY_MIHOMO=7890
LEGACY_XUDP=7891
XUDP_SERVER_PORT=2443

def load_env(path):
    data={}
    for raw in Path(path).read_text().splitlines():
        line=raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k,v=line.split('=',1)
        try:
            parts=shlex.split(v,posix=True)
            data[k]=parts[0] if parts else ''
        except Exception:
            data[k]=v.strip("'\"")
    return data

def q(v):
    return '"' + str(v).replace('\\','\\\\').replace('"','\\"') + '"'

if len(sys.argv)!=5:
    raise SystemExit("usage: bucket5-render.py DEPLOY_ENV BUCKET_ENV XUDP_UUID OUT_DIR")

deploy=load_env(sys.argv[1])
env=load_env(sys.argv[2])
xudp_uuid=sys.argv[3]
outdir=Path(sys.argv[4])
outdir.mkdir(parents=True, exist_ok=True)

for k in ("LOCAL_CONTROLLER_PORT","CONTROLLER_SECRET"):
    if not deploy.get(k): raise SystemExit(f"missing {k}")
for i in range(1,6):
    for suffix in ("ADDR","TYPE","COVER","ANYTLS","LAYER"):
        k=f"F{i}_{suffix}"
        if not env.get(k): raise SystemExit(f"missing {k}")
    if env[f"F{i}_TYPE"] not in ("shadow","restls"):
        raise SystemExit(f"invalid F{i}_TYPE")
if env.get("PROFILE") not in ("maya1","maya3"):
    raise SystemExit("PROFILE must be maya1 or maya3")
if not xudp_uuid or len(xudp_uuid)<32:
    raise SystemExit("invalid XUDP UUID")

lines=[
    "mode: rule",
    "log-level: info",
    "ipv6: false",
    f'external-controller: "127.0.0.1:{deploy["LOCAL_CONTROLLER_PORT"]}"',
    f"secret: {q(deploy['CONTROLLER_SECRET'])}",
    "profile:",
    "  store-selected: true",
    "",
    "listeners:",
    "  - name: legacy-xudp-carrier",
    "    type: socks",
    "    listen: 127.0.0.1",
    f"    port: {LEGACY_MIHOMO}",
    "    udp: true",
    "    proxy: LEGACY",
]
for b in range(1,BUCKETS+1):
    lines += [
        f"  - name: bucket-{b:02d}-carrier",
        "    type: socks",
        "    listen: 127.0.0.1",
        f"    port: {MIHOMO_BASE+b-1}",
        "    udp: true",
        f"    proxy: BUCKET-{b:02d}",
    ]

lines += ["", "proxies:"]
for i in range(1,6):
    typ=env[f"F{i}_TYPE"]
    lines += [
        f"  - name: F{i}",
        "    type: anytls",
        f"    server: {q(env[f'F{i}_ADDR'])}",
        "    port: 443",
        f"    password: {q(env[f'F{i}_ANYTLS'])}",
        "    tls: true",
        f"    sni: {q(env[f'F{i}_COVER'])}",
        "    client-fingerprint: chrome",
        "    udp: true",
        "    skip-cert-verify: false",
        "    idle-session-check-interval: 30",
        "    idle-session-timeout: 60",
        "    min-idle-session: 1",
    ]
    if typ=="shadow":
        lines += [
            "    shadow-tls-opts:",
            "      version: 3",
            f"      password: {q(env[f'F{i}_LAYER'])}",
        ]
    else:
        lines += [
            "    restls-opts:",
            f"      password: {q(env[f'F{i}_LAYER'])}",
            "      version-hint: tls13",
        ]

lines += [
    "",
    "proxy-groups:",
    "  - name: LEGACY",
    "    type: select",
    "    proxies: [F1, F2, F3, F4, F5, REJECT]",
    "    default-selected: F1",
]
for b in range(1,BUCKETS+1):
    default=((b-1)//2)+1
    lines += [
        f"  - name: BUCKET-{b:02d}",
        "    type: select",
        "    proxies: [F1, F2, F3, F4, F5, REJECT]",
        f"    default-selected: F{default}",
    ]

lines += ["", "rules:", "  - MATCH,LEGACY", ""]
mihomo="\n".join(lines)
(outdir/"mihomo.yaml").write_text(mihomo)
os.chmod(outdir/"mihomo.yaml",0o600)

inbounds=[{
    "tag":"xudp-legacy-in","listen":"127.0.0.1","port":LEGACY_XUDP,
    "protocol":"socks","settings":{"auth":"noauth","udp":True}
}]
for b in range(1,BUCKETS+1):
    inbounds.append({
        "tag":f"xudp-bucket-{b:02d}-in","listen":"127.0.0.1","port":XUDP_BASE+b-1,
        "protocol":"socks","settings":{"auth":"noauth","udp":True}
    })

outbounds=[]
rules=[]
def add_path(label, inbound_tag, carrier_port):
    inner=f"xudp-inner-{label}"
    carrier=f"carrier-{label}"
    outbounds.append({
        "tag":inner,
        "protocol":"vless",
        "settings":{"address":"127.0.0.1","port":XUDP_SERVER_PORT,"id":xudp_uuid,"encryption":"none"},
        "streamSettings":{"network":"raw","sockopt":{"dialerProxy":carrier}},
        "mux":{"enabled":True,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}
    })
    outbounds.append({
        "tag":carrier,
        "protocol":"socks",
        "settings":{"servers":[{"address":"127.0.0.1","port":carrier_port,"users":[]}]}
    })
    rules.append({"type":"field","inboundTag":[inbound_tag],"outboundTag":inner})

add_path("legacy","xudp-legacy-in",LEGACY_MIHOMO)
for b in range(1,BUCKETS+1):
    add_path(f"bucket-{b:02d}",f"xudp-bucket-{b:02d}-in",MIHOMO_BASE+b-1)

xconf={
    "log":{"loglevel":"warning"},
    "inbounds":inbounds,
    "outbounds":outbounds,
    "routing":{"domainStrategy":"AsIs","rules":rules}
}
(outdir/"xudp-bridge.json").write_text(json.dumps(xconf,separators=(",",":")))
os.chmod(outdir/"xudp-bridge.json",0o600)
