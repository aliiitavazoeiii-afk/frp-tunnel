#!/usr/bin/env python3
import os, shlex, sys
from pathlib import Path

def load_env(path):
    data={}
    for raw in Path(path).read_text().splitlines():
        line=raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k,v=line.split("=",1)
        try:
            parts=shlex.split(v, posix=True)
            data[k]=parts[0] if parts else ""
        except Exception:
            data[k]=v.strip("'\"")
    return data

if len(sys.argv)!=4:
    raise SystemExit("usage: shared-node-render.py DEPLOY_ENV SHARED_ENV OUTPUT")
d=load_env(sys.argv[1]); s=load_env(sys.argv[2]); out=Path(sys.argv[3])
need=["NODE_A_ADDR","NODE_B_ADDR","COVER_HOST_A","COVER_HOST_B","ANYTLS_PASS_A",
      "SHADOWTLS_PASS_A","ANYTLS_PASS_B","RESTLS_PASS_B","CONTROLLER_SECRET",
      "LOCAL_SOCKS_PORT","LOCAL_CONTROLLER_PORT"]
for k in need:
    if not d.get(k): raise SystemExit(f"missing {k}")
for k in ["SHARED_ADDR","SHARED_COVER","SHARED_ANYTLS_PASS","SHARED_SHADOWTLS_PASS"]:
    if not s.get(k): raise SystemExit(f"missing {k}")

def q(v):
    return '"' + str(v).replace("\\","\\\\").replace('"','\\"') + '"'

text=f'''mode: rule
log-level: info
ipv6: false
external-controller: "127.0.0.1:{d["LOCAL_CONTROLLER_PORT"]}"
secret: {q(d["CONTROLLER_SECRET"])}

listeners:
  - name: xray-socks-backend
    type: socks
    listen: 127.0.0.1
    port: {d["LOCAL_SOCKS_PORT"]}
    udp: true
    users: []

proxies:
  - name: foreign-a-shadowtls
    type: anytls
    server: {q(d["NODE_A_ADDR"])}
    port: 443
    password: {q(d["ANYTLS_PASS_A"])}
    tls: true
    sni: {q(d["COVER_HOST_A"])}
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    shadow-tls-opts:
      version: 3
      password: {q(d["SHADOWTLS_PASS_A"])}

  - name: foreign-b-restls
    type: anytls
    server: {q(d["NODE_B_ADDR"])}
    port: 443
    password: {q(d["ANYTLS_PASS_B"])}
    tls: true
    sni: {q(d["COVER_HOST_B"])}
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    restls-opts:
      password: {q(d["RESTLS_PASS_B"])}
      version-hint: tls13

  - name: foreign-shared-shadowtls
    type: anytls
    server: {q(s["SHARED_ADDR"])}
    port: 443
    password: {q(s["SHARED_ANYTLS_PASS"])}
    tls: true
    sni: {q(s["SHARED_COVER"])}
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    shadow-tls-opts:
      version: 3
      password: {q(s["SHARED_SHADOWTLS_PASS"])}

proxy-groups:
  - name: TUNNEL-BASE
    type: load-balance
    proxies:
      - foreign-a-shadowtls
      - foreign-b-restls
    url: "https://www.gstatic.com/generate_204"
    expected-status: 204
    interval: 5
    lazy: false
    timeout: 3500
    max-failed-times: 2
    strategy: sticky-sessions

  - name: TUNNEL-SHARED
    type: load-balance
    proxies:
      - foreign-a-shadowtls
      - foreign-b-restls
      - foreign-shared-shadowtls
    url: "https://www.gstatic.com/generate_204"
    expected-status: 204
    interval: 5
    lazy: false
    timeout: 3500
    max-failed-times: 2
    strategy: sticky-sessions

  - name: TUNNEL
    type: select
    proxies:
      - TUNNEL-BASE
      - TUNNEL-SHARED
    default-selected: TUNNEL-BASE

rules:
  - MATCH,TUNNEL
'''
out.write_text(text)
os.chmod(out,0o600)
