#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=dual-trust-mieru
D=/etc/$PROJECT/iran
BUNDLE=$D/mieru-bundle.json

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
probe(){
  local port=$1 label=$2 code
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 6 --max-time 12 \
    -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true)
  printf '%-28s %s\n' "$label" "HTTP=${code:-000}"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ -s "$BUNDLE" ]] || { echo "ERROR: missing $BUNDLE" >&2; exit 1; }
command -v jq >/dev/null || { echo 'ERROR: jq missing' >&2; exit 1; }

MIERU_IP=$(jq -r '.public_ip' "$BUNDLE")
MIERU_RANGE=$(jq -r '.port_range' "$BUNDLE")
[[ "$MIERU_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]] || { echo 'ERROR: invalid Mieru port range in bundle' >&2; exit 1; }
P1=${BASH_REMATCH[1]}; P2=${BASH_REMATCH[2]}

cat <<'EOF'
=== Mieru layered diagnostic ===
No credentials are printed by this script.
EOF

echo
echo '--- clock ---'
date -Is
if command -v timedatectl >/dev/null 2>&1; then
  printf 'NTPSynchronized='; timedatectl show -p NTPSynchronized --value 2>/dev/null || true
  printf 'TimeUSec='; timedatectl show -p TimeUSec --value 2>/dev/null || true
fi

echo
echo '--- services ---'
for s in dual-mieru-carrier dual-xudp-bridge dual-dispatcher dual-trust-client; do
  printf '%-24s active=' "$s"
  systemctl is-active "$s.service" 2>/dev/null || true
  systemctl show "$s.service" -p MainPID -p NRestarts -p ActiveEnterTimestamp --no-pager 2>/dev/null | sed 's/^/  /' || true
done

echo
echo '--- listeners ---'
for p in 7990 7992 7994; do
  if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
    echo "TCP/$p LISTEN"
  else
    echo "TCP/$p MISSING"
  fi
done

echo
echo '--- layer probes ---'
probe 7994 'DIRECT CARRIER 7994'
probe 7992 'MIERU + XUDP 7992'
probe 7990 'DUAL DISPATCHER 7990'

echo
echo "--- foreign TCP range reachability ($MIERU_RANGE) ---"
MIERU_IP="$MIERU_IP" P1="$P1" P2="$P2" python3 <<'PY'
import concurrent.futures, os, socket
ip=os.environ['MIERU_IP']; p1=int(os.environ['P1']); p2=int(os.environ['P2'])
def check(p):
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(2.0)
    try:
        s.connect((ip,p)); return p,'OPEN'
    except socket.timeout:
        return p,'TIMEOUT'
    except OSError as e:
        return p,f'ERROR:{getattr(e,"errno",None)}'
    finally:
        s.close()
with concurrent.futures.ThreadPoolExecutor(max_workers=12) as ex:
    rows=sorted(ex.map(check, range(p1,p2+1)))
for p,state in rows:
    print(f'{p}: {state}')
print('SUMMARY', ' '.join(f'{state}={sum(1 for _,s in rows if s==state)}' for state in sorted(set(s for _,s in rows))))
PY

echo
echo '--- recent carrier log ---'
journalctl -u dual-mieru-carrier.service --since '-15 min' --no-pager 2>/dev/null | tail -n 160 || true

echo
echo '--- recent XUDP bridge Mieru-related log ---'
journalctl -u dual-xudp-bridge.service --since '-15 min' --no-pager 2>/dev/null \
  | grep -Ei 'mieru|7994|timeout|failed|error|closed pipe|reset' | tail -n 160 || true

echo
echo '=== interpretation ==='
echo '7994 FAIL  -> failure is in Mieru carrier / foreign Mita / network-to-Mieru, before XUDP.'
echo '7994 OK + 7992 FAIL -> carrier works; investigate/restart dual-xudp-bridge.'
echo '7992 OK + 7990 FAIL -> investigate dispatcher health state.'
echo 'Many foreign ports TIMEOUT -> partial/full port-range reachability problem; local restart cannot fix it.'
echo 'All foreign ports OPEN but 7994 FAIL -> TCP reaches server; check foreign Mita status, clock and Mieru handshake/logs.'
