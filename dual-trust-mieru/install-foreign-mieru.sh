#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$B/common.sh"
require_root

PUBLIC_IP=""; PORT_RANGE="20000-20020"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-ip) PUBLIC_IP=${2:-}; shift 2 ;;
    --port-range) PORT_RANGE=${2:-}; shift 2 ;;
    *) die "usage: $0 --public-ip IP [--port-range 20000-20020]" ;;
  esac
done
[[ "$PUBLIC_IP" =~ ^[0-9a-fA-F:.]+$ ]] || die "invalid --public-ip"
[[ "$PORT_RANGE" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]] || die "invalid --port-range"
P1=${BASH_REMATCH[1]}; P2=${BASH_REMATCH[2]}
(( P1 >= 1025 && P2 <= 65535 && P1 <= P2 && P2-P1 <= 200 )) || die "port range must be 1025..65535 and at most 201 ports"

D="$CONFIG_DIR/mieru"
BUNDLE=/root/dual-mieru-client.json
for x in "$D" "$BUNDLE" /etc/systemd/system/dual-xudp-mieru.service; do
  [[ ! -e "$x" ]] || die "existing Mieru dual-tunnel state found at $x; use a clean/dedicated test server or remove the prior install first"
done
for x in /etc/systemd/system/mita.service /lib/systemd/system/mita.service /usr/lib/systemd/system/mita.service; do
  [[ ! -e "$x" ]] || die "existing mita installation detected; v1 foreign installer requires a dedicated clean server"
done

MITA_INSTALLED=0
cleanup_install(){
  rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    log "Install failed; removing partial dual Mieru services/config"
    systemctl disable --now dual-xudp-mieru.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/dual-xudp-mieru.service
    if (( MITA_INSTALLED )); then
      mita stop >/dev/null 2>&1 || true
      systemctl disable --now mita.service >/dev/null 2>&1 || true
      dpkg -r mita >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$D"
    rm -f "$BUNDLE"
  fi
  exit "$rc"
}
trap cleanup_install EXIT

install_base_packages
mkdirs
install_mieru_deb server
MITA_INSTALLED=1
install_xray

mkdir -p "$D"; chmod 0700 "$D"
if command -v timedatectl >/dev/null 2>&1; then
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  [[ "$sync" == true ]] || log "WARNING: NTP synchronization is not reported active; Mieru requires client/server clocks to be close"
fi
USER_NAME="dtm-$(openssl rand -hex 4)"
USER_PASS=$(openssl rand -hex 32)
XUDP_UUID=$(json_uuid)

cat > "$D/mita-server.json" <<EOF2
{
  "portBindings":[{"portRange":"$PORT_RANGE","protocol":"TCP"}],
  "users":[{"name":"$USER_NAME","password":"$USER_PASS","allowPrivateIP":true,"allowLoopbackIP":true}],
  "loggingLevel":"INFO",
  "dns":{"dualStack":"PREFER_IPv4"},
  "advancedSettings":{"userHintIsMandatory":true}
}
EOF2
chmod 0600 "$D/mita-server.json"

cat > "$D/xray.json" <<EOF2
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "tag":"xudp-in","listen":"127.0.0.1","port":2443,"protocol":"vless",
    "settings":{"clients":[{"id":"$XUDP_UUID","email":"dual-mieru-xudp"}],"decryption":"none"},
    "streamSettings":{"network":"raw"}
  }],
  "outbounds":[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["xudp-in"],"outboundTag":"direct"}]}
}
EOF2
chmod 0600 "$D/xray.json"
"$BIN_DIR/xray" run -test -c "$D/xray.json" >/dev/null

cat > /etc/systemd/system/dual-xudp-mieru.service <<EOF2
[Unit]
Description=Dual Trust/Mieru XUDP endpoint (Mieru foreign)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN_DIR/xray run -c $D/xray.json
Restart=always
RestartSec=2s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2
systemd-analyze verify /etc/systemd/system/dual-xudp-mieru.service >/dev/null
systemctl daemon-reload
systemctl enable --now dual-xudp-mieru.service >/dev/null
sleep 1
systemctl is-active --quiet dual-xudp-mieru.service || die "dual-xudp-mieru inactive"
ss -H -ltn 'sport = :2443' | grep -q '127.0.0.1:2443' || die "XUDP loopback :2443 missing"

# The official package ships a persistent mita daemon. Apply configuration via
# its control socket; plaintext password is not kept in mita's protobuf store.
systemctl enable --now mita >/dev/null
for _ in $(seq 1 50); do mita status >/dev/null 2>&1 && break; sleep 0.2; done
mita status >/dev/null 2>&1 || die "mita daemon control socket unavailable"
log "Applying Mieru server config"
mita apply config "$D/mita-server.json" >/dev/null
mita stop >/dev/null 2>&1 || true
mita start >/dev/null
sleep 2
mita status | grep -q 'RUNNING' || { mita status >&2 || true; journalctl -u mita -n 100 --no-pager >&2 || true; die "mita proxy is not RUNNING"; }

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "$P1:$P2/tcp" comment 'dual-mieru' >/dev/null
fi
ss -H -ltn "sport = :$P1" | grep -q . || die "Mieru first TCP port $P1 missing"
ss -H -ltn "sport = :$P2" | grep -q . || die "Mieru last TCP port $P2 missing"

export PUBLIC_IP PORT_RANGE USER_NAME USER_PASS XUDP_UUID
python3 - "$BUNDLE" <<'PY'
import json,os,sys
p=sys.argv[1]; e=os.environ
obj={"version":1,"kind":"mieru","public_ip":e["PUBLIC_IP"],"port_range":e["PORT_RANGE"],
     "username":e["USER_NAME"],"password":e["USER_PASS"],"xudp_uuid":e["XUDP_UUID"]}
with open(p,'w') as f: json.dump(obj,f,indent=2,sort_keys=True)
os.chmod(p,0o600)
PY
unset USER_PASS XUDP_UUID
log "SUCCESS: Mieru foreign is healthy on TCP/$PORT_RANGE"
log "Client bundle: $BUNDLE (0600; do not paste into chat/repo)"
log "Bundle SHA256: $(sha256sum "$BUNDLE" | awk '{print $1}')"
trap - EXIT
