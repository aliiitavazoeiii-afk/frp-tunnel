#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$B"

echo "=== Unified Trust/Mieru/Naive source audit ==="
printf 'lane3_version='; cat LANE3_VERSION

for f in lane3-common.sh install-foreign-lane3-naive.sh install-iran-lane3-helper.sh migrate-xui-split-to-unified.sh lane3-health.sh lane3-manager.sh uninstall-foreign-lane3-naive.sh dual-health.sh dual-autoheal.sh dual-manager.sh dual-cli.sh; do
  printf '%-42s ' "$f"
  bash -n "$f"
  echo OK
done
python3 -m py_compile lane3-pool.py
echo 'lane3-pool.py syntax                         OK'

grep -q "L3_BRANCH='triple-carrier-naive'" lane3-common.sh
grep -q 'L3_NAIVE_PORT=7995' lane3-common.sh
grep -q 'L3_ENTRY_PORT=7996' lane3-common.sh
grep -q 'probe_resistance' install-foreign-lane3-naive.sh
grep -q 'xudp-lane3.internal' install-foreign-lane3-naive.sh
grep -q 'kind":"lane3-naive' install-foreign-lane3-naive.sh
grep -q "3) Naive foreign" dual-install-foreign.sh
grep -q "ROLE=naive" dual-install-foreign.sh
grep -q 'install-foreign-lane3-naive.sh' dual-install-foreign.sh
grep -q 'POOL=/usr/local/sbin/lane3-pool' lane3-manager.sh
grep -q 'joined the unified Trust/Mieru/Naive pool' lane3-manager.sh
grep -q 'XUDP-NAIVE' lane3-pool.py
grep -q "'    port: 7996'" lane3-pool.py
grep -q 'sticky-sessions' lane3-pool.py
grep -q 'interval=120' lane3-pool.py
grep -q 'lazy=true' lane3-pool.py
grep -q 'max-failed-times=2' lane3-pool.py
grep -q 'dual-dispatcher.service' lane3-pool.py
grep -q 'ROLLBACK: restoring previous dispatcher config' lane3-pool.py
grep -q 'Naive direct :7995' dual-health.sh
grep -q 'Naive TCP    :7996' dual-health.sh
grep -q 'Unified entry:7990' dual-health.sh
grep -q 'heal_carrier naive 7995' dual-autoheal.sh
grep -q 'restarting only lane3-xudp-router.service' dual-autoheal.sh
grep -q 'Naive IP' dual-manager.sh
grep -q 'Naive in pool' dual-manager.sh
grep -q 'was NOT deleted automatically' dual-manager.sh
grep -q 'lane3-pool.py.*lane3-pool' install-iran-lane3-helper.sh
grep -q 'migrate-xui-split-to-unified.sh.*migrate-xui-split-to-unified' install-iran-lane3-helper.sh
grep -q 'triple-unified-entry' migrate-xui-split-to-unified.sh
grep -q 'ROLLBACK: restoring previous x-ui database and dispatcher' migrate-xui-split-to-unified.sh
grep -q 'Enabling Naive in unified :7990 pool while x-ui is stopped' migrate-xui-split-to-unified.sh
grep -q 'Waiting for real user reconnects before post-migration health' migrate-xui-split-to-unified.sh
grep -q 'cp -a "$bk/dispatcher.yaml" "$DISPATCHER"' migrate-xui-split-to-unified.sh
grep -q 'lane3-xui-route.legacy-disabled' migrate-xui-split-to-unified.sh

if grep -Eq '/etc/x-ui|x-ui\.db|xrayTemplateConfig|lane3-xui-route' install-iran-lane3-helper.sh lane3-manager.sh lane3-pool.py; then
  echo 'ERROR: unified helper/manager must not patch x-ui routing' >&2
  exit 1
fi
if grep -Eq 'systemctl[[:space:]]+(restart|stop|disable)([[:space:]]+--now)?[[:space:]]+(x-ui|dual-trust-client|dual-mieru-carrier|dual-xudp-bridge)' lane3-manager.sh install-iran-lane3-helper.sh; then
  echo 'ERROR: Naive integration contains disruptive action against existing production services' >&2
  exit 1
fi

echo 'SUCCESS: unified triple carrier assertions passed'
