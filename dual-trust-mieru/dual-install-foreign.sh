#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$B/common.sh"
require_root

ROLE=''; PUBLIC_IP=''; DOMAIN=''; EMAIL=''; PORT_RANGE='20000-20020'; UUID_FILE=''; NONINTERACTIVE=0
STAGE=argument-parse
stage(){ STAGE=$1; log "STAGE=$STAGE"; }
err(){ local rc=$?; echo "ERROR: foreign installer failed at stage=$STAGE rc=$rc command=${BASH_COMMAND:-unknown}" >&2; exit "$rc"; }
trap err ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE=${2:-}; shift 2 ;;
    --public-ip) PUBLIC_IP=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --port-range) PORT_RANGE=${2:-}; shift 2 ;;
    --xudp-uuid-file) UUID_FILE=${2:-}; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

banner(){
  echo '============================================================'
  echo '              DUAL MIERU TRUST TUNNEL'
  echo '                 power by ali tavazoei'
  echo '============================================================'
}
banner

if [[ -z "$ROLE" && $NONINTERACTIVE -eq 0 ]]; then
  echo '1) Trust foreign'
  echo '2) Mieru foreign'
  read -r -p 'Select role [1/2]: ' x
  case "$x" in 1) ROLE=trust;; 2) ROLE=mieru;; *) die 'invalid role';; esac
fi
[[ "$ROLE" == trust || "$ROLE" == mieru ]] || die 'role must be trust or mieru'

