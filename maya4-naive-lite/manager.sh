#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/etc/maya4-naive
REPLACE_AUTO=/usr/local/sbin/maya4-replace-auto
HEALTH=/usr/local/sbin/maya4-health

[[ $(id -u) -eq 0 ]] || exec sudo -- "$0" "$@"

if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
else
  G=''; R=''; Y=''; C=''; B=''; N=''
fi

svc(){ systemctl is-active "$1.service" 2>/dev/null || true; }
pause(){ echo; read -r -p 'Press Enter to continue...' _; }
banner(){
  clear 2>/dev/null || true
  printf '%b' "$C$B"
  echo '============================================================'
  echo '                 MAYA4 NAIVE DASHBOARD'
  echo '============================================================'
  printf '%b' "$N"
}
status(){
  local ip='unknown' domain='unknown'
  if [[ -s "$ROOT/bundle.json" ]]; then
    ip=$(jq -r '.public_ip // "unknown"' "$ROOT/bundle.json")
    domain=$(jq -r '.domain // "unknown"' "$ROOT/bundle.json")
  fi
  printf '%-24s | %s\n' 'Current foreign' "$ip"
  printf '%-24s | %s\n' 'Current bundle domain' "$domain"
  printf '%-24s | %s\n' 'Replacement domain' 'naive4.biya2film.top'
  printf '%-24s | %s\n' 'Naive client' "$(svc maya4-naive-client)"
  printf '%-24s | %s\n' 'XUDP router' "$(svc maya4-xudp-router)"
  printf '%-24s | %s\n' 'x-ui' "$(svc x-ui)"
}
logs(){
  journalctl -u maya4-naive-client.service -u maya4-xudp-router.service     --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|reset|failed' | tail -n 120 || true
}

while true; do
  banner
  status
  echo
  echo '  1) Replace foreign server (enter new IP only)'
  echo '  2) Full health check'
  echo '  3) Restart Maya4 tunnel only (x-ui untouched)'
  echo '  4) Recent tunnel warnings/errors'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$REPLACE_AUTO" || true ;;
    2) "$HEALTH" || true ;;
    3)
      systemctl restart maya4-naive-client.service maya4-xudp-router.service
      sleep 3
      "$HEALTH" || true
      ;;
    4) logs ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  pause
done
