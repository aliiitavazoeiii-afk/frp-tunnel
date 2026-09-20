#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE="$B/install-foreign-mieru.sh"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ -s "$BASE" ]] || { echo "ERROR: base Mieru foreign installer missing: $BASE" >&2; exit 1; }

if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-ntp true >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    [[ "$sync" == true || "$sync" == yes ]] && break
    sleep 0.5
  done
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  [[ "$sync" == true || "$sync" == yes ]] || echo "WARNING: NTP still not reported synchronized; verify clock before Iran cutover" >&2
fi

bash "$BASE" "$@"

mita status | grep -q RUNNING
ss -H -ltn 'sport = :2443' | grep -q '127.0.0.1:2443'
[[ -s /root/dual-mieru-client.json ]]

echo "SUCCESS: FINAL Mieru foreign installed; NTP requested and runtime verified"
