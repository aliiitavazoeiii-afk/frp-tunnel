#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$B/common.sh"
require_root
TRUST_BUNDLE=${1:-}
MIERU_BUNDLE=${2:-}
[[ -f "$TRUST_BUNDLE" && -f "$MIERU_BUNDLE" ]] || die "usage: $0 /root/dual-trust-client.json /root/dual-mieru-client.json"

D="$CONFIG_DIR/iran"
for x in "$D" /etc/systemd/system/dual-trust-client.service /etc/systemd/system/dual-mieru-client.service /etc/systemd/system/dual-xudp-bridge.service /etc/systemd/system/dual-dispatcher.service; do
  [[ ! -e "$x" ]] || die "existing Iran dual-tunnel state found at $x; run uninstall-iran.sh first if this is a previous test install"
done
for x in /etc/systemd/system/mieru.service /lib/systemd/system/mieru.service /usr/lib/systemd/system/mieru.service; do
  [[ ! -e "$x" ]] || die "existing standalone Mieru client installation detected; v1 Iran installer refuses to disable/replace it"
done

MIERU_INSTALLED=0
cleanup_install(){
  rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    log "Install failed; removing partial dual Iran services/config. x-ui was never touched."
    for svc in dual-dispatcher dual-xudp-bridge dual-mieru-client dual-trust-client; do
      systemctl disable --now "$svc.service" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$svc.service"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$D"
    if (( MIERU_INSTALLED )); then dpkg -r mieru >/dev/null 2>&1 || true; fi
    rm -f /usr/local/sbin/dual-tunnel-probe /usr/local/sbin/dual-tunnel-status /usr/local/sbin/dual-tunnel-failover-test
  fi
  exit "$rc"
}
trap cleanup_install EXIT

install_base_packages
mkdirs
for p in 7990 7991 7992 7993 7994 17994 19090; do free_port "$p"; done

jq -e '.version==1 and .kind=="trust" and .public_ip and .domain and .username and .password and .xudp_uuid' "$TRUST_BUNDLE" >/dev/null || die "invalid Trust bundle"
jq -e '.version==1 and .kind=="mieru" and .public_ip and .port_range and .username and .password and .xudp_uuid' "$MIERU_BUNDLE" >/dev/null || die "invalid Mieru bundle"

install_trust_client
install_mieru_deb client
MIERU_INSTALLED=1
install_xray
install_mihomo
systemctl disable --now mieru.service >/dev/null 2>&1 || true

