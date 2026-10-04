#!/usr/bin/env bash
set -Eeuo pipefail
LIB=/usr/local/lib/dual-trust-mieru-lane3
source "$LIB/lane3-common.sh"
l3_root
l3_mkdirs

ROUTE=/usr/local/sbin/lane3-xui-route
HEALTH=/usr/local/sbin/lane3-health
SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=600 -o ControlPath=/run/lane3-ssh-%C)

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'; else G='';R='';Y='';C='';B='';N=''; fi
pause(){ echo; read -r -p 'Press Enter to continue...' _; }
close_master(){ local ip=$1; ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true; }

banner(){
  clear 2>/dev/null || true
  printf '%b' "$C$B"
  echo '============================================================'
  echo '          MAYA3 MULTI-LANE TUNNEL MANAGER'
  echo '             Legacy + Lane 3 Naive'
  echo '                 power by ali tavazoei'
  echo '============================================================'
  printf '%b' "$N"
}

status(){
  local trust='-' mieru='-' l3='not configured' mode='all-legacy' s1='inactive' s2='inactive'
  [[ -s /etc/dual-trust-mieru/iran/trust-bundle.json ]] && trust=$(jq -r '.public_ip // "-"' /etc/dual-trust-mieru/iran/trust-bundle.json)
  [[ -s /etc/dual-trust-mieru/iran/mieru-bundle.json ]] && mieru=$(jq -r '.public_ip // "-"' /etc/dual-trust-mieru/iran/mieru-bundle.json)
  [[ -s "$L3_ROOT/bundle.json" ]] && l3=$(jq -r '.public_ip // "unknown"' "$L3_ROOT/bundle.json")
  [[ -s "$L3_ROOT/routing-mode" ]] && mode=$(<"$L3_ROOT/routing-mode")
  s1=$(systemctl is-active lane3-naive-client.service 2>/dev/null || true); [[ -n "$s1" ]] || s1=inactive
  s2=$(systemctl is-active lane3-xudp-router.service 2>/dev/null || true); [[ -n "$s2" ]] || s2=inactive
  printf '%-22s | %s\n' 'Legacy Trust foreign' "$trust"
  printf '%-22s | %s\n' 'Legacy Mieru foreign' "$mieru"
  printf '%-22s | %s\n' 'Lane 3 Naive foreign' "$l3"
  printf '%-22s | %s\n' 'Routing mode' "$mode"
  printf '%-22s | %s\n' 'Lane 3 Naive client' "$s1"
  printf '%-22s | %s\n' 'Lane 3 XUDP router' "$s2"
}

validate_bundle(){
  local f=$1 ip=${2:-}
  jq -e '.version==1 and .kind=="lane3-naive" and .public_ip and .domain and .port==443 and .cert_email and .username and .password and .xudp_uuid' "$f" >/dev/null || l3_die 'invalid Lane 3 bundle'
  [[ -z "$ip" || $(jq -r '.public_ip' "$f") == "$ip" ]] || l3_die 'bundle public IP mismatch'
}

write_local_configs(){
  local bundle=$1 ip domain user pass uuid
  ip=$(jq -r '.public_ip' "$bundle"); domain=$(jq -r '.domain' "$bundle"); user=$(jq -r '.username' "$bundle"); pass=$(jq -r '.password' "$bundle"); uuid=$(jq -r '.xudp_uuid' "$bundle")
  CFG="$L3_ROOT/naive.json" CFG_IP="$ip" CFG_DOMAIN="$domain" CFG_USER="$user" CFG_PASS="$pass" python3 <<'PY'
import json,os
o={
 "listen":"socks://127.0.0.1:7995",
 "proxy":f"https://{os.environ['CFG_USER']}:{os.environ['CFG_PASS']}@{os.environ['CFG_DOMAIN']}",
 "host-resolver-rules":f"MAP {os.environ['CFG_DOMAIN']} {os.environ['CFG_IP']}"
}
with open(os.environ['CFG'],'w') as f: json.dump(o,f,indent=2)
os.chmod(os.environ['CFG'],0o600)
PY
  XCFG="$L3_ROOT/xudp-router.json" XUUID="$uuid" python3 <<'PY'
import json,os
u=os.environ['XUUID']
o={
 "log":{"loglevel":"warning"},
 "inbounds":[{"tag":"lane3-in","listen":"127.0.0.1","port":7996,"protocol":"socks","settings":{"auth":"noauth","udp":True}}],
 "outbounds":[
   {"tag":"xudp-lane3","protocol":"vless","settings":{"address":"xudp-lane3.internal","port":2443,"id":u,"encryption":"none"},
    "streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier-lane3"}},
    "mux":{"enabled":True,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
   {"tag":"carrier-lane3","protocol":"socks","settings":{"address":"127.0.0.1","port":7995}}
 ],
 "routing":{"domainStrategy":"AsIs","rules":[
   {"type":"field","inboundTag":["lane3-in"],"network":"tcp","outboundTag":"carrier-lane3"},
   {"type":"field","inboundTag":["lane3-in"],"network":"udp","outboundTag":"xudp-lane3"}
 ]}
}
with open(os.environ['XCFG'],'w') as f: json.dump(o,f,indent=2)
os.chmod(os.environ['XCFG'],0o600)
PY
  "$L3_BIN/xray" run -test -c "$L3_ROOT/xudp-router.json" >/dev/null
}

