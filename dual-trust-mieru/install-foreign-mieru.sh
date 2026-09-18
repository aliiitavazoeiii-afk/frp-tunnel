#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$B/common.sh"
require_root

STAGE=argument-parse
LAST_STAGE=argument-parse
stage(){ LAST_STAGE=$1; log "STAGE=$LAST_STAGE"; }
err_report(){
  local rc=$?
  printf 'ERROR: foreign Mieru installer failed: stage=%s line=%s command=%s rc=%s\n' \
    "$LAST_STAGE" "${BASH_LINENO[0]:-unknown}" "${BASH_COMMAND:-unknown}" "$rc" >&2
  return "$rc"
}
trap err_report ERR

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
stage preflight-clean-state
for x in "$D" "$BUNDLE" /etc/systemd/system/dual-xudp-mieru.service; do
  [[ ! -e "$x" ]] || die "existing Mieru dual-tunnel state found at $x; use a clean/dedicated test server or remove the prior install first"
done
for x in /etc/systemd/system/mita.service /lib/systemd/system/mita.service /usr/lib/systemd/system/mita.service; do
  [[ ! -e "$x" ]] || die "existing mita installation detected; v1 foreign installer requires a dedicated clean server"
done

MITA_INSTALLED=0
cleanup_install(){
  rc=$?
  trap - EXIT ERR
  if (( rc != 0 )); then
    log "Install failed at STAGE=$LAST_STAGE; removing partial dual Mieru services/config"
    systemctl disable --now dual-xudp-mieru.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/dual-xudp-mieru.service
    if (( MITA_INSTALLED )); then
      mita stop >/dev/null 2>&1 || true
      systemctl disable --now mita.service >/dev/null 2>&1 || true
      dpkg -P mita >/dev/null 2>&1 || dpkg -r mita >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$D"
    rm -f "$BUNDLE"
  fi
  exit "$rc"
}
trap cleanup_install EXIT

stage base-packages
install_base_packages
mkdirs

stage install-mita-package
install_mieru_deb server
MITA_INSTALLED=1
command -v mita >/dev/null || die "mita binary missing after package install"

stage install-xray
install_xray

stage generate-config
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
    "settings":{"users":[{"id":"$XUDP_UUID","email":"dual-mieru-xudp"}],"decryption":"none"},
    "streamSettings":{"network":"raw"}
  }],
  "outbounds":[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["xudp-in"],"outboundTag":"direct"}]}
}
EOF2
chmod 0600 "$D/xray.json"

stage validate-xray-config
"$BIN_DIR/xray" run -test -c "$D/xray.json"

stage install-xudp-service
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
systemd-analyze verify /etc/systemd/system/dual-xudp-mieru.service
systemctl daemon-reload
systemctl enable --now dual-xudp-mieru.service
sleep 1
systemctl is-active --quiet dual-xudp-mieru.service || { journalctl -u dual-xudp-mieru -n 100 --no-pager >&2 || true; die "dual-xudp-mieru inactive"; }
ss -H -ltn 'sport = :2443' | grep -q '127.0.0.1:2443' || die "XUDP loopback :2443 missing"

stage wait-mita-control
systemctl enable --now mita
for _ in $(seq 1 50); do mita status >/dev/null 2>&1 && break; sleep 0.2; done
mita status || die "mita daemon control socket unavailable"

stage apply-mita-config
log "Applying Mieru server config"
mita apply config "$D/mita-server.json"

stage start-mita-proxy
mita stop >/dev/null 2>&1 || true
mita start
sleep 2
mita status | grep -q 'RUNNING' || { mita status >&2 || true; journalctl -u mita -n 100 --no-pager >&2 || true; die "mita proxy is not RUNNING"; }

stage firewall-and-listeners
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "$P1:$P2/tcp" comment 'dual-mieru' >/dev/null
fi
ss -H -ltn "sport = :$P1" | grep -q . || die "Mieru first TCP port $P1 missing"
ss -H -ltn "sport = :$P2" | grep -q . || die "Mieru last TCP port $P2 missing"

stage write-client-bundle
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
stage complete
log "SUCCESS: Mieru foreign is healthy on TCP/$PORT_RANGE"
log "Client bundle: $BUNDLE (0600; do not paste into chat/repo)"
log "Bundle SHA256: $(sha256sum "$BUNDLE" | awk '{print $1}')"
trap - EXIT ERR
