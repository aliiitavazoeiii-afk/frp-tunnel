#!/usr/bin/env bash
# Naive + Mieru production console. Legacy Maya3 Triple operations are NOT imported.
set -Eeuo pipefail
umask 077
B=$(cd -- "$(dirname -- "$0")" && pwd)
IR=/etc/dual-trust-mieru/iran
STATE=/var/lib/dual-trust-mieru/naive-mieru
HEALTH=/usr/local/sbin/nm-health
[[ -x "$HEALTH" ]] || HEALTH=$B/nm-health.sh
if [[ $EUID -ne 0 ]]; then exec sudo -- "$0" "$@";fi
[[ -t 0 ]] || { echo 'Interactive terminal required; use dual status / dual health instead' >&2;exit 2; }
is_active(){
  local unit=$1
  [[ "$unit" == *.* ]] || unit="$unit.service"
  systemctl is-active "$unit" 2>/dev/null || true
}
pause(){ echo;read -r -p 'Press Enter to continue...' _ || true; }
header(){
  clear 2>/dev/null || true
  echo '============================================================'
  echo '            NAIVE + MIERU TUNNEL MANAGER'
  echo '                power by ali tavazoei'
  echo '============================================================'
  printf '%-22s | %-25s\n' 'ROLE / SERVICE' 'STATUS / VALUE'
  echo '-----------------------+--------------------------'
  printf '%-22s | %-25s\n' 'Naive foreign IP' "$(jq -r '.public_ip // "unknown"' /etc/dual-trust-mieru/naive-mieru/bundle.json 2>/dev/null || echo unknown)"
  printf '%-22s | %-25s\n' 'Mieru foreign IP' "$(jq -r '.public_ip // "unknown"' "$IR/mieru-bundle.json" 2>/dev/null || echo unknown)"
  printf '%-22s | %-25s\n' 'Naive carrier' "$(is_active nm-naive-client)"
  printf '%-22s | %-25s\n' 'Mieru carrier' "$(is_active dual-mieru-carrier)"
  printf '%-22s | %-25s\n' 'Dispatcher' "$(is_active dual-dispatcher)"
  printf '%-22s | %-25s\n' 'XUDP bridge' "$(is_active dual-xudp-bridge)"
  printf '%-22s | %-25s\n' 'x-ui' "$(is_active x-ui)"
  printf '%-22s | %-25s\n' 'Autoheal timer' "$(is_active dual-tunnel-autoheal.timer)"
  printf '%-22s | %-25s\n' 'Load balancing' "$(awk '/^[[:space:]]*strategy:/{print $2;exit}' "$IR/dispatcher.yaml" 2>/dev/null || echo unknown)"
  echo
}
recent_logs(){
  echo '=== RECENT TUNNEL WARNINGS (30 min; secret-bearing lines omitted) ==='
  journalctl --no-pager -o cat --since '-30 min' \
    -u nm-naive-client.service -u dual-mieru-carrier.service \
    -u dual-xudp-bridge.service -u dual-dispatcher.service \
    -u dual-tunnel-autoheal.service |
  grep -Ei 'warning|warn|error|failed|timeout|reset|refused|broken pipe|restart|recovery|unhealthy' |
  grep -Eiv 'authorization|password|secret|bearer|proxy.*@' |
  tail -n 100 || true
}
restart_role(){
  local role=$1 svc port word
  svc=nm-naive-client;port=7991;word=RESTART-NAIVE
  if [[ $role == mieru ]]; then svc=dual-mieru-carrier;port=7992;word=RESTART-MIERU;fi
  echo "This operation interrupts existing $role carrier sessions only."
  echo 'x-ui, Dispatcher, shared bridge and the other carrier will not be restarted.'
  read -r -p "Type $word to confirm: " ANSWER
  [[ "$ANSWER" == "$word" ]] || { echo 'Cancelled';return 0; }
  (
    exec 8>/run/dual-trust-mieru-autoheal.lock
    flock -w 30 8 || { echo 'Autoheal busy. Retry later.';exit 1; }
    systemctl restart "$svc.service"
    sleep 3
    systemctl is-active --quiet "$svc.service"
    "$HEALTH" --quick "$role"
  )
}
low_noise(){
  echo '=== CONSERVATIVE HEALTH PROFILE ==='
  sed -n '/^proxy-groups:/,/^rules:/p' "$IR/dispatcher.yaml" |grep -E 'strategy:|interval:|lazy:|max-failed-times:' || true
  echo "Autoheal timer: $(is_active dual-tunnel-autoheal.timer)"
  if grep -q '    interval: 120' "$IR/dispatcher.yaml" &&
     grep -q '    lazy: true' "$IR/dispatcher.yaml" &&
     grep -q '    max-failed-times: 2' "$IR/dispatcher.yaml";then
    echo 'Dispatcher already uses low-noise health checks. No reload is necessary.'
  else
    echo 'NOTICE: current health profile differs; no live Dispatcher reload will be performed.'
    echo 'Review changes separately during an approved maintenance window.'
  fi
  if [[ -f /etc/systemd/system/dual-tunnel-autoheal.timer && -x /usr/local/sbin/dual-tunnel-autoheal ]] &&
     grep -q nm-naive-client /usr/local/sbin/dual-tunnel-autoheal;then
    if ! systemctl is-active --quiet dual-tunnel-autoheal.timer;then
      read -r -p 'Enable existing role-aware autoheal timer without restarting carriers? [YES]: ' A
      [[ "$A" == YES ]] && systemctl enable --now dual-tunnel-autoheal.timer || true
    fi
  else
    echo 'Autoheal unit/script missing or legacy; no old Trust autoheal will be installed.'
  fi
}
optimizer(){
  echo '=== SERVER MAINTENANCE, WITHOUT NETWORK/SERVICE RESTART ==='
  uptime
  df -h /
  free -h
  printf 'open file descriptors: ';cat /proc/sys/fs/file-nr || true
  echo 'No MTU, firewall, sysctl, DNS, route or service changes will be made.'
  read -r -p 'Clean APT cache and journal logs older than 14 days? [CLEAN]: ' A
  if [[ "$A" == CLEAN ]];then
    apt-get clean || true
    journalctl --vacuum-time=14d >/dev/null || true
    echo 'Cache/journal cleanup finished; no tunnel changes.'
  else echo 'Audit only; no changes.';fi
}
autoheal(){
  echo '=== AUTOHEAL ==='
  systemctl status dual-tunnel-autoheal.timer --no-pager -l 2>/dev/null |head -n 20 || true
  if [[ -x /usr/local/sbin/dual-tunnel-autoheal ]];then
    if grep -q nm-naive-client /usr/local/sbin/dual-tunnel-autoheal;then
      echo 'Autoheal script: Naive/Mieru aware (carrier-local only)'
    else echo 'WARNING: old autoheal script, requires manual review';fi
  fi
  systemctl list-timers --all --no-pager dual-tunnel-autoheal.timer || true
}
candidate_menu(){
  echo '1) Naive replacement status'
  echo '2) Mieru replacement status'
  echo '3) Abort isolated Naive replacement candidate'
  echo '4) Abort isolated Mieru replacement candidate'
  read -r -p 'Select: ' X
  case "$X" in
    1) python3 "$B/nm-replace.py" status naive;;
    2) python3 "$B/nm-replace.py" status mieru;;
    3) python3 "$B/nm-replace.py" abort naive;;
    4) python3 "$B/nm-replace.py" abort mieru;;
    *) echo 'Cancelled';;
  esac
}
while true;do
  header
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Naive Foreign (new VPS wizard / isolated canary)'
  echo '  4) Replace Mieru Foreign (new VPS wizard / isolated canary)'
  echo '  5) Restart Naive carrier ONLY'
  echo '  6) Restart Mieru carrier ONLY'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Low-noise health + Autoheal review'
  echo '  9) Safe server optimizer / cleanup'
  echo ' 10) Active connections and 30s balance sample'
  echo ' 11) Autoheal timer details'
  echo ' 12) Replacement candidate status / abort'
  echo ' 13) Adaptive byte-balancing monitor (read-only SHADOW)'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' C || exit 0
  echo
  case "$C" in
    1) "$HEALTH" --quick all || true;;
    2) "$HEALTH" --full all || true;;
    3) bash "$B/nm-foreign-wizard.sh" naive || true;;
    4) bash "$B/nm-foreign-wizard.sh" mieru || true;;
    5) restart_role naive || true;;
    6) restart_role mieru || true;;
    7) recent_logs;;
    8) low_noise;;
    9) optimizer;;
    10) python3 "$B/nm-stats.py" --seconds 30 || true;;
    11) autoheal;;
    12) candidate_menu;;
    13) python3 /usr/local/lib/naive-mieru-adaptive/nm-adaptive-core.py --status || true;;
    0) exit 0;;
    *) echo 'Invalid selection';;
  esac
  pause
done
