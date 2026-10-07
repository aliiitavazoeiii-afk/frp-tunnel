#!/usr/bin/env bash
set -Eeuo pipefail
LIB=/usr/local/lib/dual-trust-mieru-lane3/lane3-common.sh
[[ -s "$LIB" ]] || LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lane3-common.sh"
source "$LIB"

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G='';R='';Y='';B='';N=''; fi
ok(){ printf '%b%-7s%b %s\n' "$G" OK "$N" "$*"; }
bad(){ printf '%b%-7s%b %s\n' "$R" FAIL "$N" "$*"; fail=1; }
warn(){ printf '%b%-7s%b %s\n' "$Y" WARN "$N" "$*"; }

fail=0
echo 'MAYA3 MULTI-LANE — LANE 3 HEALTH'
if [[ -s "$L3_ROOT/bundle.json" ]]; then
  printf 'Lane 3 foreign : %s\n' "$(jq -r '.public_ip // "unknown"' "$L3_ROOT/bundle.json")"
  printf 'Lane 3 domain  : %s\n' "$(jq -r '.domain // "unknown"' "$L3_ROOT/bundle.json")"
fi
printf 'Routing mode   : %s\n' "$([[ -s "$L3_ROOT/routing-mode" ]] && cat "$L3_ROOT/routing-mode" || echo not-configured)"
echo
for s in lane3-naive-client lane3-xudp-router; do
  systemctl is-active --quiet "$s.service" 2>/dev/null && ok "$s" || bad "$s"
done
systemctl is-active --quiet x-ui.service 2>/dev/null && ok x-ui || bad x-ui
echo
if l3_http "$L3_NAIVE_PORT"; then ok "Naive direct :$L3_NAIVE_PORT HTTP=204"; else bad "Naive direct :$L3_NAIVE_PORT"; fi
if l3_http "$L3_ENTRY_PORT"; then ok "Lane3 TCP    :$L3_ENTRY_PORT HTTP=204"; else bad "Lane3 TCP    :$L3_ENTRY_PORT"; fi
tg=0
for _ in 1 2 3; do
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$L3_ENTRY_PORT" --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' https://api.telegram.org/ 2>/dev/null || true)
  [[ "$code" =~ ^(200|301|302)$ ]] && tg=$((tg+1))
  sleep .2
done
(( tg==3 )) && ok "Lane3 Telegram=$tg/3" || { ((tg>0)) && warn "Lane3 Telegram=$tg/3 intermittent" || bad 'Lane3 Telegram=0/3'; }
ug=0
for _ in 1 2 3; do l3_udp "$L3_ENTRY_PORT" && ug=$((ug+1)) || true; sleep .2; done
(( ug==3 )) && ok "Lane3 UDP/XUDP=$ug/3" || { ((ug>0)) && warn "Lane3 UDP/XUDP=$ug/3 intermittent" || bad 'Lane3 UDP/XUDP=0/3'; }
exit "$fail"
