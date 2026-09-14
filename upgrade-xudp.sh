#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="anytls-tunnel"
BRIDGE_SERVICE="anytls-xudp-bridge"
CONFIG_DIR="/etc/${PROJECT_NAME}"
STATE_DIR="/var/lib/${PROJECT_NAME}"
BIN_DIR="/usr/local/lib/${PROJECT_NAME}"
XRAY_VERSION="v26.3.27"
XRAY_BIN="${BIN_DIR}/xray-${XRAY_VERSION}"
BRIDGE_CONFIG="${CONFIG_DIR}/xudp-bridge.json"
BRIDGE_UNIT="/etc/systemd/system/${BRIDGE_SERVICE}.service"
XUI_DB="/etc/x-ui/x-ui.db"
XUI_RUNTIME="/usr/local/x-ui/bin/config.json"
XUDP_UUID="${XUDP_UUID:-503f2cf6-608f-4f76-9f7e-17721dde09cf}"
XUDP_SERVER_PORT="${XUDP_SERVER_PORT:-2443}"
XUDP_SOCKS_PORT="${XUDP_SOCKS_PORT:-7891}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
ROLE="${1:-}"
if [[ -z "$ROLE" && -f "$CONFIG_DIR/role" ]]; then ROLE=$(tr -d '[:space:]' < "$CONFIG_DIR/role"); fi
[[ "$ROLE" == "foreign-a" || "$ROLE" == "foreign-b" || "$ROLE" == "iran" ]] || die "usage: sudo bash upgrade-xudp.sh foreign-a|foreign-b|iran"
[[ -f "$CONFIG_DIR/deploy.env" ]] || die "missing $CONFIG_DIR/deploy.env; install AnyTLS first"
# shellcheck disable=SC1090
source "$CONFIG_DIR/deploy.env"

valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_port "$XUDP_SERVER_PORT" || die "invalid XUDP_SERVER_PORT"
valid_port "$XUDP_SOCKS_PORT" || die "invalid XUDP_SOCKS_PORT"
[[ "$XUDP_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "invalid XUDP_UUID"

if [[ "$ROLE" == "iran" ]]; then
  [[ -n "${LOCAL_SOCKS_PORT:-}" ]] || die "LOCAL_SOCKS_PORT missing in deploy.env"
  valid_port "$LOCAL_SOCKS_PORT" || die "invalid LOCAL_SOCKS_PORT"
  [[ -f "$XUI_DB" ]] || die "x-ui DB not found: $XUI_DB"
  systemctl cat x-ui.service >/dev/null 2>&1 || die "x-ui.service not found"
fi

install_packages(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl unzip jq python3 sqlite3 iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl unzip jq python3 sqlite iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl unzip jq python3 sqlite iproute
  else
    die "supported package manager not found"
  fi
}

install_xray(){
  local arch asset sha tmp zip url
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      asset="Xray-linux-64.zip"
      sha="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
      ;;
    aarch64|arm64)
      asset="Xray-linux-arm64-v8a.zip"
      sha="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"
      ;;
    *) die "unsupported architecture: $arch" ;;
  esac
  mkdir -p "$BIN_DIR"
  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" version | sed -n '1p'
    return
  fi
  tmp=$(mktemp -d)
  zip="$tmp/xray.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${asset}"
  log "Downloading pinned Xray ${XRAY_VERSION}"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 180 "$url" -o "$zip"
  echo "${sha}  ${zip}" | sha256sum -c - >/dev/null || die "Xray SHA256 mismatch"
  unzip -q "$zip" -d "$tmp/xray"
  install -m 0755 "$tmp/xray/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  "$XRAY_BIN" version | sed -n '1p'
}

