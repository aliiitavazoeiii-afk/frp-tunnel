#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$B"
for f in install.sh health.sh rotate-front.sh uninstall.sh; do
  printf '%-24s ' "$f"
  bash -n "$f"
  echo OK
done
grep -q 'probe_resistance' install.sh
grep -q 'hide_ip' install.sh
grep -q 'hide_via' install.sh
grep -q 'encode zstd gzip' install.sh
grep -q 'CADDY_SHA256=' install.sh
grep -q 'DNS A record must point' install.sh
grep -q 'refusing to stop or replace existing services' install.sh
grep -q 'chmod 0600' install.sh
grep -q 'naive+https://' install.sh
if grep -Eq 'systemctl (stop|restart|disable).*xray|systemctl (stop|restart|disable).*x-ui' install.sh health.sh rotate-front.sh; then
  echo 'ERROR: direct-vpn must not touch xray/x-ui' >&2
  exit 1
fi
echo 'SUCCESS: direct-vpn source assertions passed'
