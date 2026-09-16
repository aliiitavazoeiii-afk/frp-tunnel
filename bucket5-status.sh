#!/usr/bin/env bash
set -Eeuo pipefail
C=/etc/anytls-tunnel
D=$C/deploy.env
E=$C/bucket5.env
S=/var/lib/anytls-tunnel/bucket5-state.json
M=/var/lib/anytls-tunnel/bucket5-users.json
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ -f "$D" && -f "$E" ]] || die "bucket5 not installed"
source "$D"
source "$E"
API="http://127.0.0.1:${LOCAL_CONTROLLER_PORT}"
AUTH=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")
echo "Bucket5 status profile=$PROFILE"
echo
echo "--- scheduler ---"
systemctl is-active anytls-bucket5-scheduler.timer || true
echo
echo "--- user buckets ---"
if [[ -f "$M" ]]; then
  jq -r '.users | to_entries | group_by(.value) | map({bucket:(.[0].value),users:length}) | sort_by(.bucket)[] | "BUCKET-\(.bucket): \(.users) users"' "$M"
fi
echo
echo "--- selector mapping ---"
for n in $(seq 1 10); do
  i=$(printf '%02d' "$n")
  printf 'BUCKET-%s -> ' "$i"
  curl -fsS "${AUTH[@]}" "$API/proxies/BUCKET-$i" | jq -r '.now // "?"'
done
echo
echo "--- node health/delay ---"
for n in F1 F2 F3 F4 F5; do
  out=$(curl -sS -G "${AUTH[@]}" --data-urlencode 'url=https://www.gstatic.com/generate_204' --data-urlencode 'timeout=8000' --data-urlencode 'expected=204' "$API/proxies/$n/delay" || true)
  printf '%s: %s\n' "$n" "$out"
done
echo
echo "--- active connections ---"
curl -fsS "${AUTH[@]}" "$API/connections" | jq '{
  F1: [.connections[] | select(.chains | index("F1"))] | length,
  F2: [.connections[] | select(.chains | index("F2"))] | length,
  F3: [.connections[] | select(.chains | index("F3"))] | length,
  F4: [.connections[] | select(.chains | index("F4"))] | length,
  F5: [.connections[] | select(.chains | index("F5"))] | length,
  total: (.connections | length)
}'
echo
echo "--- scheduler state ---"
[[ -f "$S" ]] && jq '{health,mapping,last_bucket_bps,last_bucket_active,last_move}' "$S" || echo "no state yet"
