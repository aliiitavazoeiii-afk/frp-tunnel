#!/usr/bin/env bash
set -euo pipefail
SERVICE=anytls-tunnel
CONFIG_DIR=/etc/anytls-tunnel

echo "=== SERVICE ==="
systemctl --no-pager --full status "$SERVICE" || true
echo
echo "=== LISTENERS ==="
ss -ltnp | grep -E ':(443|7890|9090)\b' || true
echo
echo "=== VERSION ==="
/usr/local/bin/mihomo-anytls-tunnel -v || true
echo
echo "=== RECENT LOGS ==="
journalctl -u "$SERVICE" -n 40 --no-pager || true

if [[ -f "$CONFIG_DIR/role" && "$(cat "$CONFIG_DIR/role")" == "iran" && -f "$CONFIG_DIR/deploy.env" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_DIR/deploy.env"
  echo
  echo "=== BALANCER API ==="
  curl -fsS -H "Authorization: Bearer ${CONTROLLER_SECRET}" \
    "http://127.0.0.1:${LOCAL_CONTROLLER_PORT}/proxies/TUNNEL" | jq '{name,type,now,all,history}' || true
fi
