#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$B"

echo "=== Maya3 Multi-Lane Naive source audit ==="
printf 'lane3_version='; cat LANE3_VERSION

for f in lane3-common.sh install-foreign-lane3-naive.sh install-iran-lane3-helper.sh lane3-health.sh lane3-xui-route.sh lane3-manager.sh uninstall-foreign-lane3-naive.sh; do
  printf '%-42s ' "$f"
  bash -n "$f"
  echo OK
done

grep -q 'L3_NAIVE_PORT=7995' lane3-common.sh
grep -q 'L3_ENTRY_PORT=7996' lane3-common.sh
grep -q 'probe_resistance' install-foreign-lane3-naive.sh
grep -q 'xudp-lane3.internal' install-foreign-lane3-naive.sh
grep -q 'kind":"lane3-naive' install-foreign-lane3-naive.sh
grep -q 'regexp:\^' lane3-xui-route.sh
grep -q 'lane3-managed-split' lane3-xui-route.sh
grep -q 'all-lane3' lane3-xui-route.sh
grep -q 'all-legacy' lane3-xui-route.sh
grep -q 'dual-tunnel' lane3-xui-route.sh
grep -q 'ROLLBACK: restoring previous x-ui database' lane3-xui-route.sh
grep -q 'ROLLBACK: restoring previous Lane 3 foreign' lane3-manager.sh
grep -q 'lane3-naive-client.service' lane3-manager.sh
grep -q 'lane3-xudp-router.service' lane3-manager.sh
grep -q 'xudpProxyUDP443' lane3-manager.sh

if grep -Eq 'systemctl (restart|stop|disable)( --now)? (dual-trust-client|dual-mieru-carrier|dual-xudp-bridge|dual-dispatcher)' lane3-manager.sh install-iran-lane3-helper.sh; then
  echo 'ERROR: Lane 3 scripts contain disruptive action against legacy tunnel services' >&2
  exit 1
fi
if grep -Eq 'systemctl (restart|stop|disable)( --now)? x-ui' lane3-manager.sh install-iran-lane3-helper.sh; then
  echo 'ERROR: Lane 3 carrier/helper must not touch x-ui directly' >&2
  exit 1
fi

echo 'SUCCESS: Lane 3 isolated architecture assertions passed'
