#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$B"

echo '=== Maya4 Naive Lite source audit ==='
for f in common.sh install-foreign.sh install-iran.sh attach-xui.sh health.sh; do
  printf '%-28s ' "$f"
  bash -n "$f"
  echo OK
done

grep -q 'NAIVE_PORT=7995' common.sh
grep -q 'ENTRY_PORT=7996' common.sh
grep -q 'maya4-naive-client.service' install-iran.sh
grep -q 'maya4-xudp-router.service' install-iran.sh
grep -q 'Maya4 foreign IPv4' install-iran.sh
grep -q 'XUI_NONINTERACTIVE=1' install-iran.sh
grep -q 'XUI_LOG_LEVEL=warning' install-iran.sh
grep -q 'MemoryHigh=96M' install-iran.sh
grep -q 'MemoryHigh=160M' install-iran.sh
grep -q 'maya4-naive-all' attach-xui.sh
grep -q 'ROLLBACK: restoring previous x-ui database' attach-xui.sh
grep -q 'Naive direct :7995' health.sh
grep -q 'Naive full   :7996' health.sh
grep -q 'UDP/XUDP :7996' health.sh
grep -q 'maya4-naive-endpoint.service' install-foreign.sh
grep -q 'maya4-xudp.service' install-foreign.sh
grep -q 'xudp-maya4.internal' install-foreign.sh

# Maya4 is deliberately single-carrier: no dispatcher, Mihomo, Trust or Mieru.
runtime_files=(common.sh install-foreign.sh install-iran.sh attach-xui.sh health.sh)
if grep -Eq 'dual-dispatcher|mihomo|dual-trust|dual-mieru|sticky-sessions' "${runtime_files[@]}"; then
  echo 'ERROR: Maya4 lite unexpectedly contains dual/triple carrier components' >&2
  exit 1
fi

# No specialized anti-detection/probing-resistance knobs in this profile.
if grep -Eq 'probe_resistance|traffic-pattern|HANDSHAKE_|anti_dpi' "${runtime_files[@]}"; then
  echo 'ERROR: Maya4 lite must remain a standard transport profile' >&2
  exit 1
fi

echo 'SUCCESS: Maya4 Naive Lite assertions passed'
