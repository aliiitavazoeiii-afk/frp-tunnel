#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE=direct-naive.service
BUNDLE=/root/direct-naive-client.json
CADDY=/usr/local/lib/direct-naive/caddy

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
echo '=== direct-vpn health ==='
systemctl --no-pager --full status "$SERVICE" | sed -n '1,12p'
echo
ss -lntp | grep -E ':(80|443)\b' || true

echo
if [[ -x "$CADDY" ]]; then
  "$CADDY" version || true
fi

[[ -s "$BUNDLE" ]] || { echo "missing $BUNDLE" >&2; exit 1; }
DOMAIN=$(jq -r '.domain' "$BUNDLE")
USER_NAME=$(jq -r '.username' "$BUNDLE")
USER_PASS=$(jq -r '.password' "$BUNDLE")
PUBLIC_IP=$(jq -r '.public_ip' "$BUNDLE")

echo
echo "domain=$DOMAIN expected_ip=$PUBLIC_IP"
echo -n 'dns='
getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true

echo
echo '=== TLS/H2 ==='
timeout 12 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -alpn h2 </dev/null 2>/dev/null \
  | grep -E 'subject=|issuer=|ALPN protocol|Verify return code' || true

echo
echo '=== front page ==='
curl -fsSI --connect-timeout 5 --max-time 12 "https://$DOMAIN/" | sed -n '1,8p'

echo
echo '=== authenticated proxy egress ==='
code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 7 --max-time 20 \
  -x "https://${USER_NAME}:${USER_PASS}@${DOMAIN}:443" 'https://www.gstatic.com/generate_204' || true)
echo "proxy_test_http=$code"
[[ "$code" == "204" || "$code" == "200" ]] || { echo 'proxy test failed' >&2; exit 2; }

echo 'SUCCESS: direct Naive endpoint and egress are healthy'
