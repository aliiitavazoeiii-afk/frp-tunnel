#!/usr/bin/env bash
set -Eeuo pipefail
C=/etc/anytls-tunnel
E=$C/bucket5.env
XDB=/etc/x-ui/x-ui.db
S=/var/lib/anytls-tunnel/backups
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$E" ]] || die "bucket5 is not installed"
source "$E"
[[ "$PROFILE" == maya1 || "$PROFILE" == maya3 ]] || die "bad PROFILE"
systemctl is-active --quiet x-ui || die "x-ui inactive"
systemctl is-active --quiet anytls-xudp-bridge || die "XUDP inactive"
python3 /usr/local/sbin/anytls-bucket5-xui audit
mkdir -p "$S"
B=$S/bucket5-reconcile-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$B"
cp -a "$XDB" "$B/x-ui.db"
restore(){
  log "ROLLBACK x-ui DB"
  systemctl stop x-ui >/dev/null 2>&1 || true
  cp -a "$B/x-ui.db" "$XDB"
  systemctl start x-ui >/dev/null 2>&1 || true
}
trap 'rc=$?; if ((rc!=0)); then restore; fi' EXIT
log "Applying user->bucket mapping update; this restarts x-ui once"
systemctl stop x-ui
python3 /usr/local/sbin/anytls-bucket5-xui sync "$PROFILE"
systemctl start x-ui
sleep 4
systemctl is-active --quiet x-ui || die "x-ui failed"
python3 /usr/local/sbin/anytls-bucket5-xui verify "$PROFILE"
trap - EXIT
log "SUCCESS: new/changed users reconciled into stable buckets"
