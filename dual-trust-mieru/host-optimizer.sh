#!/usr/bin/env bash
set -Eeuo pipefail

MODE=${1:---audit}
STATE=/var/lib/dual-host-optimizer
CONF=/etc/sysctl.d/99-dual-host-optimizer.conf
SERVICES=(dual-trust-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher x-ui)

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"; }

SYSCTLS=(
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_slow_start_after_idle
  net.core.rmem_max
  net.core.wmem_max
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.core.netdev_max_backlog
  net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_syncookies
  vm.swappiness
)

service_snapshot(){
  for s in "${SERVICES[@]}"; do
    if systemctl list-unit-files "$s.service" >/dev/null 2>&1 || systemctl status "$s.service" >/dev/null 2>&1; then
      printf '%s\t' "$s"
      systemctl show "$s.service" -p MainPID -p ActiveState -p NRestarts --value 2>/dev/null | paste -sd',' - || true
    fi
  done
}

sysctl_exists(){ sysctl -n "$1" >/dev/null 2>&1; }

show_sysctls(){
  for k in "${SYSCTLS[@]}"; do
    if sysctl_exists "$k"; then
      printf '%-40s = %s\n' "$k" "$(sysctl -n "$k")"
    fi
  done
  printf '%-40s = %s\n' 'net.ipv4.tcp_available_congestion_control' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unavailable)"
}

audit(){
  echo '=== HOST OPTIMIZER AUDIT (read-only) ==='
  echo "time=$(date -Is)"
  echo "kernel=$(uname -r)"
  echo "cpus=$(nproc 2>/dev/null || echo unknown)"
  uptime
  echo
  free -h || true
  echo
  df -h / || true

  IFACE=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
  echo
  echo "=== NETWORK INTERFACE ==="
  echo "default_iface=${IFACE:-unknown}"
  if [[ -n "${IFACE:-}" ]]; then
    ip -s -s link show dev "$IFACE" || true
    echo
    tc qdisc show dev "$IFACE" 2>/dev/null || true
  fi

  echo
  echo '=== TCP / SOCKETS ==='
  ss -s || true
  echo
  show_sysctls

  echo
  echo '=== SOFTNET ==='
  awk '
    {p+=strtonum("0x"$1); d+=strtonum("0x"$2); t+=strtonum("0x"$3)}
    END{printf "processed=%d dropped=%d time_squeeze=%d\n",p,d,t}
  ' /proc/net/softnet_stat 2>/dev/null || true

  echo
  echo '=== TUNNEL SERVICE STATE (read-only) ==='
  service_snapshot || true

  echo
  echo '=== NOTES ==='
  echo '- audit changes nothing'
  echo '- optimizer never changes MTU, routes, firewall, tunnel config, x-ui config, or interface qdisc'
  echo '- optimizer never stops/restarts tunnel or x-ui services'
}

snapshot_sysctls(){
  local out=$1 k
  : > "$out"
  chmod 0600 "$out"
  for k in "${SYSCTLS[@]}"; do
    if sysctl_exists "$k"; then
      printf '%s\t%s\n' "$k" "$(sysctl -n "$k")" >> "$out"
    fi
  done
}

write_conf(){
  local use_bbr=$1
  cat > "$CONF" <<'EOF2'
# Dual Trust/Mieru host-only conservative optimizer.
# NO tunnel/x-ui config, route, firewall, MTU or live interface-qdisc changes.
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
vm.swappiness = 10
EOF2
  if [[ "$use_bbr" == 1 ]]; then
    cat >> "$CONF" <<'EOF2'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF2
  fi
  chmod 0644 "$CONF"
}

apply_one(){
  local k=$1 v=$2
  if ! sysctl_exists "$k"; then
    log "SKIP unsupported sysctl: $k"
    return 0
  fi
  if sysctl -w "$k=$v" >/dev/null 2>&1; then
    log "SET $k=$v"
  else
    log "WARN could not set $k; leaving kernel value unchanged"
  fi
}