port_busy_other(){
  local port=$1
  ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

backup_state(){
  local ts b
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  b="$STATE_DIR/backups/xudp-${ts}-${ROLE}"
  mkdir -p "$b"
  [[ -f "$BRIDGE_CONFIG" ]] && cp -a "$BRIDGE_CONFIG" "$b/xudp-bridge.json"
  [[ -f "$BRIDGE_UNIT" ]] && cp -a "$BRIDGE_UNIT" "$b/anytls-xudp-bridge.service"
  if [[ "$ROLE" == "iran" && -f "$XUI_DB" ]]; then cp -a "$XUI_DB" "$b/x-ui.db"; fi
  printf '%s\n' "$ROLE" > "$b/role"
  echo "$b"
}

write_bridge_config(){
  local out="${BRIDGE_CONFIG}.new"
  umask 077
  if [[ "$ROLE" == "iran" ]]; then
    cat > "$out" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "xudp-socks-in",
      "listen": "127.0.0.1",
      "port": ${XUDP_SOCKS_PORT},
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true, "ip": "127.0.0.1"}
    }
  ],
  "outbounds": [
    {
      "tag": "xudp-inner",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": ${XUDP_SERVER_PORT},
            "users": [
              {"id": "${XUDP_UUID}", "encryption": "none"}
            ]
          }
        ]
      },
      "streamSettings": {"network": "tcp", "security": "none"},
      "proxySettings": {"tag": "anytls-carrier", "transportLayer": true},
      "mux": {
        "enabled": true,
        "concurrency": -1,
        "xudpConcurrency": 16,
        "xudpProxyUDP443": "allow"
      },
      "targetStrategy": "AsIs"
    },
    {
      "tag": "anytls-carrier",
      "protocol": "socks",
      "settings": {"address": "127.0.0.1", "port": ${LOCAL_SOCKS_PORT}}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "inboundTag": ["xudp-socks-in"], "outboundTag": "xudp-inner"}
    ]
  }
}
JSON
  else
    cat > "$out" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "xudp-vless-in",
      "listen": "127.0.0.1",
      "port": ${XUDP_SERVER_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${XUDP_UUID}"}],
        "decryption": "none"
      },
      "streamSettings": {"network": "tcp", "security": "none"}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {}}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "inboundTag": ["xudp-vless-in"], "outboundTag": "direct"}
    ]
  }
}
JSON
  fi
  chmod 0600 "$out"
  log "Validating XUDP bridge configuration"
  "$XRAY_BIN" run -test -c "$out" >/dev/null || { rm -f "$out"; die "Xray bridge config validation failed"; }
  mv -f "$out" "$BRIDGE_CONFIG"
  chmod 0600 "$BRIDGE_CONFIG"
}

write_bridge_unit(){
  cat > "$BRIDGE_UNIT" <<UNIT
[Unit]
Description=AnyTLS XUDP Bridge (${ROLE})
After=network-online.target anytls-tunnel.service
Wants=network-online.target
Requires=anytls-tunnel.service

[Service]
Type=simple
ExecStartPre=${XRAY_BIN} run -test -c ${BRIDGE_CONFIG}
ExecStart=${XRAY_BIN} run -c ${BRIDGE_CONFIG}
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
UNIT
  systemd-analyze verify "$BRIDGE_UNIT" >/dev/null 2>&1 || die "systemd unit validation failed"
}

start_bridge(){
  systemctl daemon-reload
  systemctl enable "$BRIDGE_SERVICE" >/dev/null
  systemctl restart "$BRIDGE_SERVICE"
  sleep 2
  systemctl is-active --quiet "$BRIDGE_SERVICE" || {
    journalctl -u "$BRIDGE_SERVICE" -n 80 --no-pager >&2 || true
    die "XUDP bridge service failed"
  }
  if [[ "$ROLE" == "iran" ]]; then
    ss -H -ltn "sport = :${XUDP_SOCKS_PORT}" | grep -q . || die "XUDP SOCKS ${XUDP_SOCKS_PORT} is not listening"
  else
    ss -H -ltn "sport = :${XUDP_SERVER_PORT}" | grep -q . || die "XUDP endpoint ${XUDP_SERVER_PORT} is not listening"
  fi
}

