#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR=/etc/anytls-tunnel
[[ -f "$CONFIG_DIR/role" ]] || { echo "Not installed" >&2; exit 1; }
[[ "$(cat "$CONFIG_DIR/role")" == "iran" ]] || { echo "health.sh is intended for the Iran role" >&2; exit 1; }
# shellcheck disable=SC1091
source "$CONFIG_DIR/deploy.env"
AUTH=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")
BASE="http://127.0.0.1:${LOCAL_CONTROLLER_PORT}"

check_node(){
  local name=$1
  printf '%-24s ' "$name"
  if out=$(curl -fsS --max-time 8 "${AUTH[@]}" -G \
      --data-urlencode 'url=https://www.gstatic.com/generate_204' \
      --data-urlencode 'timeout=5000' \
      --data-urlencode 'expected=204' \
      "$BASE/proxies/$name/delay" 2>&1); then
    echo "OK $out"
  else
    echo "FAIL $out"
    return 1
  fi
}

fail=0
check_node foreign-a-shadowtls || fail=1
check_node foreign-b-restls || fail=1

echo "BALANCED PATH              testing..."
if ip=$(curl -fsS --proxy "http://127.0.0.1:${LOCAL_MIXED_PORT}" --connect-timeout 5 --max-time 12 https://api.ipify.org); then
  echo "BALANCED PATH              OK egress=$ip"
else
  echo "BALANCED PATH              FAIL"
  fail=1
fi
exit "$fail"
