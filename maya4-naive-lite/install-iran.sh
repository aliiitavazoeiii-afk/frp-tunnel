#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$B/common.sh"
root_only
packages
mkdirs
install_xray
install_naive

FOREIGN_IP=''
read -r -p 'Maya4 foreign IPv4: ' FOREIGN_IP
valid_ipv4 "$FOREIGN_IP" || die 'valid foreign IPv4 required'

# 1 GiB VPS safety: create swap only when the machine effectively has none.
swap_kb=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)
if (( swap_kb < 262144 )); then
  log 'Low/no swap detected; creating 1 GiB /swapfile for 1 GiB VPS stability'
  if [[ ! -e /swapfile ]]; then
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile 2>/dev/null || true
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

XUI_REQUIRED_VERSION='2.9.4'

# Maya4 is pinned to 3X-UI v2.9.4. Never install "latest" and never upgrade
# an existing panel implicitly.
if ! [[ -x /usr/local/x-ui/x-ui ]] || ! systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
  log '3X-UI not found; installing exact pinned version v2.9.4'
  tmp=$(mktemp)
  curl -fsSL --retry 4 --connect-timeout 10 --max-time 60 \
    https://raw.githubusercontent.com/MHSanaei/3x-ui/v2.9.4/install.sh -o "$tmp"
  chmod 0700 "$tmp"
  bash "$tmp" v2.9.4
  rm -f "$tmp"
fi

XUI_ACTUAL_VERSION=$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]')
XUI_ACTUAL_VERSION=${XUI_ACTUAL_VERSION#v}
[[ "$XUI_ACTUAL_VERSION" == "$XUI_REQUIRED_VERSION" ]] || \
  die "Maya4 requires 3X-UI v$XUI_REQUIRED_VERSION exactly; found: ${XUI_ACTUAL_VERSION:-unknown}. No upgrade/downgrade was performed."

systemctl enable --now x-ui.service >/dev/null
systemctl is-active --quiet x-ui.service || die 'x-ui failed to start'
log "3X-UI version locked: v$XUI_ACTUAL_VERSION (installer will not upgrade it)"

SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new)
log 'Fetching private Maya4 bundle from foreign server'
tmp_bundle=$(mktemp /root/.maya4-bundle.XXXXXX.json)
scp "${SSH_OPTS[@]}" "root@$FOREIGN_IP:/root/maya4-naive-client.json" "$tmp_bundle" || {
  rm -f "$tmp_bundle"
  die 'could not fetch Maya4 foreign bundle'
}
chmod 0600 "$tmp_bundle"

jq -e --arg ip "$FOREIGN_IP" \
  '.version==1 and .kind=="maya4-naive" and .public_ip==$ip and .domain and .username and .password and .xudp_uuid' \
  "$tmp_bundle" >/dev/null || {
    rm -f "$tmp_bundle"
    die 'invalid Maya4 foreign bundle'
  }

ip=$(jq -r '.public_ip' "$tmp_bundle")
domain=$(jq -r '.domain' "$tmp_bundle")
user=$(jq -r '.username' "$tmp_bundle")
pass=$(jq -r '.password' "$tmp_bundle")
uuid=$(jq -r '.xudp_uuid' "$tmp_bundle")

CFG="$ROOT/naive.json" CFG_IP="$ip" CFG_DOMAIN="$domain" CFG_USER="$user" CFG_PASS="$pass" python3 <<'PY'
import json,os
obj={
  "listen":"socks://127.0.0.1:7995",
  "proxy":f"https://{os.environ['CFG_USER']}:{os.environ['CFG_PASS']}@{os.environ['CFG_DOMAIN']}",
  "host-resolver-rules":f"MAP {os.environ['CFG_DOMAIN']} {os.environ['CFG_IP']}"
}
with open(os.environ['CFG'],'w') as f: json.dump(obj,f,indent=2)
os.chmod(os.environ['CFG'],0o600)
PY

