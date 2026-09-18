#!/usr/bin/env bash
set -Eeuo pipefail

kind=${1:-}
case "$kind" in
  trust)
    CFG=/etc/dual-trust-mieru/trust/xray.json
    SERVICE=dual-xudp-trust.service
    BUNDLE=/root/dual-trust-client.json
    ;;
  mieru)
    CFG=/etc/dual-trust-mieru/mieru/xray.json
    SERVICE=dual-xudp-mieru.service
    BUNDLE=/root/dual-mieru-client.json
    ;;
  *)
    echo "usage: $0 trust|mieru" >&2
    exit 2
    ;;
esac

XRAY=/usr/local/lib/dual-trust-mieru/xray
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -s "$CFG" ]] || { echo "missing config: $CFG" >&2; exit 1; }
[[ -x "$XRAY" ]] || { echo "missing xray: $XRAY" >&2; exit 1; }
[[ -s "$BUNDLE" ]] || { echo "missing bundle: $BUNDLE" >&2; exit 1; }

before=$(sha256sum "$BUNDLE" | awk '{print $1}')
backup="${CFG}.bak.$(date +%Y%m%d-%H%M%S)"
tmp="${CFG%.json}.candidate.$$.json"
trap 'rm -f "$tmp"' EXIT

cp -a "$CFG" "$backup"

jq '
  (.inbounds[] | select(.protocol=="vless").settings) |=
  (
    if has("clients") then
      .users = .clients | del(.clients)
    else
      .
    end
  )
' "$CFG" > "$tmp"
chmod 600 "$tmp"

"$XRAY" run -test -format=json -c "$tmp"
install -m 600 "$tmp" "$CFG"

systemctl restart "$SERVICE"
sleep 1
systemctl is-active --quiet "$SERVICE"
ss -H -ltn 'sport = :2443' | grep -q '127.0.0.1:2443'

after=$(sha256sum "$BUNDLE" | awk '{print $1}')
[[ "$before" == "$after" ]] || { echo "bundle hash changed unexpectedly" >&2; exit 1; }

printf 'SUCCESS: %s XUDP VLESS schema repaired\n' "$kind"
printf 'backup=%s\n' "$backup"
printf 'bundle_sha_unchanged=%s\n' "$after"
