#!/usr/bin/env bash
# FRESH foreign VPS ONLY. Builds exact Custom Backhaul V2+PoolGuard and joins a
# pre-staged Maya1 independent WSSMux lane; refuses existing services/configs.
set -Eeuo pipefail
umask 077
if [[ "$EUID" != 0 || $# != 2 || ! "$1" =~ ^[0-9a-f]{40}$ ]];then
 echo "Usage: sudo bash maya1-foreign-fresh-poolguard.sh PINNED_COMMIT /root/dual-ha-backhaul-bundle.env";exit 2
fi
REF="$1"
BUNDLE="$2"
[[ "$BUNDLE" == /root/dual-ha-backhaul-bundle.env && -f "$BUNDLE" &&
   ! -L "$BUNDLE" && "$(stat -c '%u' "$BUNDLE")" == 0 ]] || {
 echo "STOP: root-only private bundle missing/wrong path";exit 3;
}
[[ "$(uname -m)" == "x86_64" ]] || { echo "STOP: amd64 required";exit 3; }
python3 - "$BUNDLE" <<'PY'
import ipaddress,os,re,sys
p=sys.argv[1]
values={}
for line in open(p):
 m=re.fullmatch(r"([A-Z_]+)='([^']*)'\n?",line)
 if m:values[m.group(1)]=m.group(2)
required={"BH_DOMAIN","BH_IRAN_IP","BH_FOREIGN_IP","BH_TOKEN",
          "BH_CONTROL_PATH","BH_TUNNEL_PATH","BH_TLS_PORT"}
assert required <= values.keys(),"Incomplete bundle"
assert values["BH_DOMAIN"]=="bh-new.biya2film.top","Wrong domain"
assert values["BH_IRAN_IP"]=="94.184.4.38","Wrong Iran"
assert (values["BH_FOREIGN_IP"],values["BH_TLS_PORT"]) in (
    ("82.152.132.159","18447"),("152.237.230.77","18448")),"Wrong foreign/lane"
assert re.fullmatch("[a-f0-9]{64}",values["BH_TOKEN"]),"Invalid token"
assert re.fullmatch("/assets/[a-f0-9]{32}",values["BH_CONTROL_PATH"])
assert re.fullmatch("/socket/[a-f0-9]{32}",values["BH_TUNNEL_PATH"])
assert os.stat(p).st_mode & 0o077==0,"Bundle permissions must be 0600"
PY
# Refuse any existing related service or config, even if inactive.
for service in dual-ha-backhaul-client dual-ha-mita danted; do
 if [[ -e "/etc/systemd/system/$service.service" ]] ||
    systemctl is-active --quiet "$service" 2>/dev/null;then
   echo "STOP: $service already installed. Fresh VPS required.";exit 3
 fi
done
for f in /etc/danted.conf /etc/dual-ha/backhaul-foreign.toml \
         /etc/dual-ha/mita.json /opt/dual-ha/bin/backhaul; do
 [[ ! -e "$f" ]] || { echo "STOP: existing file $f";exit 3; }
done
for p in 11080 28443; do
 if ss -Hlnpt "( sport = :$p )" | grep -q LISTEN;then
   echo "STOP: port $p occupied";exit 3
 fi
done
source "$BUNDLE"
PUBLIC="$(curl -q -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [[ -n "$PUBLIC" && "$PUBLIC" != "$BH_FOREIGN_IP" ]];then
 echo "STOP: outgoing public IP differs: $PUBLIC expected $BH_FOREIGN_IP";exit 3
fi
echo "FRESH_FOREIGN_MATCH: $BH_FOREIGN_IP -> $BH_DOMAIN:$BH_TLS_PORT"
echo "Preparing packages for foreign-only Dante and pinned Go build..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl python3 tar openssl git \
                  dante-server iproute2
# Package postinstall might start a default Dante: stop ONLY the new service.
systemctl stop danted.service 2>/dev/null || true
TMP="$(mktemp -d /root/.maya1-foreign.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
GOBIN=""
if [[ -x /usr/lib/go-1.23/bin/go ]] &&
   /usr/lib/go-1.23/bin/go version | grep -q ' go1[.]23[.]1 ';then
 GOBIN=/usr/lib/go-1.23/bin/go
else
 if apt-cache show golang-1.23-go >/dev/null 2>&1;then
   apt-get install -y golang-1.23-go || true
 fi
 if [[ -x /usr/lib/go-1.23/bin/go ]] &&
    /usr/lib/go-1.23/bin/go version | grep -q ' go1[.]23[.]1 ';then
   GOBIN=/usr/lib/go-1.23/bin/go
 else
   echo "Fetching checksum-verified standalone Go 1.23.1"
   GOSHA=49bbb517cfa9eee677e1e7897f7cf9cfdbcf49e05f61984a2789136de359f9bd
   curl -fLSs --retry 2 --max-time 180 \
     https://go.dev/dl/go1.23.1.linux-amd64.tar.gz -o "$TMP/go.tar.gz"
   echo "$GOSHA  $TMP/go.tar.gz" | sha256sum -c --status || {
      echo "STOP: Go checksum mismatch";exit 4;
   }
   mkdir "$TMP/gotool"
   tar -xzf "$TMP/go.tar.gz" -C "$TMP/gotool"
   GOBIN="$TMP/gotool/go/bin/go"
 fi
fi
"$GOBIN" version | grep -q ' go1[.]23[.]1 ' || {
 echo "STOP: exact Go 1.23.1 required";exit 4;
}
UPSTREAM=df7966f8f725837a680ea7b90bd37ea52666c277
CUSTOM=e9111c6d78a922972482e3de720d1f82dca062d8
RAW="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/$CUSTOM/custom-backhaul"
ROOT="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
mkdir "$TMP/src"
curl -fLSs --retry 2 --max-time 180 \
 "https://codeload.github.com/Musixal/Backhaul/tar.gz/$UPSTREAM" -o "$TMP/source.tar.gz"
tar -xzf "$TMP/source.tar.gz" -C "$TMP/src" --strip-components=1
for patch in apply_patch.py fix_wsmux_config.py fix_wss_alpn.py;do
 curl -fsSLo "$TMP/$patch" "$RAW/$patch"
 python3 "$TMP/$patch" "$TMP/src"
done
curl -fsSLo "$TMP/client-pool-guard.py" "$ROOT/client-pool-guard.py"
python3 "$TMP/client-pool-guard.py" "$TMP/src"
export GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org,direct GOSUMDB=sum.golang.org
cd "$TMP/src"
"$GOBIN" get github.com/refraction-networking/utls@v1.6.7
"$(dirname "$GOBIN")/gofmt" -w internal/client/transport/wsmux.go
"$GOBIN" test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GOBIN" \
 build -trimpath -ldflags='-s -w' -o "$TMP/backhaul" .
# Exact binary from Maya3's first verified candidate build.
EXPECTED=aedf21b7e998c5a19bc5bff497764beb15d75f50171fd41ef759d3723b8b1bdb
ACTUAL="$(sha256sum "$TMP/backhaul" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]];then
 echo "STOP: build differs from working Maya3 Pool Guard binary"
 echo "Expected $EXPECTED"
 echo "Actual   $ACTUAL"
 echo "No active foreign tunnel service has been created.";exit 4
fi
echo "EXACT_MAYA3_POOLGUARD_SHA256_VERIFIED"
cd /root
# Make Dante serve only local traffic; never expose a public SOCKS port.
EXTDEV="$(ip -4 route get 1.1.1.1 |
 awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
[[ "$EXTDEV" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
 echo "STOP: network interface missing";exit 4;
}
cat >/etc/danted.conf <<EOF
logoutput: syslog
internal: 127.0.0.1 port = 11080
external: $EXTDEV
socksmethod: none
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass {
  from: 127.0.0.1/32 to: 0.0.0.0/0
  log: error
}
socks pass {
  from: 127.0.0.1/32 to: 0.0.0.0/0
  command: connect
  protocol: tcp
  log: error
}
EOF
chmod 0640 /etc/danted.conf
systemctl enable --now danted.service
systemctl is-active --quiet danted.service || {
 echo "STOP: Dante local SOCKS not active";exit 4;
}
curl -q -4 --noproxy "" --socks5-hostname 127.0.0.1:11080 \
 --connect-timeout 5 --max-time 15 -fsS \
 https://www.cloudflare.com/cdn-cgi/trace | grep -Fx "ip=$BH_FOREIGN_IP" || {
 echo "STOP: foreign Dante did not egress from expected IP";exit 4;
}
# Verify actual public Maya1 TLS+WS endpoint BEFORE starting reverse transport.
curl -q -4 --noproxy '*' --connect-timeout 5 --max-time 12 -fsS \
 "https://$BH_DOMAIN:$BH_TLS_PORT/" >/dev/null || {
 echo "STOP: Iran staging TLS endpoint unreachable; check provider firewall port";
 exit 4;
}
mkdir -p -m 0700 /etc/dual-ha
mkdir -p -m 0755 /opt/dual-ha/bin
install -m 0755 "$TMP/backhaul" /opt/dual-ha/bin/backhaul
cat >/etc/dual-ha/backhaul-foreign.toml <<EOF
[client]
remote_addr = "$BH_DOMAIN:$BH_TLS_PORT"
edge_ip = ""
transport = "wssmux"
token = "$BH_TOKEN"
ws_control_path = "$BH_CONTROL_PATH"
ws_tunnel_path = "$BH_TUNNEL_PATH"
tls_skip_verify = false
tls_server_name = "$BH_DOMAIN"
connection_pool = 16
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 0
log_level = "info"
EOF
chmod 0600 /etc/dual-ha/backhaul-foreign.toml
cat >/etc/systemd/system/dual-ha-backhaul-client.service <<'UNIT'
[Unit]
Description=Maya1 Custom Backhaul WSSMux PoolGuard foreign client
Wants=network-online.target
After=network-online.target danted.service
Requires=danted.service
[Service]
Type=simple
ExecStart=/opt/dual-ha/bin/backhaul -c /etc/dual-ha/backhaul-foreign.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now dual-ha-backhaul-client
systemctl is-active --quiet dual-ha-backhaul-client
echo "FOREIGN_MAYA1_POOLGUARD_ACTIVE=$BH_FOREIGN_IP"
echo "SERVER_DOMAIN=$BH_DOMAIN"
echo "POOL_BASE=16 PHYSICAL_SOCKETS_CAP=64"
echo "CUSTOM_TLS_ALPN_WS_PROFILES_MATCH_MAYA3=TRUE"
echo "NOW TEST STAGED SOCKS EGRESS FROM IRAN MAYA1."
