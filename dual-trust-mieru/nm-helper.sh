#!/usr/bin/env bash
# NAIVE + MIERU FRIENDLY HELPER: no changes to live services until explicit role-swap confirmation.
set -Eeuo pipefail
umask 077
[[ $(id -u) -eq 0 ]] || exec sudo -- "$0" "$@"
[[ -t 0 && -t 1 ]] || { echo 'Open an interactive SSH terminal and run: sudo helper'; exit 2; }

LIB=/usr/local/lib/naive-mieru-manager
CONF=/etc/dual-trust-mieru/iran
NAIVE=/etc/dual-trust-mieru/naive-mieru/bundle.json
MIERU=$CONF/mieru-bundle.json
for f in "$LIB/nm-foreign-wizard.sh" "$LIB/nm-replace.py" /usr/local/sbin/nm-health /usr/local/sbin/nm-live-audit; do
  [[ -s "$f" ]] || { echo "Missing installed manager: $f"; exit 1; }
done

read_ip(){
  local f=$1
  if [[ -s "$f" ]]; then
    jq -r '.public_ip // "unknown"' "$f" 2>/dev/null || echo unknown
  else
    echo unknown
  fi
}
svc(){
  systemctl is-active "$1.service" 2>/dev/null || true
}
pause(){
  echo
  read -r -p 'Press Enter to return to Helper...' _ || true
}
header(){
  clear 2>/dev/null || true
  echo '=========================================================='
  echo '                  NAIVE + MIERU HELPER'
  echo '                    power by ali tavazoei'
  echo '=========================================================='
  printf ' IRAN  : x-ui=%s  Dispatcher=%s  XUDP=%s\n' \
    "$(svc x-ui)" "$(svc dual-dispatcher)" "$(svc dual-xudp-bridge)"
  printf ' NAIVE : %-16s  carrier=%s\n' "$(read_ip "$NAIVE")" "$(svc nm-naive-client)"
  printf ' MIERU : %-16s  carrier=%s\n' "$(read_ip "$MIERU")" "$(svc dual-mieru-carrier)"
  printf ' POOL  : %s\n' "$(awk '/^[[:space:]]*strategy:/{print $2;exit}' "$CONF/dispatcher.yaml" 2>/dev/null || echo unknown)"
  echo '=========================================================='
  echo
  echo '  1) Dashboard / status'
  echo '  2) Full health test (TCP / Telegram / UDP-XUDP)'
  echo '  3) REPLACE Naive foreign - NEW VPS / existing bundle'
  echo '  4) REPLACE Mieru foreign - NEW VPS / existing bundle'
  echo '  5) Live traffic split & latency (60 seconds)'
  echo '  6) Live traffic split & latency (5 minutes)'
  echo '  7) Recent warning/error logs (last 30 minutes)'
  echo '  8) Replacement candidate status / safe abort'
  echo '  9) Advanced original manager menu'
  echo '  0) Exit'
  echo
  echo ' Foreign replacement first tests an isolated candidate;'
  echo ' only explicit REPLACE-naive or REPLACE-mieru performs cutover.'
}
candidates(){
  echo '=== REPLACEMENT CANDIDATES ==='
  python3 "$LIB/nm-replace.py" status naive
  python3 "$LIB/nm-replace.py" status mieru
  echo
  echo '  1) Abort isolated Naive candidate'
  echo '  2) Abort isolated Mieru candidate'
  echo '  0) Back (do not change anything)'
  local v answer role
  read -r -p 'Select: ' v || return 0
  case "$v" in
    1) role=naive ;;
    2) role=mieru ;;
    *) return 0 ;;
  esac
  read -r -p "Type ABORT-$role to discard candidate (never stops live traffic): " answer
  [[ "$answer" == "ABORT-$role" ]] || { echo 'Cancelled'; return 0; }
  python3 "$LIB/nm-replace.py" abort "$role"
}
logs(){
  echo '=== LAST 30 MINUTES: WARNINGS/ERRORS (credentials filtered) ==='
  journalctl --no-pager --since '-30 minutes' -p warning -n 100 \
    -u nm-naive-client.service -u dual-mieru-carrier.service \
    -u dual-dispatcher.service -u dual-xudp-bridge.service |
    grep -Eiv 'password|username|authorization|bearer|secret|proxy.*@' || true
}
while true; do
  header
  read -r -p 'Choose 0-9: ' choice || exit 0
  echo
  case "$choice" in
    1) /usr/local/bin/dual status || true ;;
    2) /usr/local/sbin/nm-health --full all || true ;;
    3) bash "$LIB/nm-foreign-wizard.sh" naive || true ;;
    4) bash "$LIB/nm-foreign-wizard.sh" mieru || true ;;
    5) python3 /usr/local/sbin/nm-live-audit --seconds 60 || true ;;
    6) python3 /usr/local/sbin/nm-live-audit --seconds 300 || true ;;
    7) logs ;;
    8) candidates || true ;;
    9) bash "$LIB/nm-manager.sh" || true ;;
    0) echo 'Helper closed; tunnel services left running.'; exit 0 ;;
    *) echo 'Unknown selection.' ;;
  esac
  pause
done