test_tcp_bridge(){
  log "Testing TCP through XUDP bridge SOCKS ${XUDP_SOCKS_PORT}"
  local code
  code=$(curl -sS --socks5-hostname "127.0.0.1:${XUDP_SOCKS_PORT}" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
  [[ "$code" == "204" ]] || die "bridge TCP test failed (HTTP=${code:-none}); x-ui was NOT changed"
}

test_udp_bridge(){
  log "Testing UDP DNS round-trip through XUDP bridge"
  XUDP_SOCKS_PORT="$XUDP_SOCKS_PORT" python3 <<'PY'
import os, random, socket, struct, sys, time
host="127.0.0.1"; port=int(os.environ["XUDP_SOCKS_PORT"])

def recvn(s,n):
    b=b""
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError("SOCKS TCP closed")
        b+=x
    return b

tcp=socket.create_connection((host,port),timeout=5)
tcp.sendall(b"\x05\x01\x00")
if recvn(tcp,2)!=b"\x05\x00": raise RuntimeError("SOCKS auth failed")
tcp.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
ver,rep,rsv,atyp=recvn(tcp,4)
if rep: raise RuntimeError(f"UDP ASSOCIATE reply={rep}")
if atyp==1: relay=socket.inet_ntoa(recvn(tcp,4))
elif atyp==3: relay=recvn(tcp,recvn(tcp,1)[0]).decode()
elif atyp==4: relay=socket.inet_ntop(socket.AF_INET6,recvn(tcp,16))
else: raise RuntimeError("bad relay ATYP")
rport=struct.unpack("!H",recvn(tcp,2))[0]
if relay in ("0.0.0.0","::"): relay=host
qid=random.randrange(65536)
qname=b"".join(bytes([len(x)])+x.encode() for x in "youtube.com".split("."))+b"\0"
dns=struct.pack("!HHHHHH",qid,0x0100,1,0,0,0)+qname+struct.pack("!HH",1,1)
pkt=b"\0\0\0\1"+socket.inet_aton("1.1.1.1")+struct.pack("!H",53)+dns
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); udp.settimeout(7)
t=time.time(); udp.sendto(pkt,(relay,rport))
try: data,_=udp.recvfrom(65535)
except socket.timeout:
    print("UDP XUDP TEST = FAIL (timeout)"); sys.exit(2)
pos=4; ratyp=data[3]
if ratyp==1: pos+=4
elif ratyp==3: pos+=1+data[pos]
elif ratyp==4: pos+=16
else: print("UDP XUDP TEST = FAIL (bad ATYP)"); sys.exit(2)
pos+=2; reply=data[pos:]
if len(reply)<12: print("UDP XUDP TEST = FAIL (short DNS)"); sys.exit(2)
rid,flags=struct.unpack("!HH",reply[:4])
if rid!=qid or not (flags & 0x8000): print("UDP XUDP TEST = FAIL (invalid DNS)"); sys.exit(2)
print(f"UDP XUDP TEST = OK ({time.time()-t:.3f}s, rcode={flags & 0xF})")
PY
}

patch_xui(){
  local backup_db="$BACKUP_DIR/x-ui.db"
  [[ -f "$backup_db" ]] || cp -a "$XUI_DB" "$backup_db"
  log "Switching x-ui outbound anytls-tunnel from ${LOCAL_SOCKS_PORT} to ${XUDP_SOCKS_PORT}"
  systemctl stop x-ui
  XUDP_SOCKS_PORT="$XUDP_SOCKS_PORT" XUI_DB="$XUI_DB" python3 <<'PY'
import json, os, sqlite3
p=os.environ["XUI_DB"]; new_port=int(os.environ["XUDP_SOCKS_PORT"])
con=sqlite3.connect(p)
try:
    con.execute("BEGIN IMMEDIATE")
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row: raise RuntimeError("xrayTemplateConfig not found")
    cfg=json.loads(row[0]); found=0
    for ob in cfg.get("outbounds",[]):
        if ob.get("tag")!="anytls-tunnel": continue
        if ob.get("protocol")!="socks": raise RuntimeError("anytls-tunnel is not SOCKS")
        st=ob.setdefault("settings",{})
        if isinstance(st.get("servers"),list) and st["servers"]:
            st["servers"][0]["address"]="127.0.0.1"; st["servers"][0]["port"]=new_port
        else:
            st.clear(); st.update({"address":"127.0.0.1","port":new_port})
        ob["targetStrategy"]="AsIs"
        ob["mux"]={"enabled":False}
        found+=1
    if found!=1: raise RuntimeError(f"expected exactly one anytls-tunnel outbound, found {found}")
    con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",(json.dumps(cfg,separators=(",",":")),))
    con.commit()
finally:
    con.close()
PY
  if ! systemctl start x-ui; then
    cp -a "$backup_db" "$XUI_DB"
    systemctl start x-ui || true
    die "x-ui failed to start; DB restored"
  fi
  sleep 4
  if ! systemctl is-active --quiet x-ui; then
    cp -a "$backup_db" "$XUI_DB"
    systemctl restart x-ui || true
    die "x-ui inactive after patch; DB restored"
  fi
  local runtime_port
  runtime_port=$(jq -r '.outbounds[] | select(.tag=="anytls-tunnel") | (.settings.servers[0].port // .settings.port // empty)' "$XUI_RUNTIME" 2>/dev/null | head -n1 || true)
  if [[ "$runtime_port" != "$XUDP_SOCKS_PORT" ]]; then
    cp -a "$backup_db" "$XUI_DB"
    systemctl restart x-ui || true
    die "x-ui runtime did not switch to ${XUDP_SOCKS_PORT}; DB restored"
  fi
  ss -H -ltn "sport = :443" | grep -q . || {
    cp -a "$backup_db" "$XUI_DB"
    systemctl restart x-ui || true
    die "x-ui public TCP/443 listener missing after patch; DB restored"
  }
}

