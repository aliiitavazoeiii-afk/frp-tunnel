#!/usr/bin/env bash
set -euo pipefail
echo "=== Iran existing listener :443 (read-only) ==="
ss -ltnp '( sport = :443 )' || true
echo "=== Candidate upstream local SOCKS ports ==="
for p in 21001 21002; do
 if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$p" 2>/dev/null; then
   echo "$p: TCP listener exists (SOCKS/egress not verified)"
 else echo "$p: no listener"; fi
done
echo "=== End-to-end independent SOCKS checks ==="
for p in 21001 21002; do
  if curl -fsS --socks5-hostname "127.0.0.1:$p" --max-time 12 --connect-timeout 5 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace; then
    echo "$p: PASS actual HTTPS egress"
  else
    echo "$p: FAIL actual HTTPS egress"
  fi
done
echo "=== x-ui and Xray services (read-only) ==="
systemctl --no-pager --plain is-active x-ui xray 2>/dev/null || true
