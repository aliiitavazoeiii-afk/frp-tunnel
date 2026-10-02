#!/usr/bin/env bash
set -Eeuo pipefail

HOST_OPT=/usr/local/sbin/dual-host-optimizer
STATE=/var/lib/dual-trust-mieru/maintenance
A_SERVICE=dual-trust-client
[[ -s /etc/dual-trust-mieru/iran/naive-bundle.json ]] && A_SERVICE=dual-naive-client
SERVICES=("$A_SERVICE" dual-mieru-carrier dual-xudp-bridge dual-dispatcher x-ui)

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo -- "$0" "$@"

snapshot_services(){
  local s
  for s in "${SERVICES[@]}"; do
    if systemctl show "$s.service" >/dev/null 2>&1; then
      printf '%s\t' "$s"
      systemctl show "$s.service" -p MainPID -p ActiveState -p NRestarts --value 2>/dev/null | paste -sd',' - || true
    fi
  done
}

human_disk(){ df -h / | awk 'NR==2{print $3" used / "$2" total ("$5")"}'; }

mkdir -p "$STATE"
chmod 0700 "$STATE"
TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN="$STATE/$TS"
mkdir -p "$RUN"
chmod 0700 "$RUN"

snapshot_services > "$RUN/services.before" || true
DISK_BEFORE=$(human_disk)

cat <<'TXT'
============================================================
 DUAL SAFE SERVER OPTIMIZER / MAINTENANCE
 No tunnel/x-ui restart, no route/firewall/MTU changes
============================================================
TXT
printf 'Disk before: %s\n\n' "$DISK_BEFORE"

if [[ -x "$HOST_OPT" ]]; then
  log 'Applying conservative host-only network optimizer...'
  "$HOST_OPT" --apply
else
  log 'WARNING: host optimizer is not installed; skipping sysctl optimization.'
fi

export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  log 'Refreshing APT package metadata (no package upgrade)...'
  apt-get update -y

  log 'Cleaning package download/cache data...'
  apt-get autoclean -y >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true

  if command -v apt >/dev/null 2>&1; then
    UPDATES=$(apt list --upgradable 2>/dev/null | sed '1d' | wc -l | tr -d ' ')
    echo "Pending package updates: ${UPDATES:-0} (not installed automatically)"
  fi
fi

if command -v journalctl >/dev/null 2>&1; then
  log 'Vacuuming journal entries older than 14 days...'
  journalctl --vacuum-time=14d >/dev/null 2>&1 || true
fi

log 'Removing old regular temp files (>7 days) from /tmp and /var/tmp...'
for tmp in /tmp /var/tmp; do
  [[ -d "$tmp" ]] || continue
  find "$tmp" -xdev -mindepth 1 -type f -mtime +7 -delete 2>/dev/null || true
  find "$tmp" -xdev -mindepth 1 -type d -empty -mtime +7 -delete 2>/dev/null || true
done

sync
snapshot_services > "$RUN/services.after" || true
DISK_AFTER=$(human_disk)

echo
echo '=== PRODUCTION SAFETY CHECK ==='
if cmp -s "$RUN/services.before" "$RUN/services.after"; then
  echo 'PASS: tunnel/x-ui PID, active state and restart counters are unchanged.'
else
  echo 'NOTICE: service state changed while maintenance was running.'
  echo 'The maintenance script did not issue tunnel/x-ui stop/restart commands.'
  echo '--- before ---'; cat "$RUN/services.before" || true
  echo '--- after ---'; cat "$RUN/services.after" || true
fi

echo
echo "Disk before: $DISK_BEFORE"
echo "Disk after : $DISK_AFTER"
echo "Run record : $RUN"
echo
echo 'SUCCESS: safe maintenance finished.'
echo 'No package upgrade, reboot, tunnel restart, x-ui restart, firewall, route or tunnel-config change was requested.'
