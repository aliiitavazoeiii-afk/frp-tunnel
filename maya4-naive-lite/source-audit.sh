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
grep -q "XUI_REQUIRED_VERSION='2.9.4'" install-iran.sh
grep -q 'MHSanaei/3x-ui/v2.9.4/install.sh' install-iran.sh
grep -q 'bash "$tmp" v2.9.4' install-iran.sh
grep -q '/usr/local/x-ui/x-ui -v' install-iran.sh
! grep -q 'MHSanaei/3x-ui/master/install.sh' install-iran.sh
grep -q 'MemoryHigh=96M' install-iran.sh
grep -q 'MemoryHigh=160M' install-iran.sh
grep -q 'maya4-naive-all' attach-xui.sh
grep -q 'PRAGMA table_info(inbounds)' attach-xui.sh
grep -q '3X-UI public inbound tag' attach-xui.sh
grep -q 'X-UI TEMPLATE ROUTING OK' attach-xui.sh
grep -q 'v2.9.4-generated-default' attach-xui.sh
grep -q "INSERT INTO settings(key,value) VALUES('xrayTemplateConfig',?)" attach-xui.sh
grep -q 'XUI_TEMPLATE_FILE=/usr/local/x-ui/bin/config.json' attach-xui.sh
grep -q 'ROLLBACK: restoring previous x-ui database' attach-xui.sh
grep -q 'Naive direct :7995' health.sh
grep -q 'Naive full   :7996' health.sh
grep -q 'UDP/XUDP :7996' health.sh
grep -q 'maya4-naive-endpoint.service' install-foreign.sh
grep -q 'maya4-xudp.service' install-foreign.sh
grep -q 'RESUME_EXISTING=1' install-foreign.sh
grep -q 'Any HTTP status is acceptable here' install-foreign.sh
! grep -q 'curl -fsS.*resolve.*DOMAIN:443' install-foreign.sh
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
