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
SERVICES=(dual-trust-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher)
for x in "$D" /etc/systemd/system/dual-trust-client.service /etc/systemd/system/dual-mieru-carrier.service /etc/systemd/system/dual-xudp-bridge.service /etc/systemd/system/dual-dispatcher.service; do
  [[ ! -e "$x" ]] || die "existing Iran dual-tunnel state found at $x; run uninstall-iran.sh first if this is a previous test install"
done

TPID=""; MPID=""
cleanup_install(){
  rc=$?
  trap - EXIT
  [[ -n "$TPID" ]] && kill "$TPID" 2>/dev/null || true
  [[ -n "$MPID" ]] && kill "$MPID" 2>/dev/null || true
  [[ -n "$TPID" ]] && wait "$TPID" 2>/dev/null || true
  [[ -n "$MPID" ]] && wait "$MPID" 2>/dev/null || true
  if (( rc != 0 )); then
    log "Install failed; recent dual Iran service logs follow before cleanup. x-ui was never touched."
    journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service -n 120 --no-pager 2>/dev/null || true
    log "Removing only partial dual Iran services/config. x-ui was never touched."
    for svc in "${SERVICES[@]}"; do
      systemctl disable --now "$svc.service" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$svc.service"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$D"
    rm -f /usr/local/sbin/dual-tunnel-probe /usr/local/sbin/dual-tunnel-status /usr/local/sbin/dual-tunnel-failover-test
  fi
  exit "$rc"
}
trap cleanup_install EXIT

install_base_packages
mkdirs
for p in 7990 7991 7992 7993 7994 19090; do free_port "$p"; done

jq -e '.version==1 and .kind=="trust" and .public_ip and .domain and .port and .username and .password and .xudp_uuid' "$TRUST_BUNDLE" >/dev/null || die "invalid Trust bundle"
jq -e '.version==1 and .kind=="mieru" and .public_ip and .port_range and .username and .password and .xudp_uuid' "$MIERU_BUNDLE" >/dev/null || die "invalid Mieru bundle"

install_trust_client
install_xray
install_mihomo

mkdir -p "$D" "$D/mieru-data" "$D/dispatcher-data"
chmod 0700 "$D" "$D/mieru-data" "$D/dispatcher-data"

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
printf '%s\n' "$CONTROLLER_SECRET" > "$D/controller.secret"
chmod 0600 "$D/controller.secret"

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
tls_profile = "chrome"
anti_dpi = true

[listener.socks]
address = "127.0.0.1:7993"
EOF2
chmod 0600 "$D/trust-client.toml"

cat > "$D/mieru-carrier.yaml" <<EOF2
mode: rule
log-level: info
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
    server: "$MIERU_IP"
    port-range: "$MIERU_RANGE"
    transport: TCP
    username: "$MIERU_USER"
    password: "$MIERU_PASS"
    multiplexing: MULTIPLEXING_LOW
    handshake-mode: HANDSHAKE_STANDARD
    traffic-pattern: ""
rules:
  - MATCH,MIERU
EOF2
chmod 0600 "$D/mieru-carrier.yaml"

cat > "$D/xudp.json" <<EOF2
{
  "log":{"loglevel":"info"},
  "inbounds":[
    {"tag":"trust-in","listen":"127.0.0.1","port":7991,"protocol":"socks","settings":{"auth":"noauth","udp":true}},
    {"tag":"mieru-in","listen":"127.0.0.1","port":7992,"protocol":"socks","settings":{"auth":"noauth","udp":true}}
  ],
  "outbounds":[
    {"tag":"xudp-trust","protocol":"vless","settings":{"address":"127.0.0.1","port":2443,"id":"$TRUST_UUID","encryption":"none"},"streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier-trust"}},"mux":{"enabled":true,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
    {"tag":"xudp-mieru","protocol":"vless","settings":{"address":"127.0.0.1","port":2443,"id":"$MIERU_UUID","encryption":"none"},"streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier-mieru"}},"mux":{"enabled":true,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
    {"tag":"carrier-trust","protocol":"socks","settings":{"address":"127.0.0.1","port":7993}},
    {"tag":"carrier-mieru","protocol":"socks","settings":{"address":"127.0.0.1","port":7994}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","inboundTag":["trust-in"],"outboundTag":"xudp-trust"},
    {"type":"field","inboundTag":["mieru-in"],"outboundTag":"xudp-mieru"}
  ]}
}
EOF2
chmod 0600 "$D/xudp.json"

cat > "$D/dispatcher.yaml" <<EOF2
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
    timeout: 5000
    max-failed-times: 2
    strategy: round-robin
rules:
  - MATCH,DUAL
EOF2
chmod 0600 "$D/dispatcher.yaml"

log "Validating Xray and both Mihomo candidates"
"$BIN_DIR/xray" run -test -c "$D/xudp.json" >/dev/null
"$BIN_DIR/mihomo" -t -d "$D/mieru-data" -f "$D/mieru-carrier.yaml" >/dev/null
"$BIN_DIR/mihomo" -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null

log "Preflight TrustTunnel direct carrier on local SOCKS/7993"
"$BIN_DIR/trusttunnel_client" --config "$D/trust-client.toml" >"$D/trust-candidate.log" 2>&1 & TPID=$!
for _ in $(seq 1 60); do
  ss -H -ltn 'sport = :7993' 2>/dev/null | grep -q . && break
  kill -0 "$TPID" 2>/dev/null || { tail -n 100 "$D/trust-candidate.log" >&2 || true; die "TrustTunnel client candidate exited"; }
  sleep 0.25
