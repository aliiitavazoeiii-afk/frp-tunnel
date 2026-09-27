#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:-}
OLD_BUNDLE=${2:-}
D=/etc/dual-trust-mieru
BIN=/usr/local/lib/dual-trust-mieru

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$ROLE" == trust || "$ROLE" == mieru ]] || die "usage: $0 trust|mieru /root/old-iran-role-bundle.json"
[[ -s "$OLD_BUNDLE" ]] || die "old Iran bundle missing: $OLD_BUNDLE"

if [[ "$ROLE" == trust ]]; then
  NEW_BUNDLE=/root/dual-trust-client.json
  XRAY="$D/trust/xray.json"
  SERVICE=dual-xudp-trust.service
  EXPECT_KIND=trust
else
  NEW_BUNDLE=/root/dual-mieru-client.json
  XRAY="$D/mieru/xray.json"
  SERVICE=dual-xudp-mieru.service
  EXPECT_KIND=mieru
fi

[[ -s "$NEW_BUNDLE" ]] || die "new foreign client bundle missing: $NEW_BUNDLE"
[[ -s "$XRAY" ]] || die "new foreign XUDP config missing: $XRAY"
[[ -x "$BIN/xray" ]] || die "xray binary missing: $BIN/xray"

jq -e --arg k "$EXPECT_KIND" '.version==1 and .kind==$k and .xudp_uuid' "$OLD_BUNDLE" >/dev/null || die "invalid old Iran $ROLE bundle"
jq -e --arg k "$EXPECT_KIND" '.version==1 and .kind==$k and .xudp_uuid' "$NEW_BUNDLE" >/dev/null || die "invalid new foreign $ROLE bundle"

OLD_UUID=$(jq -r '.xudp_uuid' "$OLD_BUNDLE")
[[ -n "$OLD_UUID" && "$OLD_UUID" != null ]] || die "old live UUID missing"

BK="${XRAY}.before-preserve-$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$XRAY" "$BK"
cp -a "$NEW_BUNDLE" "${NEW_BUNDLE}.before-preserve"

TMP=$(mktemp "${XRAY}.XXXXXX")
jq --arg uuid "$OLD_UUID" '(.inbounds[] | select(.tag=="xudp-in").settings.users[0].id) = $uuid' "$XRAY" > "$TMP"
chmod 0600 "$TMP"
"$BIN/xray" run -test -c "$TMP" >/dev/null
mv "$TMP" "$XRAY"

TMPB=$(mktemp "${NEW_BUNDLE}.XXXXXX")
jq --arg uuid "$OLD_UUID" '.xudp_uuid = $uuid' "$NEW_BUNDLE" > "$TMPB"
chmod 0600 "$TMPB"
mv "$TMPB" "$NEW_BUNDLE"

systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE" || die "$SERVICE inactive after UUID preservation"
ss -H -ltn 'sport = :2443' 2>/dev/null | grep -q '127.0.0.1:2443' || die "loopback XUDP/2443 missing"

NEW_UUID=$(jq -r '.xudp_uuid' "$NEW_BUNDLE")
SERVER_UUID=$(jq -r '.inbounds[] | select(.tag=="xudp-in").settings.users[0].id' "$XRAY")
[[ "$NEW_UUID" == "$OLD_UUID" && "$SERVER_UUID" == "$OLD_UUID" ]] || die "UUID preservation verification failed"

log "SUCCESS: new $ROLE foreign now preserves the current Iran XUDP UUID"
log "No credentials or UUID were printed"
log "Updated client bundle remains at $NEW_BUNDLE"
log "Foreign config backup: $BK"