mkdir -p "$D"; chmod 0700 "$D"
if command -v timedatectl >/dev/null 2>&1; then
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  [[ "$sync" == true ]] || log "WARNING: NTP synchronization is not reported active; verify the Iran and Mieru-foreign clocks are close"
fi
cp -a "$TRUST_BUNDLE" "$D/trust-bundle.json"
cp -a "$MIERU_BUNDLE" "$D/mieru-bundle.json"
chmod 0600 "$D"/*-bundle.json

TRUST_IP=$(jq -r '.public_ip' "$TRUST_BUNDLE")
TRUST_DOMAIN=$(jq -r '.domain' "$TRUST_BUNDLE")
TRUST_PORT=$(jq -r '.port' "$TRUST_BUNDLE")
TRUST_USER=$(jq -r '.username' "$TRUST_BUNDLE")
TRUST_PASS=$(jq -r '.password' "$TRUST_BUNDLE")
TRUST_UUID=$(jq -r '.xudp_uuid' "$TRUST_BUNDLE")
MIERU_IP=$(jq -r '.public_ip' "$MIERU_BUNDLE")
MIERU_RANGE=$(jq -r '.port_range' "$MIERU_BUNDLE")
MIERU_USER=$(jq -r '.username' "$MIERU_BUNDLE")
MIERU_PASS=$(jq -r '.password' "$MIERU_BUNDLE")
MIERU_UUID=$(jq -r '.xudp_uuid' "$MIERU_BUNDLE")
CONTROLLER_SECRET=$(openssl rand -hex 24)
printf '%s\n' "$CONTROLLER_SECRET" > "$D/controller.secret"; chmod 0600 "$D/controller.secret"

cat > "$D/trust-client.toml" <<EOF2
loglevel = "info"
vpn_mode = "general"
killswitch_enabled = false
post_quantum_group_enabled = true
exclusions_tcp_early_ack_enabled = false
exclusions_preresolve_enabled = false
exclusions = []

[endpoint]
hostname = "$TRUST_DOMAIN"
addresses = ["$TRUST_IP:$TRUST_PORT"]
has_ipv6 = false
username = "$TRUST_USER"
password = "$TRUST_PASS"
client_random = ""
skip_verification = false
certificate = ""
dns_upstreams = []
upstream_protocol = "http2"
anti_dpi = true

[listener.socks]
address = "127.0.0.1:7993"
EOF2
chmod 0600 "$D/trust-client.toml"

cat > "$D/mieru-client.json" <<EOF2
{
  "profiles":[{
    "profileName":"dual",
    "user":{"name":"$MIERU_USER","password":"$MIERU_PASS"},
    "servers":[{"ipAddress":"$MIERU_IP","domainName":"","portBindings":[{"portRange":"$MIERU_RANGE","protocol":"TCP"}]}],
    "mtu":1400,
    "multiplexing":{"level":"MULTIPLEXING_OFF"},
    "handshakeMode":"HANDSHAKE_STANDARD"
  }],
  "activeProfile":"dual",
  "rpcPort":17994,
  "socks5Port":7994,
  "loggingLevel":"INFO",
  "socks5ListenLAN":false
}
EOF2
chmod 0600 "$D/mieru-client.json"

cat > "$D/xudp.json" <<EOF2
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"trust-in","listen":"127.0.0.1","port":7991,"protocol":"socks","settings":{"auth":"noauth","udp":true}},
    {"tag":"mieru-in","listen":"127.0.0.1","port":7992,"protocol":"socks","settings":{"auth":"noauth","udp":true}}
  ],
  "outbounds":[
    {"tag":"xudp-trust","protocol":"vless","settings":{"address":"127.0.0.1","port":2443,"id":"$TRUST_UUID","encryption":"none"},"streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier-trust"}},"mux":{"enabled":true,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
    {"tag":"xudp-mieru","protocol":"vless","settings":{"address":"127.0.0.1","port":2443,"id":"$MIERU_UUID","encryption":"none"},"streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier-mieru"}},"mux":{"enabled":true,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
    {"tag":"carrier-trust","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":7993,"users":[]}]}},
    {"tag":"carrier-mieru","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":7994,"users":[]}]}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","inboundTag":["trust-in"],"outboundTag":"xudp-trust"},
    {"type":"field","inboundTag":["mieru-in"],"outboundTag":"xudp-mieru"}
  ]}
}
EOF2
chmod 0600 "$D/xudp.json"

cat > "$D/mihomo.yaml" <<EOF2
mode: rule
log-level: info
ipv6: false
external-controller: "127.0.0.1:19090"
secret: "$CONTROLLER_SECRET"
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
    interval: 10
    lazy: false
    timeout: 4000
    max-failed-times: 2
    strategy: round-robin
rules:
  - MATCH,DUAL
EOF2
chmod 0600 "$D/mihomo.yaml"

log "Validating Xray and Mihomo candidates"
"$BIN_DIR/xray" run -test -c "$D/xudp.json" >/dev/null
"$BIN_DIR/mihomo" -t -d "$D" -f "$D/mihomo.yaml" >/dev/null

log "Preflight Mieru carrier against foreign server"
MIERU_CONFIG_JSON_FILE="$D/mieru-client.json" mieru test https://www.gstatic.com/generate_204 >/dev/null || die "Mieru carrier preflight failed"

log "Preflight TrustTunnel client on local SOCKS/7993"
"$BIN_DIR/trusttunnel_client" --config "$D/trust-client.toml" >"$D/trust-candidate.log" 2>&1 & TPID=$!
cleanup_trust(){ kill "$TPID" 2>/dev/null || true; wait "$TPID" 2>/dev/null || true; }
trap cleanup_trust EXIT
for _ in $(seq 1 60); do
  ss -H -ltn 'sport = :7993' 2>/dev/null | grep -q . && break
  kill -0 "$TPID" 2>/dev/null || { tail -n 100 "$D/trust-candidate.log" >&2 || true; die "TrustTunnel client candidate exited"; }
  sleep 0.25
done
ss -H -ltn 'sport = :7993' | grep -q . || { tail -n 100 "$D/trust-candidate.log" >&2 || true; die "TrustTunnel SOCKS/7993 did not start"; }
code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7993 --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || { tail -n 100 "$D/trust-candidate.log" >&2 || true; die "TrustTunnel direct carrier preflight failed HTTP=$code"; }
cleanup_trust; trap - EXIT
rm -f "$D/trust-candidate.log"

mkdir -p /var/cache/dual-trust-mieru
chmod 0700 /var/cache/dual-trust-mieru

cat > /etc/systemd/system/dual-trust-client.service <<EOF2
[Unit]
Description=Dual tunnel TrustTunnel H2 client
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN_DIR/trusttunnel_client --config $D/trust-client.toml
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

cat > /etc/systemd/system/dual-mieru-client.service <<EOF2
[Unit]
Description=Dual tunnel Mieru TCP client
After=network-online.target
Wants=network-online.target
[Service]
Type=exec
Environment=MIERU_CONFIG_JSON_FILE=$D/mieru-client.json
Environment=XDG_CACHE_HOME=/var/cache/dual-trust-mieru
ExecStart=/usr/bin/mieru run
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/cache/dual-trust-mieru
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

cat > /etc/systemd/system/dual-xudp-bridge.service <<EOF2
[Unit]
Description=Dual Trust/Mieru XUDP bridge
After=dual-trust-client.service dual-mieru-client.service
Wants=dual-trust-client.service dual-mieru-client.service
[Service]
Type=simple
ExecStart=$BIN_DIR/xray run -c $D/xudp.json
Restart=always
RestartSec=2s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

cat > /etc/systemd/system/dual-dispatcher.service <<EOF2
[Unit]
Description=Dual Trust/Mieru health-aware load balancer
After=dual-xudp-bridge.service
Requires=dual-xudp-bridge.service
[Service]
Type=simple
WorkingDirectory=$D
ExecStart=$BIN_DIR/mihomo -d $D -f $D/mihomo.yaml
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$D
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

systemd-analyze verify /etc/systemd/system/dual-{trust-client,mieru-client,xudp-bridge,dispatcher}.service >/dev/null
systemctl daemon-reload
systemctl enable --now dual-trust-client.service dual-mieru-client.service >/dev/null
sleep 2
for p in 7993 7994; do ss -H -ltn "sport = :$p" | grep -q . || die "carrier SOCKS/$p missing"; done
systemctl enable --now dual-xudp-bridge.service >/dev/null
sleep 1
for p in 7991 7992; do ss -H -ltn "sport = :$p" | grep -q . || die "XUDP SOCKS/$p missing"; done
systemctl enable --now dual-dispatcher.service >/dev/null
sleep 2
ss -H -ltn 'sport = :7990' | grep -q . || { journalctl -u dual-dispatcher -n 100 --no-pager >&2 || true; die "dispatcher SOCKS/7990 missing"; }

install -m 0755 "$B/dual-probe.sh" /usr/local/sbin/dual-tunnel-probe
install -m 0755 "$B/status.sh" /usr/local/sbin/dual-tunnel-status
install -m 0755 "$B/failover-test.sh" /usr/local/sbin/dual-tunnel-failover-test
log "Running quick end-to-end probe"
/usr/local/sbin/dual-tunnel-probe --quick

unset TRUST_PASS MIERU_PASS TRUST_UUID MIERU_UUID CONTROLLER_SECRET
log "SUCCESS: Iran dual tunnel installed without touching x-ui"
log "Entry SOCKS: 127.0.0.1:7990"
log "Forced paths: Trust=7991, Mieru=7992"
log "Next: sudo dual-tunnel-probe --full"
log "Only after full probe passes, run attach-xui.sh explicitly."
trap - EXIT
