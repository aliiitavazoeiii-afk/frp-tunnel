#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
entry=7990
probe(){
  local label=$1 code
  code=$(curl -4 -sS --socks5-hostname 127.0.0.1:$entry --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
  [[ "$code" == 204 ]] || { echo "ERROR: $label dispatcher HTTP=$code" >&2; return 1; }
  echo "$label dispatcher=OK"
}
restore(){
  systemctl start dual-trust-client.service >/dev/null 2>&1 || true
  systemctl start dual-mieru-client.service >/dev/null 2>&1 || true
}
trap restore EXIT
probe BASELINE

echo 'Stopping Trust carrier only...'
systemctl stop dual-trust-client.service
for _ in $(seq 1 8); do sleep 5; probe TRUST_DOWN && break || true; done
probe TRUST_DOWN_FINAL
systemctl start dual-trust-client.service
for _ in $(seq 1 8); do sleep 3; curl -4 -sS --socks5-hostname 127.0.0.1:7991 --connect-timeout 5 --max-time 12 -o /dev/null https://www.gstatic.com/generate_204 && break || true; done

echo 'Stopping Mieru carrier only...'
systemctl stop dual-mieru-client.service
for _ in $(seq 1 8); do sleep 5; probe MIERU_DOWN && break || true; done
probe MIERU_DOWN_FINAL
systemctl start dual-mieru-client.service
sleep 3
probe RECOVERED
trap - EXIT
echo 'SUCCESS: dispatcher survived each single-carrier failure.'