install_units(){
  cat > /etc/systemd/system/lane3-naive-client.service <<EOF2
[Unit]
Description=Maya3 Lane 3 NaiveProxy carrier
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$L3_BIN/naive $L3_ROOT/naive.json
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
  cat > /etc/systemd/system/lane3-xudp-router.service <<EOF2
[Unit]
Description=Maya3 Lane 3 TCP direct + UDP XUDP router
After=network-online.target lane3-naive-client.service
Wants=network-online.target
Requires=lane3-naive-client.service
[Service]
Type=simple
ExecStart=$L3_BIN/xray run -c $L3_ROOT/xudp-router.json
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
  systemd-analyze verify /etc/systemd/system/lane3-naive-client.service /etc/systemd/system/lane3-xudp-router.service >/dev/null
  systemctl daemon-reload
}

first_import(){
  [[ ! -s "$L3_ROOT/bundle.json" ]] || { echo 'Lane 3 already configured; use Replace Lane 3 foreign.'; return 0; }
  l3_free_tcp "$L3_NAIVE_PORT" || l3_die "TCP/$L3_NAIVE_PORT already in use"
  l3_free_tcp "$L3_ENTRY_PORT" || l3_die "TCP/$L3_ENTRY_PORT already in use"
  local ip tmp
  read -r -p 'Lane 3 foreign IPv4: ' ip
  l3_valid_ipv4 "$ip" || l3_die 'invalid IPv4'
  echo 'Connecting to Lane 3 foreign. Root password should be requested once.'
  ssh "${SSH_OPTS[@]}" "root@$ip" 'echo LANE3-SSH=OK' || l3_die 'cannot SSH to Lane 3 foreign'
  tmp=$(mktemp /root/.lane3-bundle.XXXXXX.json)
  scp "${SSH_OPTS[@]}" "root@$ip:/root/lane3-naive-client.json" "$tmp" || { close_master "$ip"; rm -f "$tmp"; l3_die 'cannot fetch Lane 3 bundle'; }
  close_master "$ip"; chmod 0600 "$tmp"; validate_bundle "$tmp" "$ip"
  l3_install_naive
  [[ -x "$L3_BIN/xray" ]] || l3_die 'existing dual Xray binary missing'
  write_local_configs "$tmp"; install_units
  install -m 0600 "$tmp" "$L3_ROOT/bundle.json"; rm -f "$tmp"
  systemctl enable --now lane3-naive-client.service lane3-xudp-router.service >/dev/null
  sleep 4
  if "$HEALTH"; then
    echo; echo 'SUCCESS: Lane 3 imported. Existing Trust/Mieru and x-ui routing were untouched.'
  else
    systemctl disable --now lane3-xudp-router.service lane3-naive-client.service >/dev/null 2>&1 || true
    rm -f "$L3_ROOT/bundle.json"
    l3_die 'Lane 3 failed health; services were stopped and legacy users were untouched'
  fi
}

