#!/usr/bin/env bash
# Read-only smoke test for the fully installed staging proxy and two upstreams.
set -Eeuo pipefail
check () {
  local port="$1" name="$2"
  echo "===== $name (127.0.0.1:$port) ====="
  curl --noproxy '' --socks5-hostname "127.0.0.1:$port" \
    --connect-timeout 5 --max-time 12 -fsS \
    https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|colo)='
  curl --noproxy '' --socks5-hostname "127.0.0.1:$port" \
    --connect-timeout 5 --max-time 12 -sS -o /dev/null \
    -w 'gstatic http=%{http_code} latency=%{time_total}s\n' \
    https://www.gstatic.com/generate_204
}
check 21001 backhaul
check 21002 mieru
echo "===== HAProxy gateway ====="
systemctl is-active dual-ha-v2-gateway.service
systemctl is-active dual-ha-v2-health.service
[[ -r /run/dual-ha-v2/health.json ]] && cat /run/dual-ha-v2/health.json
check 18080 dual-egress
echo "===== Existing REALITY public port ====="
ss -lntp '( sport = :443 )'
echo "NOTE: This tests SOCKS5 -> foreign Internet; it is NOT a real client REALITY E2E test."
