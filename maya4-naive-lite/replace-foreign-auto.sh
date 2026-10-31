#!/usr/bin/env bash
# One-input Maya4 foreign replacement helper.
# Asks only for the new foreign IPv4. The Naive hostname is fixed.
set -Eeuo pipefail

DOMAIN='naive4.biya2film.top'
REPO='https://github.com/aliiitavazoeiii-afk/frp-tunnel.git'
BRANCH='maya4-naive-lite'
ROOT=/etc/maya4-naive
LOCAL_REPLACE=/usr/local/lib/maya4-naive/replace-foreign.sh
HEALTH=/usr/local/sbin/maya4-health
SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=600 -o ControlPath=/run/maya4-foreign-%C)

log(){ printf '[maya4-replace] %s\n' "$*"; }
die(){ printf '[maya4-replace] ERROR: %s\n' "$*" >&2; exit 1; }
valid_ipv4(){
  local IFS=. a b c d extra o
  read -r a b c d extra <<<"$1"
  [[ -z ${extra:-} && -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} ]] || return 1
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] && ((10#$o <= 255)) || return 1
  done
}
close_master(){
  [[ -n "${NEW_IP:-}" ]] || return 0
  ssh "${SSH_OPTS[@]}" -O exit "root@$NEW_IP" >/dev/null 2>&1 || true
}

[[ $(id -u) -eq 0 ]] || exec sudo -- "$0" "$@"
umask 077
[[ -s "$ROOT/bundle.json" ]] || die 'current Maya4 bundle missing'
[[ -s "$ROOT/naive.json" && -s "$ROOT/xudp-router.json" ]] || die 'current Maya4 tunnel config missing'
[[ -x "$LOCAL_REPLACE" ]] || die 'local replacement engine missing; reinstall the Maya4 dashboard helper'
# Fail before SSH/package install if the local candidate engine is incomplete.
[[ -s /usr/local/lib/maya4-naive/common.sh ]] ||
  die 'local common.sh missing; run updated enable-replace-command.sh before trying again'
bash -n /usr/local/lib/maya4-naive/common.sh "$LOCAL_REPLACE" ||
  die 'local candidate helper syntax invalid'
[[ -x "$HEALTH" ]] || die 'Maya4 health helper missing'
for unit in x-ui maya4-naive-client maya4-xudp-router; do
  systemctl is-active --quiet "$unit.service" || die "inactive service before replacement: $unit"
done

OLD_IP=$(jq -r '.public_ip // empty' "$ROOT/bundle.json")
EMAIL=$(jq -r '.cert_email // empty' "$ROOT/bundle.json")
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] ||
  die 'cert_email is missing/invalid in the current Maya4 bundle'

NEW_IP=${1:-}
if [[ -z "$NEW_IP" ]]; then
  echo "Current foreign : ${OLD_IP:-unknown}"
  echo "Fixed domain    : $DOMAIN"
  read -r -p 'New foreign IPv4: ' NEW_IP
fi
valid_ipv4 "$NEW_IP" || die 'invalid new foreign IPv4'
[[ "$NEW_IP" != "$OLD_IP" ]] || die 'new foreign IP equals current foreign IP'

mapfile -t DNS_IPS < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
if ! printf '%s\n' "${DNS_IPS[@]:-}" | grep -Fxq "$NEW_IP"; then
  echo
  echo "DNS is not ready."
  echo "Set the DNS-only A record:"
  echo "  $DOMAIN -> $NEW_IP"
  echo "Current resolved IPv4: ${DNS_IPS[*]:-(none)}"
  echo
  echo 'No Maya4 service or configuration was changed.'
  exit 3
fi

TMP=$(mktemp /root/.maya4-auto-bundle.XXXXXX.json)
cleanup(){
  rc=$?
  close_master
  rm -f "$TMP"
  exit "$rc"
}
trap cleanup EXIT INT TERM

log "DNS OK: $DOMAIN -> $NEW_IP"
log 'Connecting to the fresh foreign VPS. Root password may be requested once.'
ssh "${SSH_OPTS[@]}" "root@$NEW_IP" 'echo NEW-MAYA4-FOREIGN-SSH=OK' ||
  die 'cannot SSH to the new foreign VPS'

log 'Installing Maya4 Naive endpoint on the new foreign VPS'
ssh "${SSH_OPTS[@]}" "root@$NEW_IP" bash -s -- "$NEW_IP" "$DOMAIN" "$EMAIL" "$REPO" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1
DOMAIN=$2
EMAIL=$3
REPO=$4
BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git ca-certificates >/dev/null
rm -rf /opt/frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/frp-tunnel >/dev/null
cd /opt/frp-tunnel/maya4-naive-lite
bash install-foreign.sh --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --non-interactive
REMOTE

log 'Fetching the private candidate bundle'
scp "${SSH_OPTS[@]}" "root@$NEW_IP:/root/maya4-naive-client.json" "$TMP" >/dev/null
chmod 0600 "$TMP"
jq -e --arg ip "$NEW_IP" --arg domain "$DOMAIN" '
  .version==1 and .kind=="maya4-naive" and
  .public_ip==$ip and .domain==$domain and .port==443 and
  .username and .password and .xudp_uuid
' "$TMP" >/dev/null || die 'new foreign returned an invalid bundle'
close_master

log 'Foreign install complete. Running isolated TCP + XUDP candidate tests before cutover.'
"$LOCAL_REPLACE" "$TMP"

log 'Running final Maya4 health'
"$HEALTH"
log "DONE: Maya4 now uses foreign $NEW_IP via $DOMAIN"
log "Old foreign $OLD_IP was not deleted."
trap - EXIT INT TERM
rm -f "$TMP"
