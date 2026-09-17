#!/usr/bin/env bash
set -Eeuo pipefail

B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC=${1:-}
C=/etc/anytls-tunnel
DST=$C/bucket5-transports-canary.json

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -n "$SRC" && -f "$SRC" ]] || die "usage: sudo bash $0 /path/to/bucket5-f4-canary-client.json"
[[ -f "$B/bucket5-transport-probe.sh" && -f "$B/bucket5-transport-ab.py" ]] || die "helper files missing"
command -v jq >/dev/null 2>&1 || die "jq missing"

jq -e '.version==1 and (.nodes.F4.carriers|type=="object") and (.nodes.F4.carriers|length>=2)' "$SRC" >/dev/null || die "invalid canary client bundle"
mkdir -p "$C" /var/lib/anytls-tunnel/transport-ab
chmod 0700 /var/lib/anytls-tunnel/transport-ab
install -o root -g root -m 0600 "$SRC" "$DST"
install -o root -g root -m 0755 "$B/bucket5-transport-probe.sh" /usr/local/sbin/anytls-bucket5-transport-probe
install -o root -g root -m 0755 "$B/bucket5-transport-ab.py" /usr/local/sbin/anytls-bucket5-transport-ab

log "Installed isolated transport canary tools. No service was restarted or reconfigured."
log "Config: $DST"
log "Try: sudo anytls-bucket5-transport-probe F4 restls"
log "Then: sudo anytls-bucket5-transport-probe F4 shadow"
log "Then: sudo anytls-bucket5-transport-probe F4 reality"
