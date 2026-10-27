#!/usr/bin/env bash
# Guided fresh-Foreign provisioning and staged role-only replacement.
set -Eeuo pipefail
umask 077
ROLE=$1
B=$(cd -- "$(dirname "$0")" && pwd)
REPO=/opt/frp-tunnel-nm
[[ $EUID -eq 0 && -t 0 ]] || { echo 'Run interactively as root' >&2; exit 1; }
[[ $ROLE == naive || $ROLE == mieru ]] || exit 2
CONF=/etc/dual-trust-mieru/iran
BUNDLE=/etc/dual-trust-mieru/naive-mieru/bundle.json
TAG=xudp-trust
if [[ $ROLE == mieru ]]; then BUNDLE=$CONF/mieru-bundle.json;TAG=xudp-mieru;fi
[[ -s "$BUNDLE" ]] || { echo 'Missing current role bundle' >&2;exit 1; }
echo "REPLACE $ROLE: old Foreign remains untouched; only this role may restart after approval."
echo 'No users are moved until the isolated candidate passes and you confirm cutover.'
echo 'New Naive foreign needs its own DNS A record + TCP/443; Mieru needs TCP/20000-20020 (or current range).'
echo 'Verify the new VPS SSH host fingerprint independently; keep old VPS online for rollback.'
echo '1) Provision NEW foreign VPS by SSH'
echo '2) Use NEW foreign JSON bundle already on Iran'
read -r -p 'Option [1/2, anything else cancels]: ' OPT
TMP=''
IP=''
UUID=''
rssh(){ ssh -o StrictHostKeyChecking=ask -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPersist=240 -o ControlPath=/run/nm-foreign-%C "$@"; }
rscp(){ scp -o StrictHostKeyChecking=ask -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPersist=240 -o ControlPath=/run/nm-foreign-%C "$@"; }
clean(){
 [[ -z "$IP" ]] || rssh -O exit "root@$IP" >/dev/null 2>&1 || true
 [[ -z "$TMP" ]] || rm -f "$TMP"
 [[ -z "$UUID" ]] || rm -f "$UUID"
}
trap clean EXIT
if [[ $OPT == 1 ]]; then
  read -r -p 'New Foreign IPv4: ' IP
  python3 - "$IP" <<'PY'
import ipaddress,sys
assert ipaddress.ip_address(sys.argv[1]).version==4
PY
  OLD=$(jq -er '.public_ip' "$BUNDLE")
  [[ "$OLD" != "$IP" ]] || { echo 'ERROR: must be NEW independent Foreign' >&2;exit 1; }
  read -r -p 'Verify SSH host fingerprint independently. Confirm NEW EMPTY VPS [YES]: ' YES
  [[ "$YES" == YES ]] || exit 1
  SHA=$(git -C "$REPO" rev-parse HEAD)
  if [[ $ROLE == naive ]]; then
    read -r -p 'NEW Naive domain (different from old): ' DOMAIN
    read -r -p 'TLS email: ' EMAIL
    [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ && "$DOMAIN" == *.* && "$EMAIL" == *@*.* ]] || exit 1
    [[ "$DOMAIN" != "$(jq -r '.domain' "$BUNDLE")" ]] || { echo 'Use different domain' >&2;exit 1; }
    getent ahostsv4 "$DOMAIN" | awk '{print $1}' | grep -Fxq "$IP" || { echo 'DNS mismatch' >&2;exit 1; }
  else
    RANGE=$(jq -er '.port_range' "$BUNDLE")
    echo "Reusing Mieru port range $RANGE"
  fi
  rssh "root@$IP" 'echo FOREIGN_SSH_READY'
  UUID=$(mktemp /root/.nm-foreign-uuid.XXXXXXXX)
  jq -er --arg tag "$TAG" '.outbounds[]|select(.tag==$tag)|.settings.id' "$CONF/xudp.json" >"$UUID"
  rscp "$UUID" "root@$IP:/root/nm-foreign-xudp.uuid"
  if [[ $ROLE == naive ]]; then
    rssh "root@$IP" bash -s -- "$IP" "$DOMAIN" "$EMAIL" "$SHA" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; SHA=$4
test -s /root/nm-foreign-xudp.uuid
apt-get update -y >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates curl jq >/dev/null
test ! -e /opt/frp-tunnel-nm || exit 1
git clone --depth 1 -b naive-mieru-live-safe-v1 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel-nm >/dev/null
# The live Iran checkout is pinned; the remote branch may have advanced.
# Fetch the exact Iran-reviewed commit, not an unreviewed moving branch tip.
if [[ "$(git -C /opt/frp-tunnel-nm rev-parse HEAD)" != "$SHA" ]]; then
  git -C /opt/frp-tunnel-nm fetch --depth 1 origin "$SHA" >/dev/null
  git -C /opt/frp-tunnel-nm checkout --detach "$SHA" >/dev/null
fi
test "$(git -C /opt/frp-tunnel-nm rev-parse HEAD)" = "$SHA"
cd /opt/frp-tunnel-nm/dual-trust-mieru
bash install-foreign-lane3-naive.sh --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/nm-foreign-xudp.uuid --non-interactive
rm -f /root/nm-foreign-xudp.uuid
REMOTE
    SRC=/root/lane3-naive-client.json
  else
    rssh "root@$IP" bash -s -- "$IP" "$RANGE" "$SHA" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; SHA=$3
test -s /root/nm-foreign-xudp.uuid
apt-get update -y >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates curl jq >/dev/null
test ! -e /opt/frp-tunnel-nm || exit 1
git clone --depth 1 -b naive-mieru-live-safe-v1 https://github.com/aliiitavazoeiii-afk/frp-tunnel.git /opt/frp-tunnel-nm >/dev/null
# The live Iran checkout is pinned; the remote branch may have advanced.
# Fetch the exact Iran-reviewed commit, not an unreviewed moving branch tip.
if [[ "$(git -C /opt/frp-tunnel-nm rev-parse HEAD)" != "$SHA" ]]; then
  git -C /opt/frp-tunnel-nm fetch --depth 1 origin "$SHA" >/dev/null
  git -C /opt/frp-tunnel-nm checkout --detach "$SHA" >/dev/null
fi
test "$(git -C /opt/frp-tunnel-nm rev-parse HEAD)" = "$SHA"
cd /opt/frp-tunnel-nm/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/nm-foreign-xudp.uuid --non-interactive
rm -f /root/nm-foreign-xudp.uuid
REMOTE
    SRC=/root/dual-mieru-client.json
  fi
  TMP=$(mktemp /root/.nm-new-foreign.XXXXXXXX.json)
  rscp "root@$IP:$SRC" "$TMP"
  chmod 0600 "$TMP"
  FILE=$TMP
elif [[ $OPT == 2 ]]; then
  read -r -p 'Absolute path to NEW foreign bundle JSON: ' FILE
  [[ "$FILE" == /* && -s "$FILE" ]] || { echo 'Bundle missing' >&2;exit 1; }
else
  exit 0
fi
python3 "$B/nm-replace.py" prepare "$ROLE" "$FILE"
echo 'Candidate passed. Existing role connections WILL briefly disconnect on cutover.'
read -r -p "Type REPLACE-$ROLE to cut over (otherwise leave staged): " APPROVE
if [[ "$APPROVE" == "REPLACE-$ROLE" ]]; then
  UPPER=$(printf %s "$ROLE" | tr '[:lower:]' '[:upper:]')
  python3 "$B/nm-replace.py" cutover "$ROLE" --confirm "REPLACE-$UPPER"
fi