install_health_helper(){
  cat >/usr/local/sbin/anytls-xudp-health <<'EOFH'
#!/usr/bin/env bash
set -u
role=$(tr -d '[:space:]' </etc/anytls-tunnel/role 2>/dev/null || true)
echo "role=$role"
systemctl is-active --quiet anytls-tunnel && echo "AnyTLS: OK" || echo "AnyTLS: FAIL"
systemctl is-active --quiet anytls-xudp-bridge && echo "XUDP bridge: OK" || echo "XUDP bridge: FAIL"
if [[ "$role" == "iran" ]]; then
  curl -sS --socks5-hostname 127.0.0.1:7891 --connect-timeout 6 --max-time 15 -o /dev/null -w 'XUDP TCP path: HTTP=%{http_code}\n' https://www.gstatic.com/generate_204 || true
  echo "x-ui outbound:"
  jq -r '.outbounds[] | select(.tag=="anytls-tunnel") | "  tag=\(.tag) port=\(.settings.servers[0].port // .settings.port // "?") targetStrategy=\(.targetStrategy // "?")"' /usr/local/x-ui/bin/config.json 2>/dev/null || true
fi
EOFH
  chmod 0755 /usr/local/sbin/anytls-xudp-health
}

log "Installing dependencies"
install_packages
log "Installing pinned Xray"
install_xray
mkdir -p "$STATE_DIR/backups"
BACKUP_DIR=$(backup_state)
log "Backup snapshot: $BACKUP_DIR"

if [[ "$ROLE" == "iran" ]]; then
  if [[ "$XUDP_SOCKS_PORT" == "$LOCAL_SOCKS_PORT" ]]; then die "XUDP_SOCKS_PORT must differ from Mihomo SOCKS port"; fi
  if port_busy_other "$XUDP_SOCKS_PORT" && ! systemctl is-active --quiet "$BRIDGE_SERVICE" 2>/dev/null; then
    ss -ltnp "sport = :${XUDP_SOCKS_PORT}" || true
    die "TCP/${XUDP_SOCKS_PORT} already in use"
  fi
else
  if port_busy_other "$XUDP_SERVER_PORT" && ! systemctl is-active --quiet "$BRIDGE_SERVICE" 2>/dev/null; then
    ss -ltnp "sport = :${XUDP_SERVER_PORT}" || true
    die "TCP/${XUDP_SERVER_PORT} already in use"
  fi
fi

write_bridge_config
write_bridge_unit
start_bridge
install_health_helper

if [[ "$ROLE" == "iran" ]]; then
  test_tcp_bridge
  test_udp_bridge
  patch_xui
  log "SUCCESS: XUDP bridge active; x-ui now sends to SOCKS5 127.0.0.1:${XUDP_SOCKS_PORT}"
  log "Run: sudo anytls-xudp-health"
  log "Then disconnect/reconnect the client and test YouTube/Shorts."
else
  log "SUCCESS: Foreign XUDP endpoint active on loopback 127.0.0.1:${XUDP_SERVER_PORT}"
  log "No public firewall port was added."
fi