done
ss -H -ltn 'sport = :7993' 2>/dev/null | grep -q . || { tail -n 100 "$D/trust-candidate.log" >&2 || true; die "TrustTunnel SOCKS/7993 did not start"; }

# The SOCKS listener can appear slightly before the TrustTunnel session reaches
# CONNECTED. Wait for the actual carrier state so preflight does not race startup.
for _ in $(seq 1 80); do
  grep -Eq 'VPN_SS_CONNECTED|Successfully connected to endpoint' "$D/trust-candidate.log" 2>/dev/null && break
  kill -0 "$TPID" 2>/dev/null || { tail -n 100 "$D/trust-candidate.log" >&2 || true; die "TrustTunnel client candidate exited before CONNECTED"; }
  sleep 0.25
done
grep -Eq 'VPN_SS_CONNECTED|Successfully connected to endpoint' "$D/trust-candidate.log" 2>/dev/null || {
  tail -n 100 "$D/trust-candidate.log" >&2 || true
  die "TrustTunnel client did not reach CONNECTED state"
}

code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7993 --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || { tail -n 100 "$D/trust-candidate.log" >&2 || true; die "TrustTunnel direct carrier preflight failed HTTP=$code"; }
kill "$TPID" 2>/dev/null || true; wait "$TPID" 2>/dev/null || true; TPID=""
rm -f "$D/trust-candidate.log"

log "Preflight Mieru native carrier on local SOCKS/7994"
"$BIN_DIR/mihomo" -d "$D/mieru-data" -f "$D/mieru-carrier.yaml" >"$D/mieru-candidate.log" 2>&1 & MPID=$!
for _ in $(seq 1 60); do
  ss -H -ltn 'sport = :7994' 2>/dev/null | grep -q . && break
  kill -0 "$MPID" 2>/dev/null || { tail -n 100 "$D/mieru-candidate.log" >&2 || true; die "Mieru carrier candidate exited"; }
  sleep 0.25
done
ss -H -ltn 'sport = :7994' 2>/dev/null | grep -q . || { tail -n 100 "$D/mieru-candidate.log" >&2 || true; die "Mieru SOCKS/7994 did not start"; }
code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7994 --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || { tail -n 100 "$D/mieru-candidate.log" >&2 || true; die "Mieru direct carrier preflight failed HTTP=$code"; }
kill "$MPID" 2>/dev/null || true; wait "$MPID" 2>/dev/null || true; MPID=""
rm -f "$D/mieru-candidate.log"

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

cat > /etc/systemd/system/dual-mieru-carrier.service <<EOF2
[Unit]
Description=Dual tunnel native Mihomo Mieru TCP carrier
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=$D/mieru-data
ExecStart=$BIN_DIR/mihomo -d $D/mieru-data -f $D/mieru-carrier.yaml
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$D/mieru-data
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

cat > /etc/systemd/system/dual-xudp-bridge.service <<EOF2
[Unit]
Description=Dual Trust/Mieru XUDP bridge
After=dual-trust-client.service dual-mieru-carrier.service
Wants=dual-trust-client.service dual-mieru-carrier.service
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
Description=Dual Trust/Mieru health-aware full-path load balancer
After=dual-xudp-bridge.service
Wants=dual-xudp-bridge.service
[Service]
Type=simple
WorkingDirectory=$D/dispatcher-data
ExecStart=$BIN_DIR/mihomo -d $D/dispatcher-data -f $D/dispatcher.yaml
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$D/dispatcher-data
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

systemd-analyze verify /etc/systemd/system/dual-trust-client.service /etc/systemd/system/dual-mieru-carrier.service /etc/systemd/system/dual-xudp-bridge.service /etc/systemd/system/dual-dispatcher.service >/dev/null
systemctl daemon-reload
systemctl enable --now dual-trust-client.service dual-mieru-carrier.service >/dev/null
sleep 2
for p in 7993 7994; do ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . || die "carrier SOCKS/$p missing"; done
systemctl enable --now dual-xudp-bridge.service >/dev/null
sleep 1
for p in 7991 7992; do ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . || die "XUDP SOCKS/$p missing"; done
systemctl enable --now dual-dispatcher.service >/dev/null
sleep 2
ss -H -ltn 'sport = :7990' 2>/dev/null | grep -q . || { journalctl -u dual-dispatcher -n 100 --no-pager >&2 || true; die "dispatcher SOCKS/7990 missing"; }

install -m 0755 "$B/dual-probe.sh" /usr/local/sbin/dual-tunnel-probe
install -m 0755 "$B/status.sh" /usr/local/sbin/dual-tunnel-status
install -m 0755 "$B/failover-test.sh" /usr/local/sbin/dual-tunnel-failover-test

log "Running quick end-to-end forced-path probe"
/usr/local/sbin/dual-tunnel-probe --quick

unset TRUST_PASS MIERU_PASS TRUST_UUID MIERU_UUID CONTROLLER_SECRET
log "SUCCESS: Iran dual tunnel installed without touching x-ui"
log "Entry SOCKS: 127.0.0.1:7990"
log "Forced paths: Trust=7991, Mieru=7992"
log "Next: sudo dual-tunnel-probe --full"
log "Then on the empty test Iran only: sudo dual-tunnel-failover-test"
log "Only after both pass, run attach-xui.sh explicitly."
trap - EXIT
