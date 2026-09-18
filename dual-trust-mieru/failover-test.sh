#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run as root" >&2; exit 1; }
PROBE=/usr/local/sbin/dual-tunnel-probe
[[ -x "$PROBE" ]] || { echo "dual-tunnel-probe missing" >&2; exit 1; }

restore(){
  set +e
  systemctl start dual-trust-client.service dual-mieru-carrier.service >/dev/null 2>&1 || true
}
trap restore EXIT

wait_entry(){
  local label=$1
  for i in $(seq 1 10); do
    if curl -4 -sS --socks5-hostname 127.0.0.1:7990 --connect-timeout 5 --max-time 12 \
      -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null | grep -qx 204; then
      echo "$label: dispatcher PASS on attempt $i"
      return 0
    fi
    sleep 4
  done
  echo "$label: dispatcher did not recover" >&2
  return 1
}

echo "BASELINE: both paths"
"$PROBE" --quick

echo
echo "FAILOVER A: stopping Trust carrier; Mieru must carry dispatcher"
systemctl stop dual-trust-client.service
wait_entry "Trust stopped"
systemctl start dual-trust-client.service
sleep 6
"$PROBE" --quick

echo
echo "FAILOVER B: stopping Mieru carrier; Trust must carry dispatcher"
systemctl stop dual-mieru-carrier.service
wait_entry "Mieru stopped"
systemctl start dual-mieru-carrier.service
sleep 6
"$PROBE" --quick

trap - EXIT
restore
echo "SUCCESS: dispatcher survived loss of either carrier independently"
