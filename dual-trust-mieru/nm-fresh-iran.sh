#!/usr/bin/env bash
# Fresh Iran deployment: Naive foreign + Mieru foreign; no TrustTunnel.
# Does NOT install or modify x-ui. Refuses existing tunnel installations.
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/common.sh"
source "$HERE/lane3-common.sh"

[[ $EUID -eq 0 ]] || die 'run as root'
[[ $# -eq 2 ]] || die 'usage: bash nm-fresh-iran.sh /root/lane3-naive-client.json /root/dual-mieru-client.json'
NAIVE_SOURCE=$1
MIERU_SOURCE=$2
[[ -s "$NAIVE_SOURCE" && -s "$MIERU_SOURCE" ]] || die 'Both foreign bundles must already be copied to Iran via SCP'
[[ ! -e /etc/dual-trust-mieru/iran && ! -e /etc/dual-trust-mieru/naive-mieru ]] || die 'EXISTING TUNNEL FOUND: this installer is only for a NEW Iran VPS'
for unit in dual-dispatcher dual-xudp-bridge dual-mieru-carrier nm-naive-client dual-trust-client; do
  if systemctl is-active --quiet "$unit.service" 2>/dev/null; then die "existing tunnel service $unit active; abort"; fi
  [[ ! -e "/etc/systemd/system/$unit.service" ]] || die "existing unit: $unit"
done
for port in 7990 7991 7992 7993 7994 19090;do free_port "$port";done
command -v python3 >/dev/null || die 'python3 missing'
command -v jq >/dev/null || die 'jq missing'
log 'Validating both separate foreign bundles (credentials hidden)'
NAIVE_SOURCE="$NAIVE_SOURCE" MIERU_SOURCE="$MIERU_SOURCE" python3 <<'PY'
import json,os,ipaddress,re,socket
a=json.load(open(os.environ["NAIVE_SOURCE"]))
b=json.load(open(os.environ["MIERU_SOURCE"]))
assert a.get("version")==1 and a.get("kind")=="lane3-naive" and a.get("port")==443, "invalid Naive foreign bundle"
assert b.get("version")==1 and b.get("kind")=="mieru", "invalid Mieru foreign bundle"
assert a.get("transport")=="https", "Naive transport is not HTTPS"
for d in (a,b):
    ipaddress.IPv4Address(d["public_ip"])
    for k in ("username","password","xudp_uuid"):
        assert isinstance(d.get(k),str) and bool(d[k]), f"missing {k}"
    assert re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',d["xudp_uuid"]), "invalid XUDP UUID"
assert a["public_ip"] != b["public_ip"], "Foreign Naive and Mieru require SEPARATE VPS IPs"
assert re.fullmatch(r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}",a["domain"]), "invalid Naive hostname"
assert a["public_ip"] in socket.gethostbyname_ex(a["domain"])[2], "Naive domain DNS does not point to its foreign IP"
assert re.fullmatch(r"([0-9]{4,5})-([0-9]{4,5})",b["port_range"]), "invalid Mieru TCP range"
p,q=map(int,b["port_range"].split("-"))
assert 1025<=p<=q<=65535 and q-p<=200, "invalid Mieru TCP range values"
assert a["xudp_uuid"]!=b["xudp_uuid"], "two independent foreign XUDP UUIDs required"
print("Validated: separate Naive + Mieru foreign endpoints and XUDP UUIDs")
PY

log 'Installing verified, version-pinned network binaries'
install_base_packages
apt-get install -y --no-install-recommends xz-utils git >/dev/null
install_xray
install_mihomo
# Verified NaiveProxy v154.0.8037.49-5; reuse project-pinned installer.
l3_install_naive

ROOT=/etc/dual-trust-mieru/iran
N=/etc/dual-trust-mieru/naive-mieru
mkdir -p "$ROOT/mieru-data" "$ROOT/dispatcher-data" "$N"
chmod 0700 "$ROOT" "$ROOT/mieru-data" "$ROOT/dispatcher-data" "$N"
install -m 0600 "$NAIVE_SOURCE" "$N/bundle.json"
install -m 0600 "$MIERU_SOURCE" "$ROOT/mieru-bundle.json"
# The outbound XUDP target is the Naive foreign's loopback, via Caddy
# forwarding to xudp-trust.internal:2443.
grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+xudp-trust\.internal([[:space:]]|$)' /etc/hosts ||
  echo '127.0.0.1 xudp-trust.internal # nm-fresh-naive' >> /etc/hosts

ROOT="$ROOT" N="$N" python3 <<'PY'
import json,os,pathlib,secrets
root=pathlib.Path(os.environ["ROOT"]);n=pathlib.Path(os.environ["N"])
a=json.load(open(n/"bundle.json"));b=json.load(open(root/"mieru-bundle.json"))
def save(path,content):
    with path.open("x") as f:f.write(content)
    path.chmod(0o600)
naive={"listen":"socks://127.0.0.1:7993",
       "proxy":f"https://{a['username']}:{a['password']}@{a['domain']}",
       "host-resolver-rules":f"MAP {a['domain']} {a['public_ip']}"}
save(n/"naive-live.json",json.dumps(naive,indent=2)+"\n")
mieru=f'''mode: rule
log-level: warning
ipv6: false
listeners:
  - name: mieru-carrier-socks
    type: socks
    listen: 127.0.0.1
    port: 7994
    udp: true
    proxy: MIERU
proxies:
  - name: MIERU
    type: mieru
    server: {json.dumps(b["public_ip"])}
    port-range: {json.dumps(b["port_range"])}
    transport: TCP
    username: {json.dumps(b["username"])}
    password: {json.dumps(b["password"])}
    multiplexing: MULTIPLEXING_OFF
    handshake-mode: HANDSHAKE_STANDARD
    traffic-pattern: ""
rules:
  - MATCH,MIERU
'''
save(root/"mieru-carrier.yaml",mieru)
bridge={
 "log":{"loglevel":"warning"},
 "inbounds":[
   {"tag":"trust-in","listen":"127.0.0.1","port":7991,"protocol":"socks","settings":{"auth":"noauth","udp":True}},
   {"tag":"mieru-in","listen":"127.0.0.1","port":7992,"protocol":"socks","settings":{"auth":"noauth","udp":True}}
 ],
 "outbounds":[
   {"tag":"xudp-trust","protocol":"vless",
    "settings":{"address":"xudp-trust.internal","port":2443,"id":a["xudp_uuid"],"encryption":"none"},
    "streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier-trust"}},
    "mux":{"enabled":True,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
   {"tag":"xudp-mieru","protocol":"vless",
    "settings":{"address":"127.0.0.1","port":2443,"id":b["xudp_uuid"],"encryption":"none"},
    "streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier-mieru"}},
    "mux":{"enabled":True,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
   {"tag":"carrier-trust","protocol":"socks","settings":{"address":"127.0.0.1","port":7993}},
   {"tag":"carrier-mieru","protocol":"socks","settings":{"address":"127.0.0.1","port":7994}}
 ],
 "routing":{"domainStrategy":"AsIs","rules":[
   {"type":"field","inboundTag":["trust-in"],"network":"tcp","outboundTag":"carrier-trust"},
   {"type":"field","inboundTag":["trust-in"],"network":"udp","outboundTag":"xudp-trust"},
   {"type":"field","inboundTag":["mieru-in"],"network":"tcp","outboundTag":"carrier-mieru"},
   {"type":"field","inboundTag":["mieru-in"],"network":"udp","outboundTag":"xudp-mieru"}
 ]}
}
save(root/"xudp.json",json.dumps(bridge,indent=2)+"\n")
controller_secret=secrets.token_hex(24)
save(root/"controller.secret",controller_secret+"\n")
dispatcher=f'''mode: rule
log-level: warning
ipv6: false
external-controller: "127.0.0.1:19090"
secret: {json.dumps(controller_secret)}
listeners:
  - name: dual-entry
    type: socks
    listen: 127.0.0.1
    port: 7990
    udp: true
    proxy: DUAL
proxies:
  - name: XUDP-TRUST
    type: socks5
    server: 127.0.0.1
    port: 7991
    udp: true
  - name: XUDP-MIERU
    type: socks5
    server: 127.0.0.1
    port: 7992
    udp: true
proxy-groups:
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
rules:
  - MATCH,DUAL
'''
save(root/"dispatcher.yaml",dispatcher)
print("Rendered dedicated Naive+Mieru Iran stack. Naive uses the proven single-client SOCKS model.")
PY

"$BIN_DIR/xray" run -test -c "$ROOT/xudp.json" >/dev/null
"$BIN_DIR/mihomo" -t -d "$ROOT/mieru-data" -f "$ROOT/mieru-carrier.yaml" >/dev/null
"$BIN_DIR/mihomo" -t -d "$ROOT/dispatcher-data" -f "$ROOT/dispatcher.yaml" >/dev/null

cat >/etc/systemd/system/nm-naive-client.service <<EOF
[Unit]
Description=Fresh Naive direct HTTP2 carrier
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN_DIR/naive $N/naive-live.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dual-mieru-carrier.service <<EOF
[Unit]
Description=Fresh Mieru independent carrier
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=$ROOT/mieru-data
ExecStart=$BIN_DIR/mihomo -d $ROOT/mieru-data -f $ROOT/mieru-carrier.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$ROOT/mieru-data
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dual-xudp-bridge.service <<EOF
[Unit]
Description=Naive and Mieru split TCP/XUDP bridge
After=nm-naive-client.service dual-mieru-carrier.service
Wants=nm-naive-client.service dual-mieru-carrier.service
[Service]
Type=simple
ExecStart=$BIN_DIR/xray run -c $ROOT/xudp.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dual-dispatcher.service <<EOF
[Unit]
Description=Naive and Mieru round-robin front SOCKS
After=dual-xudp-bridge.service
Wants=dual-xudp-bridge.service
[Service]
Type=simple
WorkingDirectory=$ROOT/dispatcher-data
ExecStart=$BIN_DIR/mihomo -d $ROOT/dispatcher-data -f $ROOT/dispatcher.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$ROOT/dispatcher-data
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
systemd-analyze verify \
  /etc/systemd/system/nm-naive-client.service \
  /etc/systemd/system/dual-mieru-carrier.service \
  /etc/systemd/system/dual-xudp-bridge.service \
  /etc/systemd/system/dual-dispatcher.service >/dev/null
systemctl daemon-reload
log 'Starting local carriers and bridge on NEW Iran VPS only'
systemctl enable --now nm-naive-client.service dual-mieru-carrier.service >/dev/null
sleep 3
systemctl enable --now dual-xudp-bridge.service >/dev/null
sleep 2
systemctl enable --now dual-dispatcher.service >/dev/null
sleep 3
for svc in nm-naive-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher;do
 systemctl is-active --quiet "$svc.service" || die "inactive service: $svc"
done
for port in 7990 7991 7992 7993 7994 19090;do
  ss -H -ltn "sport = :$port" |grep -q . || die "missing listener $port"
done

check_http(){
 local name=$1 port=$2 count=$3 i good=0 rc output code latency
 for ((i=1;i<=count;i++));do
   rc=0
   output=$(curl -q -4 -sS --socks5-hostname "127.0.0.1:$port" \
     --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code} %{time_total}' \
     https://www.gstatic.com/generate_204 2>/dev/null) || rc=$?
   code=$(awk '{print $1}' <<<"$output");latency=$(awk '{print $2}' <<<"$output")
   if ((rc==0)) && [[ "$code" == 204 ]] &&
     awk -v t="$latency" 'BEGIN{exit !(t<3.0)}';then
       good=$((good+1))
   else
       log "WARN $name :$port round=$i curl=$rc status=$code latency=$latency"
   fi
   sleep .15
 done
 log "$name :$port => $good/$count HTTP204 within 3s"
 ((good==count))
}
log 'STRICT FINAL HEALTH: HTTP + split TCP + UDP/XUDP; no public users attached'
check_http NAIVE_DIRECT 7993 12 || die 'Naive foreign path unstable; do not attach x-ui'
check_http MIERU_DIRECT 7994 12 || die 'Mieru foreign path unstable; do not attach x-ui'
check_http NAIVE_SPLIT 7991 12 || die 'Naive split path unstable; do not attach x-ui'
check_http MIERU_SPLIT 7992 12 || die 'Mieru split path unstable; do not attach x-ui'
for port in 7991 7992;do
 for i in 1 2 3;do
   l3_udp "$port" || die "real XUDP/DNS failure on :$port; do not attach x-ui"
 done
 log "UDP/XUDP port :$port 3/3 PASS"
done
check_http DUAL_DISPATCHER 7990 16 || die 'Dispatcher unhealthy; do not attach x-ui'
# Recognized by the existing Naive/Mieru manager and replacement scripts.
mkdir -p /var/lib/dual-trust-mieru/naive-mieru
date -Is >/var/lib/dual-trust-mieru/naive-mieru/live-cutover.timestamp
install -m 0755 "$HERE/nm-health.sh" /usr/local/sbin/nm-health
log 'SUCCESS: new Iran Naive + Mieru tunnel staged and validated at 127.0.0.1:7990'
log 'NO PUBLIC INBOUND ATTACHED. Create/configure 3X-UI VLESS REALITY :443, then explicitly attach it.'
log 'Note: successful idle synthetic checks DO NOT certify Naive under heavy production load.'