apply(){
  require_root
  mkdir -p "$STATE"; chmod 0700 "$STATE"
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  BK="$STATE/$TS"
  mkdir -p "$BK"; chmod 0700 "$BK"

  snapshot_sysctls "$BK/sysctl.before"
  service_snapshot > "$BK/services.before" || true
  if [[ -f "$CONF" ]]; then cp -a "$CONF" "$BK/sysctl.conf.before"; else : > "$BK/no_previous_conf"; fi

  log "Snapshot: $BK"
  log 'No tunnel/x-ui service will be restarted or stopped.'

  # Load optional kernel modules only. This does not restart services or replace the live NIC qdisc.
  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe sch_fq >/dev/null 2>&1 || true
  AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  USE_BBR=0
  if grep -qw bbr <<<"$AVAILABLE"; then USE_BBR=1; fi

  write_conf "$USE_BBR"

  apply_one net.ipv4.tcp_mtu_probing 1
  apply_one net.ipv4.tcp_slow_start_after_idle 0
  apply_one net.core.rmem_max 16777216
  apply_one net.core.wmem_max 16777216
  apply_one net.ipv4.tcp_rmem '4096 131072 16777216'
  apply_one net.ipv4.tcp_wmem '4096 16384 16777216'
  apply_one net.core.netdev_max_backlog 8192
  apply_one net.core.somaxconn 4096
  apply_one net.ipv4.tcp_max_syn_backlog 8192
  apply_one net.ipv4.tcp_syncookies 1
  apply_one vm.swappiness 10

  if (( USE_BBR == 1 )); then
    apply_one net.core.default_qdisc fq
    apply_one net.ipv4.tcp_congestion_control bbr
    log 'BBR is available and selected as the default for new TCP sockets.'
    log 'The existing interface qdisc was intentionally NOT replaced, so active traffic is not disturbed.'
  else
    log "BBR unavailable on this kernel; current congestion control preserved: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  fi

  ln -sfn "$BK" "$STATE/latest"
  service_snapshot > "$BK/services.after" || true

  echo
  echo '=== SERVICE PID SAFETY CHECK ==='
  if cmp -s "$BK/services.before" "$BK/services.after"; then
    echo 'PASS: tunnel/x-ui service PID/state/restart counters unchanged.'
  else
    echo 'NOTICE: service snapshot changed while optimizer ran; optimizer issued no stop/restart commands.'
    echo '--- before ---'; cat "$BK/services.before" || true
    echo '--- after ---'; cat "$BK/services.after" || true
  fi

  echo
  show_sysctls
  echo
  echo 'SUCCESS: host-only optimizer applied without tunnel/x-ui restart.'
  echo "Rollback: sudo $0 --rollback"
}

rollback(){
  require_root
  [[ -L "$STATE/latest" ]] || die "no optimizer snapshot found at $STATE/latest"
  BK=$(readlink -f "$STATE/latest")
  [[ -f "$BK/sysctl.before" ]] || die "snapshot missing sysctl.before"

  log "Restoring sysctl snapshot from $BK"
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    sysctl -w "$k=$v" >/dev/null 2>&1 || log "WARN could not restore $k"
  done < "$BK/sysctl.before"

  if [[ -f "$BK/sysctl.conf.before" ]]; then
    cp -a "$BK/sysctl.conf.before" "$CONF"
  else
    rm -f "$CONF"
  fi

  echo 'SUCCESS: host optimizer sysctls restored; no tunnel/x-ui restart was performed.'
}

housekeeping(){
  require_root
  log 'Housekeeping only: no service stops/restarts.'
  command -v journalctl >/dev/null 2>&1 && journalctl --vacuum-time=14d >/dev/null 2>&1 || true
  command -v apt-get >/dev/null 2>&1 && apt-get clean >/dev/null 2>&1 || true
  find /tmp -xdev -type f -atime +7 -delete 2>/dev/null || true
  echo 'SUCCESS: conservative disk/cache housekeeping complete.'
}

case "$MODE" in
  --audit) audit ;;
  --apply) apply ;;
  --rollback) rollback ;;
  --housekeeping) housekeeping ;;
  *) die "usage: $0 [--audit|--apply|--rollback|--housekeeping]" ;;
esac