replace_foreign(){
  [[ -s "$L3_ROOT/bundle.json" ]] || { first_import; return; }
  local old new domain email uuid uuidfile tmp bk
  old=$(jq -r '.public_ip' "$L3_ROOT/bundle.json"); domain=$(jq -r '.domain' "$L3_ROOT/bundle.json")
  email=$(jq -r '.cert_email' "$L3_ROOT/bundle.json"); uuid=$(jq -r '.xudp_uuid' "$L3_ROOT/bundle.json")
  echo "Current Lane 3 foreign: $old"
  echo "Current Lane 3 domain : $domain"
  read -r -p 'New Lane 3 foreign IPv4: ' new
  l3_valid_ipv4 "$new" || l3_die 'invalid IPv4'
  [[ "$new" != "$old" ]] || l3_die 'new IP equals current IP'
  mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
  printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || { echo "Point $domain A record to $new first, then run this option again."; return 0; }

  echo 'Connecting to new foreign. Root password should be requested once.'
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-LANE3-SSH=OK' || l3_die 'cannot SSH to new foreign'
  uuidfile=$(mktemp /root/.lane3-uuid.XXXXXX); chmod 0600 "$uuidfile"; printf '%s\n' "$uuid" > "$uuidfile"
  scp "${SSH_OPTS[@]}" "$uuidfile" "root@$new:/root/lane3-live-uuid.txt"
  rm -f "$uuidfile"

  ssh "${SSH_OPTS[@]}" "root@$new" bash -s -- "$new" "$domain" "$email" "$L3_REPO" "$L3_BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git ca-certificates >/dev/null
rm -rf /opt/frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/frp-tunnel >/dev/null
cd /opt/frp-tunnel/dual-trust-mieru
bash install-foreign-lane3-naive.sh --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/lane3-live-uuid.txt --non-interactive
rm -f /root/lane3-live-uuid.txt
REMOTE

  tmp=$(mktemp /root/.lane3-new-bundle.XXXXXX.json)
  scp "${SSH_OPTS[@]}" "root@$new:/root/lane3-naive-client.json" "$tmp"
  close_master "$new"; chmod 0600 "$tmp"; validate_bundle "$tmp" "$new"
  [[ $(jq -r '.xudp_uuid' "$tmp") == "$uuid" ]] || { rm -f "$tmp"; l3_die 'replacement UUID mismatch'; }

  bk="$L3_STATE/backups/foreign-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$bk"; chmod 0700 "$bk"
  cp -a "$L3_ROOT/bundle.json" "$bk/bundle.json"; cp -a "$L3_ROOT/naive.json" "$bk/naive.json"
  rollback(){
    local rc=${1:-1}; trap - ERR INT TERM
    l3_log 'ROLLBACK: restoring previous Lane 3 foreign'
    cp -a "$bk/bundle.json" "$L3_ROOT/bundle.json"; cp -a "$bk/naive.json" "$L3_ROOT/naive.json"
    systemctl restart lane3-naive-client.service >/dev/null 2>&1 || true
    sleep 3; rm -f "$tmp"; exit "$rc"
  }
  trap 'rollback $?' ERR; trap 'rollback 130' INT; trap 'rollback 143' TERM
  write_local_configs "$tmp"
  install -m 0600 "$tmp" "$L3_ROOT/bundle.json"
  systemctl restart lane3-naive-client.service
  sleep 4
  "$HEALTH" || rollback 1
  trap - ERR INT TERM
  rm -f "$tmp"
  l3_log "SUCCESS: Lane 3 foreign replaced $old -> $new"
  l3_log "Old foreign was NOT deleted automatically. Backup: $bk"
}

assign(){
  local email
  read -r -p 'Exact x-ui user email to route via Lane 3: ' email
  "$ROUTE" assign "$email"
}
unassign(){
  local email
  read -r -p 'Exact x-ui user email to return to Legacy: ' email
  "$ROUTE" unassign "$email"
}
show_logs(){
  journalctl -u lane3-naive-client.service -u lane3-xudp-router.service --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|reset|failed' | tail -n 120 || true
}

while true; do
  banner; status; echo
  if [[ -s "$L3_ROOT/bundle.json" ]]; then echo '  1) Replace Lane 3 foreign server'; else echo '  1) Import first Lane 3 foreign server'; fi
  echo '  2) Full Lane 3 health check'
  echo '  3) SPLIT mode: L3-* + assigned users -> Lane 3'
  echo '  4) Assign existing user -> Lane 3'
  echo '  5) Return assigned user -> Legacy'
  echo '  6) Route ALL users -> Lane 3'
  echo '  7) Route ALL users -> Legacy'
  echo '  8) List users and effective route'
  echo '  9) Recent Lane 3 warnings/errors'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c; echo
  case "$c" in
    1) if [[ -s "$L3_ROOT/bundle.json" ]]; then replace_foreign; else first_import; fi ;;
    2) "$HEALTH" || true ;;
    3) "$ROUTE" apply split ;;
    4) assign ;;
    5) unassign ;;
    6) "$ROUTE" apply all-lane3 ;;
    7) "$ROUTE" apply all-legacy ;;
    8) "$ROUTE" list ;;
    9) show_logs ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  pause
done
