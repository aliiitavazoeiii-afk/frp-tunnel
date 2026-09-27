#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:-}
BUNDLE=${2:-}
D=/etc/dual-trust-mieru/iran
STATE=/var/lib/dual-trust-mieru
BIN=/usr/local/lib/dual-trust-mieru

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$ROLE" == trust || "$ROLE" == mieru ]] || die "usage: $0 trust|mieru /root/new-client-bundle.json"
[[ -s "$BUNDLE" ]] || die "bundle missing: $BUNDLE"
[[ -d "$D" && -s "$D/xudp.json" ]] || die "Iran dual tunnel state/xudp.json missing"

for s in dual-trust-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher; do
  systemctl is-active --quiet "$s.service" || die "$s inactive"
done

if [[ "$ROLE" == trust ]]; then
  jq -e '.version==1 and .kind=="trust" and .public_ip and .domain and .port and .username and .password and .xudp_uuid' "$BUNDLE" >/dev/null || die "invalid Trust bundle"
  LIVE_BUNDLE="$D/trust-bundle.json"
  LIVE_CFG="$D/trust-client.toml"
  CARRIER=dual-trust-client.service
  DIRECT_PORT=7993
  PATH_PORT=7991
  TAG=xudp-trust
else
  jq -e '.version==1 and .kind=="mieru" and .public_ip and .port_range and .username and .password and .xudp_uuid' "$BUNDLE" >/dev/null || die "invalid Mieru bundle"
  LIVE_BUNDLE="$D/mieru-bundle.json"
  LIVE_CFG="$D/mieru-carrier.yaml"
  CARRIER=dual-mieru-carrier.service
  DIRECT_PORT=7994
  PATH_PORT=7992
  TAG=xudp-mieru
fi

CURRENT_UUID=$(jq -r --arg tag "$TAG" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
NEW_UUID=$(jq -r '.xudp_uuid' "$BUNDLE")
[[ -n "$CURRENT_UUID" && "$CURRENT_UUID" != null ]] || die "current $TAG UUID missing"
[[ "$NEW_UUID" == "$CURRENT_UUID" ]] || die "bundle XUDP UUID does not match live $TAG UUID; refusing carrier-only cutover"

BK="$STATE/backups/carrier-only-${ROLE}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK"; chmod 0700 "$BK"
cp -a "$LIVE_CFG" "$BK/$(basename "$LIVE_CFG")"
cp -a "$LIVE_BUNDLE" "$BK/$(basename "$LIVE_BUNDLE")"

rollback(){
  local rc=${1:-1}
  trap - ERR INT TERM
  log "ROLLBACK: restoring previous $ROLE carrier"
  cp -a "$BK/$(basename "$LIVE_CFG")" "$LIVE_CFG"
  cp -a "$BK/$(basename "$LIVE_BUNDLE")" "$LIVE_BUNDLE"
  systemctl restart "$CARRIER" >/dev/null 2>&1 || true
  sleep 3
  log "Previous $ROLE carrier restored; shared bridge/dispatcher/x-ui were never restarted"
  exit "$rc"
}
trap 'rollback $?' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM

probe_stable(){
  local port=$1 label=$2 attempts=$3 needed=$4
  local code attempt streak=0
  for attempt in $(seq 1 "$attempts"); do
    code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
    if [[ "$code" == 204 ]]; then
      streak=$((streak+1))
      log "$label probe $attempt/$attempts = OK (streak $streak/$needed)"
      (( streak >= needed )) && return 0
    else
      log "$label probe $attempt/$attempts transient failure HTTP=${code:-000}"
      streak=0
    fi
    sleep 1
  done
  return 1
}

if [[ "$ROLE" == trust ]]; then
  TRUST_IP=$(jq -r '.public_ip' "$BUNDLE")
  TRUST_DOMAIN=$(jq -r '.domain' "$BUNDLE")
  TRUST_PORT=$(jq -r '.port' "$BUNDLE")
  TRUST_USER=$(jq -r '.username' "$BUNDLE")
  TRUST_PASS=$(jq -r '.password' "$BUNDLE")
  cat > "$LIVE_CFG.new" <<EOF2
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
  chmod 0600 "$LIVE_CFG.new"
else
  MIERU_IP=$(jq -r '.public_ip' "$BUNDLE")
  MIERU_RANGE=$(jq -r '.port_range' "$BUNDLE")
  MIERU_USER=$(jq -r '.username' "$BUNDLE")
  MIERU_PASS=$(jq -r '.password' "$BUNDLE")
  cat > "$LIVE_CFG.new" <<EOF2
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
    multiplexing: MULTIPLEXING_OFF
    handshake-mode: HANDSHAKE_STANDARD
    traffic-pattern: ""
rules:
  - MATCH,MIERU
EOF2
  chmod 0600 "$LIVE_CFG.new"
  "$BIN/mihomo" -t -d "$D/mieru-data" -f "$LIVE_CFG.new" >/dev/null
fi

mv "$LIVE_CFG.new" "$LIVE_CFG"
cp -a "$BUNDLE" "$LIVE_BUNDLE"
chmod 0600 "$LIVE_CFG" "$LIVE_BUNDLE"

log "Restarting ONLY $CARRIER; shared XUDP bridge/dispatcher/x-ui stay untouched"
systemctl restart "$CARRIER"
sleep 5
systemctl is-active --quiet "$CARRIER" || rollback 1
ss -H -ltn "sport = :$DIRECT_PORT" 2>/dev/null | grep -q . || rollback 1

log "Direct $ROLE carrier warm-up/stability probe"
if ! probe_stable "$DIRECT_PORT" "$role-direct" 10 3; then
  echo "ERROR: $ROLE direct carrier failed to become stable after 10 attempts" >&2
  rollback 1
fi

log "Existing split/XUDP path stability probe without bridge restart"
if ! probe_stable "$PATH_PORT" "$role-split" 8 2; then
  echo "ERROR: $ROLE split/XUDP path failed to become stable after 8 attempts" >&2
  rollback 1
fi

trap - ERR INT TERM
log "SUCCESS: $ROLE carrier replaced with matching live XUDP UUID"
log "No restart issued for dual-xudp-bridge, dual-dispatcher, x-ui, or the other carrier"
log "Backup retained at $BK"
