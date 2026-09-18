#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' '=== dual-trust-mieru status ==='
date -Is
for s in dual-trust-client dual-mieru-client dual-xudp-bridge dual-dispatcher; do
  printf '%-28s ' "$s"
  systemctl is-active "$s" 2>/dev/null || true
done
printf '\n=== listeners ===\n'
ss -H -ltn | awk '{a=$4; sub(/^.*:/,"",a); p=a+0; if (p>=7990 && p<=7994 || p==19090 || p==17994) print $0}' | sort -k4,4V
printf '\n=== quick probe ===\n'
/usr/local/sbin/dual-tunnel-probe --quick || true
printf '\n=== recent logs ===\n'
for s in dual-trust-client dual-mieru-client dual-xudp-bridge dual-dispatcher; do
  echo "--- $s ---"
  journalctl -u "$s" -n 8 --no-pager -o short-iso 2>/dev/null || true
done