XCFG="$ROOT/xudp-router.json" XUUID="$uuid" python3 <<'PY'
import json,os
u=os.environ['XUUID']
obj={
 "log":{"loglevel":"warning"},
 "inbounds":[{
   "tag":"maya4-in",
   "listen":"127.0.0.1",
   "port":7996,
   "protocol":"socks",
   "settings":{"auth":"noauth","udp":True}
 }],
 "outbounds":[
   {
     "tag":"xudp-maya4",
     "protocol":"vless",
     "settings":{"address":"xudp-maya4.internal","port":2443,"id":u,"encryption":"none"},
     "streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier-maya4"}},
     "mux":{"enabled":True,"concurrency":-1,"xudpConcurrency":8,"xudpProxyUDP443":"allow"}
   },
   {
     "tag":"carrier-maya4",
     "protocol":"socks",
     "settings":{"address":"127.0.0.1","port":7995}
   }
 ],
 "routing":{"domainStrategy":"AsIs","rules":[
   {"type":"field","inboundTag":["maya4-in"],"network":"tcp","outboundTag":"carrier-maya4"},
   {"type":"field","inboundTag":["maya4-in"],"network":"udp","outboundTag":"xudp-maya4"}
 ]}
}
with open(os.environ['XCFG'],'w') as f: json.dump(obj,f,indent=2)
os.chmod(os.environ['XCFG'],0o600)
PY

"$BIN/xray" run -test -c "$ROOT/xudp-router.json" >/dev/null
install -m 0600 "$tmp_bundle" "$ROOT/bundle.json"
rm -f "$tmp_bundle"

cat > /etc/systemd/system/maya4-naive-client.service <<EOF
[Unit]
Description=Maya4 lightweight Naive client
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN/naive $ROOT/naive.json
Restart=always
RestartSec=2s
LimitNOFILE=262144
MemoryHigh=96M
MemoryMax=192M
Nice=5
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/maya4-xudp-router.service <<EOF
[Unit]
Description=Maya4 TCP + UDP/XUDP router
After=network-online.target maya4-naive-client.service
Wants=network-online.target
Requires=maya4-naive-client.service
[Service]
Type=simple
ExecStart=$BIN/xray run -c $ROOT/xudp-router.json
Restart=always
RestartSec=2s
LimitNOFILE=262144
MemoryHigh=160M
MemoryMax=320M
Nice=5
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF

systemd-analyze verify /etc/systemd/system/maya4-naive-client.service /etc/systemd/system/maya4-xudp-router.service >/dev/null
systemctl daemon-reload
systemctl enable --now maya4-naive-client.service maya4-xudp-router.service >/dev/null
sleep 4

install -m 0755 "$B/health.sh" /usr/local/sbin/maya4-health
install -m 0755 "$B/attach-xui.sh" /usr/local/sbin/maya4-attach
cat > /usr/local/bin/maya4 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-status}" in
  status|health) exec /usr/local/sbin/maya4-health ;;
  attach) exec /usr/local/sbin/maya4-attach ;;
  restart)
    systemctl restart maya4-naive-client.service maya4-xudp-router.service
    sleep 3
    exec /usr/local/sbin/maya4-health
    ;;
  *) echo 'usage: maya4 [status|health|attach|restart]' >&2; exit 2 ;;
esac
EOF
chmod 0755 /usr/local/bin/maya4

/usr/local/sbin/maya4-health || die 'Maya4 tunnel health failed after install'

log 'SUCCESS: Maya4 Iran base is ready'
echo
echo '3X-UI is installed and running.'
echo 'If this is a fresh panel, create your normal public inbound in 3X-UI first.'
echo 'Then route that inbound through Naive with: maya4 attach'
echo 'Health command: maya4 health'
echo '3X-UI menu: x-ui'
echo 'Do not paste /etc/maya4-naive/bundle.json into chat or a repository.'
