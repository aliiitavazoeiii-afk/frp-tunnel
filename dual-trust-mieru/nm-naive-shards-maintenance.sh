#!/usr/bin/env bash
# Gated two-client Naive sharding. Only the Naive-facing port :7993 is swapped.
set -Eeuo pipefail
umask 077
MODE=${1:-}
R=/etc/dual-trust-mieru/naive-shards
D=/var/lib/dual-trust-mieru/naive-shards
B=/usr/local/lib/dual-trust-mieru
O=/etc/systemd/system/nm-naive-client.service.d/90-naive-shards.conf
ORIG=/etc/dual-trust-mieru/naive-mieru/naive-live.json
PROTECTED=(x-ui dual-dispatcher dual-xudp-bridge dual-mieru-carrier)
log(){ echo "[NAIVE-SHARDS] $*"; }
die(){ echo "[NAIVE-SHARDS] ERROR: $*" >&2;exit 1; }
[[ $EUID -eq 0 ]] || die "root required"
exec 9>/run/naive-shards-maintenance.lock
flock -n 9 || die "another maintenance action is active"
[[ "$MODE" == stage || "$MODE" == cutover || "$MODE" == rollback || "$MODE" == status ]] || die "Usage: $0 {stage|cutover|rollback|status}"
alive(){ systemctl is-active --quiet "$1.service"; }
probe(){
  local port=$1 tries=$2 i n=0 rc status
  for ((i=0;i<tries;i++));do
    rc=0
    status=$(curl -q -4 -sS --socks5-hostname "127.0.0.1:$port" \
      --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' \
      'https://www.gstatic.com/generate_204' 2>/dev/null) || rc=$?
    [[ $rc == 0 && "$status" == 204 ]] && n=$((n+1))
    sleep 0.2
  done
  log "port :$port => $n/$tries"
  ((n==tries))
}
services(){
  local x
  for x in "${PROTECTED[@]}";do alive "$x" || die "protected service inactive: $x";done
}
pids(){
  local x
  for x in "${PROTECTED[@]}";do systemctl show "$x.service" -p MainPID --value;done
}
stage(){
  services
  alive nm-naive-client || die 'live Naive client inactive'
  [[ -f "$ORIG" && -x "$B/naive" && -x "$B/mihomo" ]] || die 'missing verified live files'
  [[ ! -e "$O" && ! -e "$R" ]] || die 'stage/override already exists; aborting'
  systemctl show nm-naive-client.service -p ExecStart --value | grep -Fq "$ORIG" || die 'unexpected live ExecStart'
  for p in 17993 17994 17995;do
    ! ss -H -ltn "sport = :$p" | grep -q . || die "port $p occupied"
  done
  probe 7994 2 || die 'Mieru unhealthy before stage'
  mkdir -p "$R" "$D/stage" "$D/live"
  chmod 0700 "$R" "$D" "$D/stage" "$D/live"
  SRC="$ORIG" OUT="$R" python3 <<'PY'
import json,os,pathlib
src=json.loads(pathlib.Path(os.environ["SRC"]).read_text())
assert src.get("listen")=="socks://127.0.0.1:7993"
assert src.get("proxy","").startswith("https://")
assert src.get("host-resolver-rules")
root=pathlib.Path(os.environ["OUT"])
for name,port in (("a",17993),("b",17994)):
    data={**src,"listen":f"socks://127.0.0.1:{port}"}
    f=root/f"shard-{name}.json"
    with f.open("x") as out:json.dump(data,out)
    f.chmod(0o600)
template="""mixed-port: PORT
bind-address: 127.0.0.1
allow-lan: false
mode: rule
log-level: warning
ipv6: false
proxies:
  - name: NAIVE-A
    type: socks5
    server: 127.0.0.1
    port: 17993
    udp: false
  - name: NAIVE-B
    type: socks5
    server: 127.0.0.1
    port: 17994
    udp: false
proxy-groups:
  - name: NAIVE-SHARDS
    type: load-balance
    strategy: round-robin
    proxies:
      - NAIVE-A
      - NAIVE-B
    url: https://www.gstatic.com/generate_204
    expected-status: 204
    interval: 30
    lazy: false
    timeout: 5000
    max-failed-times: 2
rules:
  - MATCH,NAIVE-SHARDS
"""
for filename,port in (("stage.yaml",17995),("live.yaml",7993)):
    f=root/filename
    with f.open("x") as out:out.write(template.replace("PORT",str(port)))
    f.chmod(0o600)
print("Secure local configs created; credentials not printed.")
PY
  "$B/mihomo" -t -d "$D/stage" -f "$R/stage.yaml" >/dev/null || die 'stage YAML invalid'
  "$B/mihomo" -t -d "$D/live" -f "$R/live.yaml" >/dev/null || die 'live YAML invalid'
  for x in a b;do
    cat >"/etc/systemd/system/nm-naive-shard-$x.service" <<EOF
[Unit]
Description=Naive independent backend $x
After=network-online.target
[Service]
Type=simple
ExecStart=$B/naive $R/shard-$x.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  done
  cat >/etc/systemd/system/nm-naive-staging-gw.service <<EOF
[Unit]
Description=Naive local isolated sharding trial
After=nm-naive-shard-a.service nm-naive-shard-b.service
[Service]
Type=simple
ExecStart=$B/mihomo -d $D/stage -f $R/stage.yaml
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  systemd-analyze verify /etc/systemd/system/nm-naive-shard-{a,b}.service /etc/systemd/system/nm-naive-staging-gw.service >/dev/null || die 'unit validation failed'
  systemctl daemon-reload
  systemctl enable --now nm-naive-shard-a.service nm-naive-shard-b.service nm-naive-staging-gw.service >/dev/null || die 'stage startup failed'
  sleep 2
  for x in nm-naive-shard-a nm-naive-shard-b nm-naive-staging-gw;do alive "$x" || die "$x inactive";done
  probe 17993 5 || die 'shard A failed; production untouched'
  probe 17994 5 || die 'shard B failed; production untouched'
  probe 17995 12 || die 'stage gateway failed; production untouched'
  probe 7994 2 || die 'Mieru baseline failed; production untouched'
  log "STAGE PASS: production services and ports unchanged."
}
restore(){
  [[ -e "$O" ]] && rm -f "$O"
  systemctl daemon-reload
  systemctl restart nm-naive-client.service
  alive nm-naive-client && probe 7993 3
}
cutover(){
  services
  alive nm-naive-client || die 'original live Naive is down'
  [[ ! -e "$O" && -s "$R/live.yaml" ]] || die 'no healthy stage or already cut over'
  systemctl show nm-naive-client.service -p ExecStart --value | grep -Fq "$ORIG" || die 'unknown ExecStart'
  for s in nm-naive-shard-a nm-naive-shard-b nm-naive-staging-gw;do alive "$s" || die "missing stage: $s";done
  probe 17993 4 || die 'shard A unhealthy'
  probe 17994 4 || die 'shard B unhealthy'
  probe 17995 8 || die 'staging gateway unhealthy'
  probe 7994 4 || die 'Mieru unhealthy; cutover blocked'
  "$B/mihomo" -t -d "$D/live" -f "$R/live.yaml" >/dev/null || die 'gateway config invalid'
  exec 8>/run/dual-trust-mieru-autoheal.lock
  flock -w 20 8 || die 'autoheal busy'
  local before
  before=$(pids)
  mkdir -p "$(dirname "$O")"
  local next="$O.tmp.$$"
  cat >"$next" <<EOF
[Service]
ExecStart=
ExecStart=$B/mihomo -d $D/live -f $R/live.yaml
EOF
  chmod 0600 "$next"
  mv "$next" "$O"
  systemctl daemon-reload
  log 'SWITCH: restarting Naive role ONLY; existing Naive flows may disconnect once.'
  if ! systemctl restart nm-naive-client.service ||
     ! alive nm-naive-client ||
     ! probe 7993 5 ||
     ! probe 7991 3 ||
     ! /usr/local/sbin/nm-health --full naive;then
    log 'Naive gateway unhealthy; automatic rollback to original client.'
    restore || log 'CRITICAL: Naive rollback failed; inspect systemctl status'
    die 'cutover postflight failed'
  fi
  [[ "$(pids)" == "$before" ]] || log 'WARNING: protected service PID changed externally'
  # Staging gateway is no longer needed after successful live takeover.
  systemctl disable --now nm-naive-staging-gw.service >/dev/null ||
    log 'WARNING: staging gateway remains on isolated :17995; production unaffected'
  log 'LIVE SUCCESS: two independent Naive clients load balanced behind original :7993'
  log 'Mieru, x-ui, production Dispatcher and shared XUDP bridge NOT restarted'
}
rollback(){
  [[ -f "$O" ]] || die 'sharding not currently active'
  exec 8>/run/dual-trust-mieru-autoheal.lock
  flock -w 20 8 || die 'autoheal busy'
  probe 7994 3 || die 'Mieru baseline unhealthy; rollback blocked'
  restore || die 'rollback failed; inspect nm-naive-client.service'
  log 'Original single Naive client restored; auxiliary sharding services remain isolated'
}
status(){
  local s
  for s in "${PROTECTED[@]}" nm-naive-client nm-naive-shard-a nm-naive-shard-b nm-naive-staging-gw;do
    echo "$s: $(systemctl is-active "$s.service" 2>/dev/null || true)"
  done
  if [[ -f "$O" ]];then echo "NAIVE_SHARDING=LIVE";else echo "NAIVE_SHARDING=STAGING_OR_OFF";fi
}
case "$MODE" in
  stage) stage;;
  cutover) cutover;;
  rollback) rollback;;
  status) status;;
esac
