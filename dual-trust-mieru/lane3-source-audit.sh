#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$B"

echo "=== Unified Trust/Mieru/Naive source audit ==="
printf 'lane3_version='; cat LANE3_VERSION

for f in lane3-common.sh install-foreign-lane3-naive.sh install-iran-lane3-helper.sh lane3-health.sh lane3-manager.sh uninstall-foreign-lane3-naive.sh dual-health.sh dual-autoheal.sh dual-manager.sh dual-cli.sh; do
  printf '%-42s ' "$f"
  bash -n "$f"
  echo OK
done

grep -q "L3_BRANCH='triple-carrier-naive'" lane3-common.sh
grep -q 'L3_NAIVE_PORT=7995' lane3-common.sh
grep -q 'L3_ENTRY_PORT=7996' lane3-common.sh
grep -q 'probe_resistance' install-foreign-lane3-naive.sh
grep -q 'xudp-lane3.internal' install-foreign-lane3-naive.sh
grep -q 'kind":"lane3-naive' install-foreign-lane3-naive.sh
grep -q 'XUDP-NAIVE' lane3-manager.sh
grep -q 'port: 7996' lane3-manager.sh
grep -q 'strategy.*sticky-sessions' lane3-manager.sh
grep -q 'unified Trust/Mieru/Naive pool' lane3-manager.sh
grep -q 'Naive direct :7995' dual-health.sh
grep -q 'Naive TCP    :7996' dual-health.sh
grep -q 'Unified entry:7990' dual-health.sh
grep -q 'heal_carrier naive 7995' dual-autoheal.sh
grep -q 'restarting only lane3-xudp-router.service' dual-autoheal.sh
grep -q 'Naive IP' dual-manager.sh
grep -q 'Naive in pool' dual-manager.sh
grep -q 'old.*was NOT deleted automatically' dual-manager.sh
grep -q 'dual-health.sh.*dual-health' install-iran-lane3-helper.sh

# Unified integration must never edit or restart x-ui, Trust, Mieru or the shared
# Trust/Mieru XUDP bridge. Only the dispatcher may restart for pool membership.
if grep -Eq '/etc/x-ui|x-ui\.db|xrayTemplateConfig|lane3-xui-route' install-iran-lane3-helper.sh lane3-manager.sh; then
  echo 'ERROR: unified helper/manager must not patch x-ui routing' >&2
  exit 1
fi
if grep -Eq 'systemctl[[:space:]]+(restart|stop|disable)([[:space:]]+--now)?[[:space:]]+(x-ui|dual-trust-client|dual-mieru-carrier|dual-xudp-bridge)' lane3-manager.sh install-iran-lane3-helper.sh; then
  echo 'ERROR: Naive integration contains disruptive action against existing production services' >&2
  exit 1
fi

echo 'SUCCESS: unified triple carrier assertions passed'
