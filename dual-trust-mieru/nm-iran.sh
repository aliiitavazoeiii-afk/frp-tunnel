#!/usr/bin/env bash
# Naive-Mieru staged migration: no restart of Mieru, dispatcher, bridge or x-ui.
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$B/lane3-common.sh"
l3_root
D=/etc/dual-trust-mieru/naive-mieru
IR=/etc/dual-trust-mieru/iran
BIN=/usr/local/lib/dual-trust-mieru
STATE=/var/lib/dual-trust-mieru/naive-mieru
BUNDLE="$D/bundle.json"
MODE=${1:-}
mkdir -p "$D" "$STATE"; chmod 0700 "$D" "$STATE"
exec 9>/run/naive-mieru-migration.lock
flock -n 9 || l3_die 'another migration operation is already running'
log(){ printf '[NM] %s\n' "$*"; }
require_live(){
  for svc in x-ui dual-dispatcher dual-xudp-bridge dual-mieru-carrier; do
    systemctl is-active --quiet "$svc.service" || l3_die "protected service inactive: $svc"
  done
  [[ -s "$IR/xudp.json" && -s "$IR/dispatcher.yaml" ]] || l3_die 'existing Dual stack missing'
  jq -e '
    any(.inbounds[]; .tag=="trust-in" and .port==7991) and
    any(.outbounds[]; .tag=="carrier-trust" and .settings.port==7993) and
    any(.outbounds[]; .tag=="xudp-trust" and (.settings.address=="xudp-trust.internal" or .settings.address=="127.0.0.1") and .settings.port==2443 and .streamSettings.sockopt.dialerProxy=="carrier-trust") and
    any(.outbounds[]; .tag=="carrier-mieru" and .settings.port==7994)
  ' "$IR/xudp.json" >/dev/null || l3_die 'XUDP bridge is not the verified split architecture; refusing'
  grep -q '      - XUDP-TRUST' "$IR/dispatcher.yaml" || l3_die 'legacy dispatcher alias absent'
  grep -q '      - XUDP-MIERU' "$IR/dispatcher.yaml" || l3_die 'Mieru pool member absent'
  ! grep -q '      - XUDP-NAIVE' "$IR/dispatcher.yaml" || l3_die 'Triple dispatcher detected'
}
probe(){
  local port=$1 url=${2:-https://www.gstatic.com/generate_204} allowed=${3:-204} result
  result=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" \
    --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
  [[ "$result" == "$allowed" ]]
}
full_health(){
  local direct=$1 path=$2 i good=0
  probe "$direct" || { log "direct :$direct HTTP FAILED"; return 1; }
  probe "$path" || { log "split :$path HTTP FAILED"; return 1; }
  # Exactly one HTTP request per attempt. The prior implementation tried
  # separate HTTP requests for each acceptable status, causing up to 9 requests,
  # unnecessary load and misleading intermittent-failure diagnostics.
  local tg_code tg_rc
  for i in 1 2 3; do
    tg_rc=0
    tg_code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$path" \
      --connect-timeout 5 --max-time 12 -o /dev/null \
      -w '%{http_code}' https://api.telegram.org/ 2>/dev/null) || tg_rc=$?
    if [[ "$tg_rc" -eq 0 && "$tg_code" =~ ^(200|301|302)$ ]]; then
      good=$((good+1))
      log "Telegram HTTPS attempt $i/3: OK HTTP=$tg_code"
    else
      log "Telegram HTTPS attempt $i/3: FAIL curl_rc=$tg_rc HTTP=${tg_code:-000}"
    fi
  done
  (( good >= 2 )) || { log "Telegram HTTPS synthetic FAILED ($good/3)"; return 1; }
  local telegram_ok=$good
  good=0
  for i in 1 2 3; do l3_udp "$path" && good=$((good+1)) || true; done
  (( good >= 2 )) || { log "XUDP DNS FAILED ($good/3)"; return 1; }
  log "HEALTH PASS direct:$direct path:$path Telegram:$telegram_ok UDP/XUDP:$good"
}
protected_pids(){
  for svc in x-ui dual-dispatcher dual-xudp-bridge dual-mieru-carrier; do
    printf '%s %s\n' "$svc" "$(systemctl show -p MainPID --value "$svc.service")"
  done
}
validate_bundle(){
  local f=$1
  jq -e '.version==1 and .kind=="lane3-naive" and (.public_ip|type=="string") and (.domain|type=="string") and .port==443 and (.username|type=="string") and (.password|type=="string") and (.xudp_uuid|type=="string")' "$f" >/dev/null || l3_die 'invalid Naive foreign bundle'
  local live new
  live=$(jq -r '.outbounds[] | select(.tag=="xudp-trust") | .settings.id' "$IR/xudp.json")
  new=$(jq -r '.xudp_uuid' "$f")
  [[ "$live" =~ ^[0-9a-fA-F-]{36}$ && "$new" == "$live" ]] ||
    l3_die 'foreign XUDP UUID MUST match live former Trust role; do not overwrite Mieru UUID'
}
write_candidate(){
  local f=$1
  BUNDLE_SOURCE="$f" ROOT="$D" python3 <<'PY'
import json,os,pathlib
b=json.load(open(os.environ['BUNDLE_SOURCE']))
root=pathlib.Path(os.environ['ROOT'])
c={
 "listen":"socks://127.0.0.1:17993",
 "proxy":f"https://{b['username']}:{b['password']}@{b['domain']}",
 "host-resolver-rules":f"MAP {b['domain']} {b['public_ip']}"
}
(root/'naive-candidate.json').write_text(json.dumps(c,indent=2)+'\n')
u=b['xudp_uuid']
live=json.load(open('/etc/dual-trust-mieru/iran/xudp.json'))
legacy=[z for z in live['outbounds'] if z.get('tag')=='xudp-trust']
if len(legacy)!=1: raise RuntimeError('unrecognized legacy XUDP leg')
target=legacy[0]['settings']['address']
if target not in ('127.0.0.1','xudp-trust.internal'):
 raise RuntimeError('unexpected legacy XUDP address: refusing to synthesize candidate')
x={
 "log":{"loglevel":"warning"},
 "inbounds":[{"tag":"nm-candidate-in","listen":"127.0.0.1","port":17991,
              "protocol":"socks","settings":{"auth":"noauth","udp":True}}],
 "outbounds":[
   {"tag":"xudp-nm","protocol":"vless",
    "settings":{"address":target,"port":2443,"id":u,"encryption":"none"},
    "streamSettings":{"network":"raw","sockopt":{"dialerProxy":"nm-direct"}},
    "mux":{"enabled":True,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
   {"tag":"nm-direct","protocol":"socks","settings":{"address":"127.0.0.1","port":17993}}
 ],
 "routing":{"domainStrategy":"AsIs","rules":[
   {"type":"field","inboundTag":["nm-candidate-in"],"network":"tcp","outboundTag":"nm-direct"},
   {"type":"field","inboundTag":["nm-candidate-in"],"network":"udp","outboundTag":"xudp-nm"}]}
}
(root/'xudp-candidate.json').write_text(json.dumps(x,indent=2)+'\n')
(root/'naive-live.json').write_text(json.dumps({**c,"listen":"socks://127.0.0.1:7993"},indent=2)+'\n')
for p in root.glob('*.json'): p.chmod(0o600)
PY
  "$BIN/xray" run -test -c "$D/xudp-candidate.json" >/dev/null
}
prepare(){
  require_live
  local src=${2:-/root/lane3-naive-client.json}
  [[ -s "$src" ]] || l3_die "secure bundle missing: $src; SCP it directly from NEW foreign server"
  validate_bundle "$src"
  for port in 17993 17991; do
    if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
      l3_die "candidate port $port already occupied; check for previous candidate install"
    fi
  done
  log 'Downloading SHA256-verified, security-pinned NaiveProxy; no apt/package changes.'
  local arch digest suffix tmp
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) suffix=linux-x64; digest=80214dfea1767f6ecf63a3a79dc9f48b203460f51abc609357fff48dd5844c7d ;;
    aarch64|arm64) suffix=linux-arm64; digest=8f4d917fa39a5d8cf1c17fc12ffd99ba84c015b62b43461d09cc074ca4114d8d ;;
    *) l3_die "unsupported architecture: $arch" ;;
  esac
  local tag=v154.0.8037.49-5
  local target="$BIN/naive-$tag"
  if [[ ! -x "$target" ]]; then
    for cmd in curl sha256sum tar xz; do command -v "$cmd" >/dev/null || l3_die "missing $cmd; install manually, cannot modify live packages"; done
    tmp=$(mktemp -d /root/.nm-naive.XXXXXXXX)
    curl -fL --retry 3 --connect-timeout 10 --max-time 180 \
      "https://github.com/klzgrad/naiveproxy/releases/download/$tag/naiveproxy-$tag-$suffix.tar.xz" \
      -o "$tmp/naive.tar.xz"
    echo "$digest  $tmp/naive.tar.xz" | sha256sum -c - >/dev/null || l3_die 'SECURITY: NaiveProxy binary digest mismatch'
    mkdir -p "$tmp/unpacked"
    tar -xJf "$tmp/naive.tar.xz" -C "$tmp/unpacked"
    local found
    found=$(find "$tmp/unpacked" -type f -name naive | head -n 1)
    [[ -n "$found" ]] || l3_die 'naive binary missing from verified archive'
    install -m 0755 "$found" "$target"
    rm -rf "$tmp"
  fi
  ln -sfn "$target" "$BIN/naive"
  [[ -x "$BIN/xray" ]] || l3_die 'live Xray binary unavailable'
  install -m 0600 "$src" "$BUNDLE"
  write_candidate "$BUNDLE"
  cat >/etc/systemd/system/nm-naive-candidate.service <<EOF
[Unit]
Description=Isolated Naive candidate, outside user pool
After=network-online.target
[Service]
Type=simple
ExecStart=$BIN/naive $D/naive-candidate.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/nm-xudp-candidate.service <<EOF
[Unit]
Description=Isolated XUDP candidate, outside user pool
After=nm-naive-candidate.service
[Service]
Type=simple
ExecStart=$BIN/xray run -c $D/xudp-candidate.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  systemd-analyze verify /etc/systemd/system/nm-*candidate.service >/dev/null
  systemctl daemon-reload
  systemctl start nm-naive-candidate.service nm-xudp-candidate.service
  sleep 3
  systemctl is-active --quiet nm-naive-candidate.service || l3_die 'Naive candidate failed'
  systemctl is-active --quiet nm-xudp-candidate.service || l3_die 'XUDP candidate failed'
  full_health 17993 17991 || l3_die 'foreign not healthy; Mieru and dispatcher remain untouched'
  log 'CANDIDATE PASS; ready for cutover. No current user route was modified.'
}
install_new_autoheal(){
  install -m 0755 "$B/nm-autoheal.sh" /usr/local/sbin/dual-tunnel-autoheal
}
restore_alias_cli(){
  for f in dual dual-manager dual-health; do
    local dst
    if [[ "$f" == dual ]]; then dst=/usr/local/bin/dual; else dst=/usr/local/sbin/"$f"; fi
    [[ -f "$dst" && ! -f "$STATE/orig-$f" ]] && cp -a "$dst" "$STATE/orig-$f" || true
  done
  install -m 0755 "$B/nm-cli.sh" /usr/local/bin/dual
  install -m 0755 "$B/nm-cli.sh" /usr/local/sbin/dual-manager
  install -m 0755 "$B/nm-health.sh" /usr/local/sbin/dual-health
  install -m 0755 "$B/nm-health.sh" /usr/local/sbin/nm-health
  install -m 0755 "$B/nm-pool-balance.py" /usr/local/sbin/nm-pool-balance
}
cutover(){
  require_live
  [[ -s "$BUNDLE" && -s "$D/naive-live.json" ]] || l3_die 'run prepare first'
  validate_bundle "$BUNDLE"
  systemctl is-active --quiet nm-naive-candidate.service || l3_die 'candidate inactive'
  systemctl is-active --quiet nm-xudp-candidate.service || l3_die 'candidate router inactive'
  full_health 17993 17991 || l3_die 'candidate degraded; cutover REFUSED'
  probe 7994 && probe 7992 || l3_die 'Mieru is degraded; do not touch'
  l3_udp 7992 || l3_die 'Mieru XUDP unhealthy'
  local before
  before=$(protected_pids)
  # Keep legacy autoheal from resurrecting the broken Trust client.
  exec 8>/run/dual-trust-mieru-autoheal.lock
  flock -w 25 8 || l3_die 'autoheal busy; aborting cutover'
  [[ -f "$STATE/orig-autoheal" ]] ||
    cp -a /usr/local/sbin/dual-tunnel-autoheal "$STATE/orig-autoheal"
  install_new_autoheal
  cat >/etc/systemd/system/nm-naive-client.service <<EOF
[Unit]
Description=Naive carrier replacing failed Trust on loopback port 7993
After=network-online.target
[Service]
Type=simple
ExecStart=$BIN/naive $D/naive-live.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  systemd-analyze verify /etc/systemd/system/nm-naive-client.service >/dev/null
  systemctl daemon-reload
  log 'Stopping ONLY the already-broken Trust client; Mieru stays active.'
  systemctl stop dual-trust-client.service
  if ! systemctl start nm-naive-client.service; then
    systemctl start dual-trust-client.service || true
    cp -a "$STATE/orig-autoheal" /usr/local/sbin/dual-tunnel-autoheal || true
    l3_die 'Naive could not start; Trust restored; Mieru untouched'
  fi
  sleep 3
  if ! full_health 7993 7991; then
    log 'ROLLBACK Naive port swap, restoring former Trust service'
    systemctl stop nm-naive-client.service || true
    systemctl start dual-trust-client.service || true
    cp -a "$STATE/orig-autoheal" /usr/local/sbin/dual-tunnel-autoheal || true
    l3_die 'candidate was healthy but live path failed. Mieru untouched.'
  fi
  # Persist the proven new carrier BEFORE later observability assertions;
  # even if an external service unexpectedly changes, reboot must not resurrect Trust.
  systemctl disable dual-trust-client.service >/dev/null
  systemctl enable nm-naive-client.service >/dev/null
  local after
  after=$(protected_pids)
  [[ "$before" == "$after" ]] || l3_die 'CRITICAL: protected service PID changed; inspect runtime'
  probe 7994 && probe 7992 || l3_die 'CRITICAL: Mieru degraded after cutover; inspect immediately'
  systemctl stop nm-naive-candidate.service nm-xudp-candidate.service
  restore_alias_cli
  date -Is > "$STATE/live-cutover.timestamp"
  log "Naive becomes eligible for new traffic after the unchanged dispatcher next successful health check."
  log 'SUCCESS: Naive active in legacy Trust socket :7993 / split :7991.'
  log 'Mieru, x-ui, dispatcher and shared XUDP bridge PIDs unchanged.'
  log 'POOL remains STICKY with legacy internal XUDP-TRUST alias until gated rebalance.'
  log 'The old foreign Trust VPS is NOT deleted; retire separately after soak verification.'
}
diagnose(){
  require_live
  log "Read-only candidate diagnostics; no services restarted or configurations reloaded"
  for svc in nm-naive-candidate nm-xudp-candidate dual-mieru-carrier; do
    printf "%-26s %s\n" "$svc" "$(systemctl is-active "$svc.service" 2>/dev/null || true)"
  done
  for port in 17993 17991 7992; do
    echo "--- SOCKS :$port ---"
    for url in https://www.gstatic.com/generate_204 https://api.telegram.org/; do
      for i in 1 2 3; do
        local out rc=0
        out=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" \
          --connect-timeout 5 --max-time 12 -o /dev/null \
          -w "HTTP=%{http_code} total=%{time_total}s" "$url" 2>/dev/null) || rc=$?
        printf "try=%s url=%s curl_rc=%s %s\n" "$i" "$url" "$rc" "$out"
      done
    done
  done
  for port in 17991 7992; do
    local ok=0
    for i in 1 2 3; do
      if l3_udp "$port"; then ok=$((ok+1)); fi
    done
    printf "XUDP role=:%s success=%s/3\n" "$port" "$ok"
  done
}
case "$MODE" in
  prepare) prepare "$@" ;;
  diagnose) diagnose ;;
  cutover) cutover ;;
  status) exec bash "$B/nm-cli.sh" status ;;
  *) echo "usage: $0 prepare [foreign-bundle.json] | diagnose | cutover | status" >&2; exit 2 ;;
esac
