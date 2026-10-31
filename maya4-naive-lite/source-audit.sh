#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$B"

echo '=== Maya4 Naive Lite source audit ==='
for f in common.sh install-foreign.sh install-iran.sh attach-xui.sh health.sh replace-foreign.sh replace-foreign-auto.sh manager.sh enable-replace-command.sh; do
  printf '%-28s ' "$f"
  bash -n "$f"
  echo OK
done

grep -q 'NAIVE_PORT=7995' common.sh
grep -q 'ENTRY_PORT=7996' common.sh
grep -q 'XRAY_VERSION=v26.10.21' common.sh
grep -q '0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978' common.sh
grep -q 'd1304946c486d98e6b886e9b931eaaaebb23835b30e217638037b7f2721d4e9c' common.sh
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
grep -q "'outboundTag':'maya4-naive'" attach-xui.sh
grep -q 'PRAGMA table_info(inbounds)' attach-xui.sh
grep -q '3X-UI public inbound tag' attach-xui.sh
grep -q 'X-UI TEMPLATE ROUTING OK' attach-xui.sh
grep -q 'v2.9.4-generated-sanitized' attach-xui.sh
grep -q "INSERT INTO settings(key,value) VALUES('xrayTemplateConfig',?)" attach-xui.sh
grep -q 'XUI_TEMPLATE_FILE=/usr/local/x-ui/bin/config.json' attach-xui.sh
grep -q 'ROLLBACK: restoring previous x-ui database' attach-xui.sh
grep -q 'Naive direct :7995' health.sh
grep -q 'Naive full   :7996' health.sh
grep -q 'UDP/XUDP :7996' health.sh
grep -q 'maya4-naive-endpoint.service' install-foreign.sh
grep -q 'maya4-xudp.service' install-foreign.sh
grep -q 'RESUME_EXISTING=1' install-foreign.sh
grep -q 'KEEP_BUNDLE=0' install-foreign.sh
grep -q 'Existing completed foreign deployment found' install-foreign.sh
grep -q 'existing bundle identity differs' install-foreign.sh
grep -q 'existing bundle credentials or UUID differ' install-foreign.sh
grep -q 'endpoint service does not reference expected Caddyfile' install-foreign.sh
grep -q 'XUDP service does not reference expected config' install-foreign.sh
grep -q 'if (( ! KEEP_BUNDLE ));then' install-foreign.sh
grep -q 'no files removed' install-foreign.sh
grep -q 'Any HTTP status is acceptable here' install-foreign.sh
! grep -q 'curl -fsS.*resolve.*DOMAIN:443' install-foreign.sh
grep -q 'xudp-maya4.internal' install-foreign.sh
grep -q -- '--non-interactive' install-foreign.sh
grep -q "DOMAIN='naive4.biya2film.top'" replace-foreign-auto.sh
grep -q 'install-foreign.sh --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --non-interactive' replace-foreign-auto.sh
grep -q '"$LOCAL_REPLACE" "$TMP"' replace-foreign-auto.sh
# The live helper runs from /usr/local/lib/maya4-naive and sources common.sh
# by dirname. Validate both the installer and fail-fast preflight.
grep -Fq 'install -m 0755 "$SRC/common.sh" "$LIB/common.sh"' enable-replace-command.sh
grep -Fq 'for f in common.sh manager.sh' enable-replace-command.sh
grep -Fq '[[ -s /usr/local/lib/maya4-naive/common.sh ]]' replace-foreign-auto.sh
grep -Fq 'bash -n /usr/local/lib/maya4-naive/common.sh "$LOCAL_REPLACE"' replace-foreign-auto.sh
grep -Fq 'source "$B/common.sh"' replace-foreign.sh
grep -q 'Replace foreign server (enter new IP only)' manager.sh
grep -q 'exec /usr/local/sbin/maya4-manager' enable-replace-command.sh
grep -q 'exec /usr/local/sbin/maya4-replace-auto' enable-replace-command.sh
grep -q 'Run: dual status' enable-replace-command.sh
grep -q 'usage: dual \[status|health|restart|replace \[NEW_IP\]\]' enable-replace-command.sh
if grep -qE 'systemctl (stop|restart|disable) x-ui' replace-foreign-auto.sh manager.sh; then
  echo 'ERROR: dashboard/auto replacement must never stop/restart x-ui' >&2
  exit 1
fi

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

# Replacement helper MUST remain separate from the fresh installer.
grep -q 'trap finish EXIT' replace-foreign.sh
grep -q "http_test 17995 'candidate direct'" replace-foreign.sh
grep -q "http_test 17996 'candidate full'" replace-foreign.sh
grep -q 'udp_test 17996' replace-foreign.sh
grep -q 'CUTOVER=1' replace-foreign.sh
grep -q 'cp -a "$BK/naive.json" "$D/naive.json"' replace-foreign.sh
grep -q 'cp -a "$BK/xudp-router.json" "$D/xudp-router.json"' replace-foreign.sh
if grep -qE 'systemctl (stop|restart|disable) x-ui' replace-foreign.sh; then
  echo 'ERROR: foreign replacement must never stop/restart x-ui' >&2
  exit 1
fi

echo 'SUCCESS: Maya4 Naive Lite assertions passed'

grep -q "XUI_XRAY=.*xray-linux-" attach-xui.sh
grep -q 'run -test -c "$candidate"' attach-xui.sh
grep -q "settings':{'servers':\[{'address':'127.0.0.1','port':7996}\]}" attach-xui.sh
! grep -q "'targetStrategy':'AsIs'" attach-xui.sh
! grep -q "'ruleTag':'maya4-naive-all'" attach-xui.sh
grep -q 'Xray public :443 did not return' attach-xui.sh

grep -q "cfg\['inbounds'\]=api_inbounds" attach-xui.sh
grep -q 'template still contains DB/user inbounds' attach-xui.sh
grep -q 'persisted template inbounds are not api-only' attach-xui.sh
grep -q 'existing tag found' attach-xui.sh
