#!/usr/bin/env bash
# Live Naive + Mieru operator dashboard. Never changes protected services.
set -Eeuo pipefail
D=/etc/dual-trust-mieru/iran
NM=/etc/dual-trust-mieru/naive-mieru
safe_ip(){
  [[ -s "$1" ]] && jq -r '.public_ip // "unknown"' "$1" 2>/dev/null || echo unknown
}
status(){
  echo '=============== NAIVE + MIERU ==============='
  printf 'Naive foreign       : %s\n' "$(safe_ip "$NM/bundle.json")"
  printf 'Mieru foreign       : %s\n' "$(safe_ip "$D/mieru-bundle.json")"
  for svc in x-ui dual-dispatcher dual-xudp-bridge nm-naive-client dual-mieru-carrier; do
    printf '%-20s: %s\n' "$svc" "$(systemctl is-active "$svc.service" 2>/dev/null || true)"
  done
  echo 'Pool strategy (configured):'
  sed -n '/^proxy-groups:/,/^rules:/p' "$D/dispatcher.yaml" |
    grep -E 'type:|strategy:|interval:|lazy:|max-failed-times:' || true
  if grep -q '      - XUDP-NAIVE' "$D/dispatcher.yaml"; then
    echo 'Pool: native Naive/Mieru labels'
  else
    echo 'Pool: compatibility alias XUDP-TRUST routes to Naive (the strategy above reflects the current saved config)'
  fi
  echo 'Autoheal            : '"$(systemctl is-active dual-tunnel-autoheal.timer 2>/dev/null || true)"
  echo 'Commands: dual (interactive menu) | dual health --full all | dual status | dual balance-plan'
}
case "${1:-}" in
  '')
    if [[ -t 0 && -t 1 ]]; then
      exec /usr/local/lib/naive-mieru-manager/nm-manager.sh
    else
      status
    fi ;;
  menu) exec /usr/local/lib/naive-mieru-manager/nm-manager.sh ;;
  status) status ;;
  health) shift; exec /usr/local/sbin/nm-health "${1:---quick}" "${2:-all}" ;;
  balance-plan) exec /usr/local/sbin/nm-pool-balance --plan ;;
  *) echo 'usage: dual [menu|status|health [--quick|--full] [all|naive|mieru]|balance-plan]' >&2; exit 2 ;;
esac
