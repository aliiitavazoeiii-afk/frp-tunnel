#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -x /usr/local/sbin/dual-health ]]; then
  exec /usr/local/sbin/dual-health "${1:---full}" naive
fi
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$B/dual-health.sh" "${1:---full}" naive
