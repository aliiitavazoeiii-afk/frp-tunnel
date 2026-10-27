#!/usr/bin/env bash
# Read-only resource/connection diagnostics for Iran Naive client or foreign Caddy.
# No credentials, raw socket addresses, client request logs, or config contents.
set -Eeuo pipefail
umask 077
MODE=$(printf '%s' "$@" | head -c 16)
[[ $EUID -eq 0 ]] || { echo "Run as root";exit 1; }
[[ $MODE == iran || $MODE == foreign ]] || { echo "Usage: bash nm-naive-inspect.sh {iran|foreign}"; exit 2; }
echo "=== NAIVE RESOURCE SNAPSHOT: $MODE ==="
date -u '+UTC %Y-%m-%dT%H:%M:%SZ'
uname -m
uptime
free -m
echo "=== Load/pressure ==="
for file in /proc/pressure/{cpu,memory,io}; do
  if [[ -f $file ]];then echo "$file";cat "$file";fi
done
echo "=== System TCP summary (no endpoint addresses) ==="
ss -s
echo "=== Kernel configuration (read-only) ==="
for key in net.ipv4.tcp_congestion_control net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_retries2 net.ipv4.tcp_slow_start_after_idle;do
  sysctl "$key" 2>/dev/null || true
done
echo "=== System network counters since boot (not per service) ==="
nstat -az 2>/dev/null | grep -E '^(TcpRetransSegs|TcpExtTCPTimeouts|TcpExtTCPSynRetrans|TcpExtTCPFastRetrans|TcpExtTCPAbortOnTimeout|TcpExtListenOverflows|TcpExtListenDrops|TcpExtTCPLossProbes|TcpExtTCPBacklogDrop)[[:space:]]' || true
echo "=== Relevant service counters ==="
if [[ $MODE == iran ]];then
  services="nm-naive-client nm-ha dual-xudp-bridge dual-dispatcher dual-mieru-carrier"
else
  services="lane3-naive-endpoint lane3-xudp"
fi
for s in $services;do
  echo "--- $s ---"
  systemctl show "$s.service" -p ActiveState -p MainPID -p NRestarts -p ActiveEnterTimestamp -p MemoryCurrent -p TasksCurrent -p LimitNOFILE --no-pager 2>/dev/null || true
  pid=$(systemctl show "$s.service" -p MainPID --value 2>/dev/null || echo 0)
  if [[ $pid =~ ^[0-9]+$ && $pid -gt 0 && -d /proc/$pid ]];then
    printf 'open_fd_count='
    find "/proc/$pid/fd" -maxdepth 1 -type l 2>/dev/null | wc -l
    ps -p "$pid" -o pid=,etimes=,rss=,%cpu=,nlwp= 2>/dev/null || true
    awk '/VmRSS:|VmPeak:|Threads:|FDSize:/{print}' "/proc/$pid/status" 2>/dev/null || true
  fi
done
if [[ $MODE == foreign ]];then
  echo "=== Aggregate inbound TCP 443 sessions (no client IPs) ==="
  ss -Htan state established '( sport = :443 )' 2>/dev/null | wc -l
else
  echo "=== HA current status (no credential material) ==="
  if [[ -f /var/lib/dual-trust-mieru/naive-mieru/ha/status.json ]];then
    python3 - <<'PY'
import json,pathlib
d=json.loads(pathlib.Path('/var/lib/dual-trust-mieru/naive-mieru/ha/status.json').read_text())
print('updated_at=',d.get('updated_at'),'policy=',d.get('policy'),'selection=',d.get('pool_selection'))
for role,r in d.get('roles',{}).items():
 print(role,'status=',r.get('status'),'restart=',r.get('last_restart_at'),
       'incidents=',r.get('incident'))
PY
  fi
fi
echo "INSPECT COMPLETE: read-only; no service modifications."
