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

echo
echo "--- v1.1 manager / health assertions ---"
grep -q 'OnUnitActiveSec=5min' install-autoheal.sh || { echo 'auto-heal cadence is not the v1.1 low-noise 5m profile' >&2; exit 1; }
grep -q 'RandomizedDelaySec=90s' install-autoheal.sh || { echo 'auto-heal timer missing jitter' >&2; exit 1; }
! grep -q 'OnUnitActiveSec=30s' install-autoheal.sh || { echo 'legacy 30-second auto-heal survived' >&2; exit 1; }
grep -q 'probe_udp 7991' dual-autoheal.sh || { echo 'auto-heal missing real Trust UDP/XUDP probe' >&2; exit 1; }
grep -q 'probe_udp 7992' dual-autoheal.sh || { echo 'auto-heal missing real Mieru UDP/XUDP probe' >&2; exit 1; }
grep -q 't_udp == 0 && m_udp == 0' dual-autoheal.sh || { echo 'shared bridge restart is not gated on both UDP paths failing' >&2; exit 1; }
grep -q 'api.telegram.org' dual-health.sh || { echo 'health screen missing Telegram check' >&2; exit 1; }
grep -q 'UDP/XUDP' dual-health.sh || { echo 'health screen missing UDP/XUDP check' >&2; exit 1; }
grep -q 'api.telegram.org' replace-carrier-only-final.sh || { echo 'carrier replacement missing Telegram gate' >&2; exit 1; }
grep -q 'probe_udp_stable' replace-carrier-only-final.sh || { echo 'carrier replacement missing UDP/XUDP gate' >&2; exit 1; }
grep -q 'multiplexing: MULTIPLEXING_OFF' replace-carrier-only-final.sh || { echo 'carrier replacement would regress Mieru mux mode' >&2; exit 1; }
grep -q 'DUAL MIERU TRUST TUNNEL' dual-manager.sh || { echo 'manager banner missing' >&2; exit 1; }
grep -q 'Replace Trust foreign server' dual-manager.sh || { echo 'manager missing Trust replacement action' >&2; exit 1; }
grep -q 'Replace Mieru foreign server' dual-manager.sh || { echo 'manager missing Mieru replacement action' >&2; exit 1; }
grep -q 'dual-install-foreign.sh --role trust' dual-manager.sh || { echo 'manager missing automated Trust bootstrap' >&2; exit 1; }
grep -q 'dual-install-foreign.sh --role mieru' dual-manager.sh || { echo 'manager missing automated Mieru bootstrap' >&2; exit 1; }
grep -q 'xudp_uuid' dual-install-foreign.sh || { echo 'foreign installer missing UUID preservation path' >&2; exit 1; }
grep -q 'loopback XUDP backend preflight' dual-install-foreign.sh || { echo 'foreign installer missing XUDP backend preflight' >&2; exit 1; }
grep -q 'Existing dual installation detected: upgrading in place' dual-install-iran.sh || { echo 'Iran installer missing in-place upgrade path' >&2; exit 1; }
grep -q 'exec /usr/local/sbin/dual-manager' dual-cli.sh || { echo 'dual status CLI missing' >&2; exit 1; }

grep -q 'chmod 0755.*dual-probe.sh' attach-xui-final.sh || { echo 'final x-ui attach wrapper missing probe executable normalization' >&2; exit 1; }
grep -q '^probe_udp_once(){' dual-probe-final.sh || { echo 'final probe missing isolated UDP/XUDP attempt helper' >&2; exit 1; }
grep -q '^probe_udp(){' dual-probe-final.sh || { echo 'final probe missing UDP/XUDP retry wrapper' >&2; exit 1; }
grep -q 'UDP/XUDP transient failure; retry' dual-probe-final.sh || { echo 'final probe missing transient UDP retry handling' >&2; exit 1; }

grep -q 'net.ipv4.tcp_mtu_probing' host-optimizer.sh || { echo 'host optimizer missing safe PLPMTUD fallback' >&2; exit 1; }
grep -q 'net.ipv4.tcp_congestion_control' host-optimizer.sh || { echo 'host optimizer missing congestion-control capability handling' >&2; exit 1; }
grep -q 'PASS: tunnel/x-ui PID/state/restart counters unchanged' host-optimizer.sh || { echo 'host optimizer missing PID safety verification' >&2; exit 1; }
! grep -Eq 'systemctl[[:space:]]+(restart|stop|disable)|tc[[:space:]]+qdisc[[:space:]]+(replace|del|change)|ip[[:space:]]+link[[:space:]]+set|iptables|nft[[:space:]]' host-optimizer.sh || { echo 'host optimizer contains a disruptive network/service action' >&2; exit 1; }
! grep -q '/etc/dual-trust-mieru' host-optimizer.sh || { echo 'host optimizer must not modify/read tunnel config tree' >&2; exit 1; }

echo 'final split architecture + v1.1 manager + low-noise health + safe replacement assertions = OK'

echo
echo "--- required final files ---"
for f in common.sh install-foreign-trust.sh install-foreign-mieru.sh install-foreign-mieru-final.sh install-iran.sh install-iran-final.sh dual-install-foreign.sh dual-install-iran.sh dual-manager.sh dual-cli.sh dual-health.sh dual-probe-final.sh dual-autoheal.sh install-autoheal.sh migrate-live-final.sh failover-test.sh status.sh attach-xui.sh attach-xui-final.sh replace-foreign-final.sh replace-carrier-only-final.sh diagnose-mieru.sh host-optimizer.sh uninstall-iran.sh; do
  [[ -s "$f" ]] || { echo "missing: $f" >&2; exit 1; }
  echo "OK $f"
done

echo
echo "SUCCESS: FINAL source audit passed"