valid_ipv4(){
  local IFS=. a b c d extra o
  read -r a b c d extra <<<"$1"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for o in "$a" "$b" "$c" "$d"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] && (( 10#$o <= 255 )) || return 1; done
}

[[ -n "$PUBLIC_IP" || $NONINTERACTIVE -eq 1 ]] || read -r -p 'Public IPv4: ' PUBLIC_IP
valid_ipv4 "$PUBLIC_IP" || die 'valid IPv4 required'

if [[ "$ROLE" == trust ]]; then
  [[ -n "$DOMAIN" || $NONINTERACTIVE -eq 1 ]] || read -r -p 'Trust domain: ' DOMAIN
  [[ -n "$EMAIL" || $NONINTERACTIVE -eq 1 ]] || read -r -p "Let's Encrypt email: " EMAIL
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'valid Trust domain required'
  [[ "$EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'valid email required'
else
  if [[ $NONINTERACTIVE -eq 0 ]]; then
    read -r -p "Mieru port range [$PORT_RANGE]: " x || true
    [[ -z "${x:-}" ]] || PORT_RANGE=$x
  fi
  [[ "$PORT_RANGE" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]] || die 'invalid Mieru port range'
fi

LIVE_UUID=''
if [[ -n "$UUID_FILE" ]]; then
  stage uuid-file
  [[ -s "$UUID_FILE" ]] || die "UUID file missing: $UUID_FILE"
  LIVE_UUID=$(tr -d '\r\n ' < "$UUID_FILE")
  [[ "$LIVE_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die 'UUID file is invalid'
fi

stage base-role
if [[ "$ROLE" == trust ]]; then
  D="$CONFIG_DIR/trust"; BUNDLE=/root/dual-trust-client.json; XSVC=dual-xudp-trust.service
  if [[ -s "$D/xray.json" && -s "$D/vpn.toml" && -s "$BUNDLE" ]] \
     && systemctl is-active --quiet dual-trust-endpoint.service \
     && systemctl is-active --quiet dual-xudp-trust.service; then
    [[ $(jq -r '.kind // empty' "$BUNDLE") == trust ]] || die 'existing Trust bundle has wrong role'
    [[ $(jq -r '.public_ip // empty' "$BUNDLE") == "$PUBLIC_IP" ]] || die 'existing Trust install belongs to a different public IP'
    [[ $(jq -r '.domain // empty' "$BUNDLE") == "$DOMAIN" ]] || die 'existing Trust install belongs to a different domain'
    log 'Existing healthy Trust foreign detected; resuming validation without reinstalling endpoint'
  else
    [[ ! -e "$D" && ! -e "$BUNDLE" ]] || die 'partial/inactive Trust state exists; inspect before reinstalling'
    bash "$B/install-foreign-trust.sh" --public-ip "$PUBLIC_IP" --domain "$DOMAIN" --email "$EMAIL"
  fi
  tmp=$(mktemp)
  jq --arg email "$EMAIL" '.cert_email=$email' "$BUNDLE" > "$tmp" || die 'failed to add cert email to Trust bundle'
  install -m 0600 "$tmp" "$BUNDLE"; rm -f "$tmp"
else
  D="$CONFIG_DIR/mieru"; BUNDLE=/root/dual-mieru-client.json; XSVC=dual-xudp-mieru.service
  if [[ -s "$D/xray.json" && -s "$D/mita-server.json" && -s "$BUNDLE" ]] \
     && systemctl is-active --quiet dual-xudp-mieru.service \
     && mita status 2>/dev/null | grep -q RUNNING; then
    [[ $(jq -r '.kind // empty' "$BUNDLE") == mieru ]] || die 'existing Mieru bundle has wrong role'
    [[ $(jq -r '.public_ip // empty' "$BUNDLE") == "$PUBLIC_IP" ]] || die 'existing Mieru install belongs to a different public IP'
    [[ $(jq -r '.port_range // empty' "$BUNDLE") == "$PORT_RANGE" ]] || die 'existing Mieru install uses a different port range'
    log 'Existing healthy Mieru foreign detected; resuming validation without reinstalling endpoint'
  else
    [[ ! -e "$D" && ! -e "$BUNDLE" ]] || die 'partial/inactive Mieru state exists; inspect before reinstalling'
    bash "$B/install-foreign-mieru-final.sh" --public-ip "$PUBLIC_IP" --port-range "$PORT_RANGE"
  fi
fi

if [[ -n "$LIVE_UUID" ]]; then
  stage uuid-sync
  BUNDLE_UUID=$(jq -r '.xudp_uuid // empty' "$BUNDLE")
  SERVER_UUID=$(jq -r '.inbounds[] | select(.tag=="xudp-in") | .settings.users[0].id // empty' "$D/xray.json")
  if [[ "$BUNDLE_UUID" == "$LIVE_UUID" && "$SERVER_UUID" == "$LIVE_UUID" ]]; then
    log 'UUID state = MATCH; no XUDP restart needed'
  else
    log 'UUID state = DIFFERENT; applying live Iran UUID without printing it'
    cp -a "$D/xray.json" "$D/xray.json.before-live-uuid"
    cp -a "$BUNDLE" "${BUNDLE}.before-live-uuid"

    XTMP=$(mktemp)
    jq --arg uuid "$LIVE_UUID" '(.inbounds[] | select(.tag=="xudp-in").settings.users[0].id)=$uuid' "$D/xray.json" > "$XTMP" \
      || die 'XRAY-JSON patch failed'
    stage xray-validate
    "$BIN_DIR/xray" run -test -c "$XTMP" >/dev/null \
      || die 'XRAY-VALIDATE failed after UUID patch'
    install -m 0600 "$XTMP" "$D/xray.json"; rm -f "$XTMP"

    BTMP=$(mktemp)
    jq --arg uuid "$LIVE_UUID" '.xudp_uuid=$uuid' "$BUNDLE" > "$BTMP" \
      || die 'BUNDLE-JSON patch failed'
    install -m 0600 "$BTMP" "$BUNDLE"; rm -f "$BTMP"

    stage xudp-restart
    if ! systemctl restart "$XSVC"; then
      journalctl -u "$XSVC" -n 40 --no-pager >&2 || true
      die 'XUDP-RESTART command failed'
    fi
    sleep 2
    if ! systemctl is-active --quiet "$XSVC"; then
      journalctl -u "$XSVC" -n 40 --no-pager >&2 || true
      die 'XUDP service inactive after UUID apply'
    fi

    BUNDLE_UUID=$(jq -r '.xudp_uuid // empty' "$BUNDLE")
    SERVER_UUID=$(jq -r '.inbounds[] | select(.tag=="xudp-in") | .settings.users[0].id // empty' "$D/xray.json")
    [[ "$BUNDLE_UUID" == "$LIVE_UUID" && "$SERVER_UUID" == "$LIVE_UUID" ]] || die 'UUID verification failed'
    log 'UUID state = MATCH after apply'
  fi
  rm -f "$UUID_FILE" 2>/dev/null || true
fi

socks_connect_test(){
  local port=$1 target=$2 target_port=$3
  PROBE_SOCKS_PORT="$port" PROBE_TARGET="$target" PROBE_TARGET_PORT="$target_port" python3 <<'PY'
import os,socket,struct,ipaddress
p=int(os.environ['PROBE_SOCKS_PORT']); host=os.environ['PROBE_TARGET']; dp=int(os.environ['PROBE_TARGET_PORT'])
def r(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError('SOCKS closed')
        b+=x
    return b
s=socket.create_connection(('127.0.0.1',p),timeout=5)
s.sendall(b'\x05\x01\x00')
if r(s,2)!=b'\x05\x00': raise RuntimeError('SOCKS auth')
try:
    ip=ipaddress.ip_address(host)
    req=b'\x05\x01\x00'+(b'\x01'+ip.packed if ip.version==4 else b'\x04'+ip.packed)
except ValueError:
    hb=host.encode(); req=b'\x05\x01\x00\x03'+bytes([len(hb)])+hb
s.sendall(req+struct.pack('!H',dp))
h=r(s,4)
if h[1]!=0: raise RuntimeError(f'SOCKS CONNECT reply={h[1]}')
at=h[3]
if at==1: r(s,4)
elif at==3: r(s,r(s,1)[0])
elif at==4: r(s,16)
r(s,2)
PY
}

stage carrier-preflight
if [[ "$ROLE" == trust ]]; then
  install_trust_client
  free_port 17993
  U=$(jq -r '.username' "$BUNDLE"); P=$(jq -r '.password' "$BUNDLE")
  TCFG=$(mktemp); TLOG=$(mktemp)
  cat > "$TCFG" <<EOT
loglevel = "info"
vpn_mode = "general"
killswitch_enabled = false
post_quantum_group_enabled = true
exclusions_tcp_early_ack_enabled = false
exclusions_preresolve_enabled = false
exclusions = []
[endpoint]
hostname = "$DOMAIN"
addresses = ["127.0.0.1:443"]
has_ipv6 = false
username = "$U"
password = "$P"
client_random = ""
skip_verification = false
certificate = ""
dns_upstreams = []
upstream_protocol = "http2"
tls_profile = "chrome"
anti_dpi = false
[listener.socks]
address = "127.0.0.1:17993"
EOT
  chmod 0600 "$TCFG" "$TLOG"
  "$BIN_DIR/trusttunnel_client" --config "$TCFG" >"$TLOG" 2>&1 & pid=$!
  ready=0
  for _ in $(seq 1 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 50 "$TLOG" >&2 || true
      wait "$pid" 2>/dev/null || true
      rm -f "$TCFG" "$TLOG"
      die 'TRUST-PREFLIGHT client exited before ready'
    fi
    if ss -H -ltn 'sport = :17993' 2>/dev/null | grep -q . \
       && grep -Eq 'VPN_SS_CONNECTED|Successfully connected to endpoint' "$TLOG" 2>/dev/null; then
      ready=1; break
    fi
    sleep .2
  done
  if (( ready == 0 )); then
    tail -n 50 "$TLOG" >&2 || true
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    rm -f "$TCFG" "$TLOG"
    die 'TRUST-PREFLIGHT did not reach CONNECTED state'
  fi
  if ! socks_connect_test 17993 xudp-trust.internal 2443; then
    tail -n 50 "$TLOG" >&2 || true
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    rm -f "$TCFG" "$TLOG"
    die 'TRUST-PREFLIGHT tunneled XUDP backend failed'
  fi
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  rm -f "$TCFG" "$TLOG"
else
  install_mihomo
  free_port 17994
  U=$(jq -r '.username' "$BUNDLE"); P=$(jq -r '.password' "$BUNDLE"); PR=$(jq -r '.port_range' "$BUNDLE")
  MCFG=$(mktemp); MLOG=$(mktemp); MD=$(mktemp -d)
  cat > "$MCFG" <<EOT
mode: rule
log-level: warning
ipv6: false
listeners:
  - name: local-preflight
    type: socks
    listen: 127.0.0.1
    port: 17994
    udp: true
    proxy: MIERU
proxies:
  - name: MIERU
    type: mieru
    server: 127.0.0.1
    port-range: "$PR"
    transport: TCP
    username: "$U"
    password: "$P"
    multiplexing: MULTIPLEXING_OFF
    handshake-mode: HANDSHAKE_STANDARD
    traffic-pattern: ""
rules:
  - MATCH,MIERU
EOT
  "$BIN_DIR/mihomo" -d "$MD" -f "$MCFG" >"$MLOG" 2>&1 & pid=$!
  ready=0
  for _ in $(seq 1 80); do
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 50 "$MLOG" >&2 || true
      rm -rf "$MD" "$MCFG" "$MLOG"
      die 'MIERU-PREFLIGHT client exited before ready'
    fi
    if ss -H -ltn 'sport = :17994' 2>/dev/null | grep -q .; then ready=1; break; fi
    sleep .2
  done
  if (( ready == 0 )); then
    tail -n 50 "$MLOG" >&2 || true
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    rm -rf "$MD" "$MCFG" "$MLOG"
    die 'MIERU-PREFLIGHT did not open SOCKS listener'
  fi
  if ! socks_connect_test 17994 127.0.0.1 2443; then
    tail -n 50 "$MLOG" >&2 || true
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    rm -rf "$MD" "$MCFG" "$MLOG"
    die 'MIERU-PREFLIGHT tunneled XUDP backend failed'
  fi
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  rm -rf "$MD" "$MCFG" "$MLOG"
fi

stage complete
log "SUCCESS: $ROLE foreign passed carrier + loopback XUDP backend preflight"
echo "Bundle ready: $BUNDLE"
trap - ERR
