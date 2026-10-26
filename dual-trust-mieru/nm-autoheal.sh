#!/usr/bin/env bash
# Safe local daemon supervision only: do not restart healthy-but-blocked carriers.
set -Eeuo pipefail
exec 9>/run/dual-trust-mieru-autoheal.lock
flock -n 9 || exit 0
for item in 'mieru:dual-mieru-carrier:7994' 'naive:nm-naive-client:7993'; do
  IFS=: read -r name svc port <<<"$item"
  # Do not restart while a peer is overloaded or a foreign path is filtered:
  # local daemon liveness is not data-plane liveness.
  if systemctl is-active --quiet "$svc.service" &&
     ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
    continue
  fi
  logger -t naive-mieru-autoheal "$name local daemon/listener inactive; restarting only $svc"
  systemctl restart "$svc.service" || true
done
# Health and quarantine decisions remain Mihomo's responsibility; all services
# including x-ui, dispatcher, XUDP bridge and unaffected carrier are untouched.
