#!/usr/bin/env bash
set -Eeuo pipefail

B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NODE=${1:-}
SRC=${2:-}
C=/etc/anytls-tunnel
DST=$C/bucket5-transports-canary.json

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$NODE" =~ ^F[1-5]$ ]] || die "usage: sudo bash $0 F1..F5 /path/to/client-bundle.json"
[[ -n "$SRC" && -f "$SRC" ]] || die "missing client bundle"
[[ -f "$B/bucket5-transport-probe.sh" && -f "$B/bucket5-transport-ab.py" ]] || die "helper files missing"
command -v jq >/dev/null 2>&1 || die "jq missing"

jq -e --arg n "$NODE" '.version>=2 and (.nodes[$n].carriers|type=="object") and (.nodes[$n].carriers|length>=3)' "$SRC" >/dev/null || die "invalid $NODE canary client bundle"
mkdir -p "$C" /var/lib/anytls-tunnel/transport-ab
chmod 0700 /var/lib/anytls-tunnel/transport-ab
TMP=$(mktemp /tmp/bucket5-transports.XXXXXX)
trap 'rm -f "$TMP"' EXIT
chmod 0600 "$TMP"
if [[ -f "$DST" ]]; then
  jq -s '{version: ([.[].version] | max), nodes: (.[0].nodes + .[1].nodes)}' "$DST" "$SRC" >"$TMP"
else
  cp "$SRC" "$TMP"
fi
jq -e --arg n "$NODE" '.nodes[$n].carriers.primary and .nodes[$n].carriers.control and .nodes[$n].carriers.alternate and .nodes[$n].carriers.reality' "$TMP" >/dev/null || die "merged config invalid"
install -o root -g root -m 0600 "$TMP" "$DST"
install -o root -g root -m 0755 "$B/bucket5-transport-probe.sh" /usr/local/sbin/anytls-bucket5-transport-probe
install -o root -g root -m 0755 "$B/bucket5-transport-ab.py" /usr/local/sbin/anytls-bucket5-transport-ab

log "Installed isolated $NODE transport canary tools. No service was restarted or reconfigured."
log "Config: $DST"
log "Probe baseline:  sudo anytls-bucket5-transport-probe $NODE primary"
log "Probe port ctrl: sudo anytls-bucket5-transport-probe $NODE control"
log "Probe alternate: sudo anytls-bucket5-transport-probe $NODE alternate"
log "Probe Reality:   sudo anytls-bucket5-transport-probe $NODE reality"
