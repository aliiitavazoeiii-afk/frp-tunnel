#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$B"

echo "=== Dual Trust/Mieru FINAL source audit ==="
printf 'version='; cat VERSION
printf 'git_head='; git -C "$B" rev-parse HEAD 2>/dev/null || echo unknown

echo
echo "--- bash syntax ---"
for f in *.sh; do
  printf '%-40s ' "$f"
  bash -n "$f"
  echo OK
done

echo
echo "--- final architecture assertions ---"
grep -q 'MULTIPLEXING_OFF' install-iran-final.sh || { echo 'missing final Mieru mux OFF patch' >&2; exit 1; }
grep -q 'network.*tcp.*carrier-trust' install-iran-final.sh || { echo 'missing Trust TCP direct rule' >&2; exit 1; }
grep -q 'network.*udp.*xudp-trust' install-iran-final.sh || { echo 'missing Trust UDP XUDP rule' >&2; exit 1; }
grep -q 'network.*tcp.*carrier-mieru' install-iran-final.sh || { echo 'missing Mieru TCP direct rule' >&2; exit 1; }
grep -q 'network.*udp.*xudp-mieru' install-iran-final.sh || { echo 'missing Mieru UDP XUDP rule' >&2; exit 1; }
grep -q 'xudp-trust.internal' install-iran-final.sh || { echo 'missing Trust XUDP hostname workaround' >&2; exit 1; }
grep -q 'multiplexing: MULTIPLEXING_OFF' replace-foreign-final.sh || { echo 'replace helper would regress Mieru mux mode' >&2; exit 1; }
! grep -q 'multiplexing: MULTIPLEXING_LOW' replace-foreign-final.sh || { echo 'legacy Mieru LOW found in final replace helper' >&2; exit 1; }
grep -q 'MULTIPLEXING_OFF' migrate-live-final.sh || { echo 'live migration missing Mieru mux OFF' >&2; exit 1; }
grep -q "'network':'tcp'.*'carrier-trust'" migrate-live-final.sh || { echo 'live migration missing Trust TCP direct rule' >&2; exit 1; }
grep -q "'network':'udp'.*'xudp-trust'" migrate-live-final.sh || { echo 'live migration missing Trust UDP XUDP rule' >&2; exit 1; }
grep -q '^resilient(){' migrate-live-final.sh || { echo 'live migration missing transient-safe validator' >&2; exit 1; }
grep -q 'for attempt in 1 2 3' migrate-live-final.sh || { echo 'live migration validator missing retry loop' >&2; exit 1; }
grep -q 'dual-tunnel-autoheal' install-autoheal.sh || { echo 'auto-heal installer missing timer service' >&2; exit 1; }
grep -q 'dual-trust-client.service' dual-autoheal.sh || { echo 'auto-heal missing selective Trust restart' >&2; exit 1; }
grep -q 'dual-mieru-carrier.service' dual-autoheal.sh || { echo 'auto-heal missing selective Mieru restart' >&2; exit 1; }
grep -q 'chmod 0755.*dual-probe.sh' attach-xui-final.sh || { echo 'final x-ui attach wrapper missing probe executable normalization' >&2; exit 1; }
echo 'final split architecture + resilient validation + auto-heal + x-ui attach assertions = OK'

echo
echo "--- required final files ---"
for f in common.sh install-foreign-trust.sh install-foreign-mieru.sh install-foreign-mieru-final.sh install-iran.sh install-iran-final.sh install-iran-stable.sh dual-probe-final.sh dual-autoheal.sh install-autoheal.sh migrate-live-final.sh failover-test.sh status.sh attach-xui.sh attach-xui-final.sh replace-foreign-final.sh diagnose-mieru.sh uninstall-iran.sh; do
  [[ -s "$f" ]] || { echo "missing: $f" >&2; exit 1; }
  echo "OK $f"
done

echo
echo "SUCCESS: FINAL source audit passed"
