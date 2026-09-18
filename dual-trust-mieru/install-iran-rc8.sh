#!/usr/bin/env bash
set -Eeuo pipefail

B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE="$B/install-iran.sh"
TRUST_BUNDLE=${1:-}
MIERU_BUNDLE=${2:-}
HOSTNAME=xudp-trust.internal
HOST_MARKER='# dual-trust-mieru trust-xudp-hostname'
HOST_LINE="127.0.0.1 $HOSTNAME $HOST_MARKER"
TMP=$(mktemp /tmp/dual-install-iran-rc8.XXXXXX.sh)
HOST_ADDED=0
SUCCESS=0

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
[[ -x "$BASE" || -f "$BASE" ]] || { echo "missing base installer: $BASE" >&2; exit 1; }
[[ -f "$TRUST_BUNDLE" && -f "$MIERU_BUNDLE" ]] || {
  echo "usage: $0 /root/dual-trust-client.json /root/dual-mieru-client.json" >&2
  exit 2
}

cleanup(){
  rc=$?
  rm -f "$TMP"
  if (( SUCCESS == 0 && HOST_ADDED == 1 )); then
    python3 - "$HOST_LINE" <<'PY'
import sys
line=sys.argv[1]
p='/etc/hosts'
with open(p, encoding='utf-8') as f:
    lines=f.read().splitlines()
lines=[x for x in lines if x.strip()!=line.strip()]
with open(p,'w',encoding='utf-8') as f:
    f.write('\n'.join(lines)+'\n')
PY
  fi
  exit "$rc"
}
trap cleanup EXIT

if ! getent ahostsv4 "$HOSTNAME" 2>/dev/null | awk '{print $1}' | grep -Fxq '127.0.0.1'; then
  printf '%s\n' "$HOST_LINE" >> /etc/hosts
  HOST_ADDED=1
fi

getent ahostsv4 "$HOSTNAME" | awk '{print $1}' | grep -Fxq '127.0.0.1' || {
  echo "ERROR: $HOSTNAME does not resolve to 127.0.0.1" >&2
  exit 1
}

python3 - "$BASE" "$TMP" <<'PY'
import sys
src,dst=sys.argv[1:]
s=open(src,encoding='utf-8').read()
old='{"tag":"xudp-trust","protocol":"vless","settings":{"address":"127.0.0.1","port":2443'
new='{"tag":"xudp-trust","protocol":"vless","settings":{"address":"xudp-trust.internal","port":2443'
count=s.count(old)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one Trust XUDP loopback target, found {count}')
s=s.replace(old,new,1)
open(dst,'w',encoding='utf-8').write(s)
PY
chmod 0700 "$TMP"

printf '[%s] RC8: Trust XUDP destination uses hostname %s (local hosts -> 127.0.0.1)\n' "$(date '+%F %T')" "$HOSTNAME"

bash "$TMP" "$TRUST_BUNDLE" "$MIERU_BUNDLE"
SUCCESS=1
trap - EXIT
rm -f "$TMP"
echo "SUCCESS: rc8 Iran hostname workaround installed"
