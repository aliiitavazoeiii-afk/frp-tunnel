#!/usr/bin/env bash
set -Eeuo pipefail

services=(dual-trust-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher)
echo "=== dual services ==="
for s in "${services[@]}"; do
  printf '%-28s ' "$s"
  systemctl is-active "$s.service" 2>/dev/null || true
done

echo
echo "=== local listeners ==="
for p in 7990 7991 7992 7993 7994 19090; do
  printf '%-8s ' "$p"
  if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then echo LISTEN; else echo MISSING; fi
done

echo
echo "=== quick full-path probes ==="
if [[ -x /usr/local/sbin/dual-tunnel-probe ]]; then
  /usr/local/sbin/dual-tunnel-probe --quick || true
else
  echo "dual-tunnel-probe not installed"
fi
