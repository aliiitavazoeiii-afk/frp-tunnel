#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR=/etc/anytls-tunnel
[[ -f "$CONFIG_DIR/role" && "$(cat "$CONFIG_DIR/role")" == "iran" ]] || { echo "Run this on the Iran role" >&2; exit 1; }
# shellcheck disable=SC1091
source "$CONFIG_DIR/deploy.env"

probe(){
  local addr=$1 host=$2 label=$3 tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  local endpoint="${addr}:443"
  [[ "$addr" == *:* ]] && endpoint="[${addr}]:443"
  echo "=== $label: unauthenticated TLS probe ${endpoint} SNI=${host} ==="
  if ! timeout 12 openssl s_client -connect "$endpoint" -servername "$host" -tls1_3 -showcerts </dev/null >"$tmp" 2>/dev/null; then
    echo "FAIL: TLS probe could not complete"
    return 1
  fi
  if ! openssl x509 -in "$tmp" -noout -subject -issuer -dates; then
    echo "FAIL: no leaf certificate returned"
    return 1
  fi
  if openssl x509 -in "$tmp" -noout -checkhost "$host" >/dev/null 2>&1; then
    echo "PASS: fallback certificate matches $host"
  else
    echo "FAIL: fallback certificate does not match $host"
    return 1
  fi
  rm -f "$tmp"
  trap - RETURN
}

rc=0
probe "$NODE_A_ADDR" "$COVER_HOST_A" "foreign-a / ShadowTLS v3" || rc=1
probe "$NODE_B_ADDR" "$COVER_HOST_B" "foreign-b / ResTLS" || rc=1
exit "$rc"
