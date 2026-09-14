#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC="$BASE_DIR/upgrade-xudp-v2.sh"
TMP="$BASE_DIR/.upgrade-xudp-v3-runtime.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ -f "$SRC" ]] || { echo "ERROR: upgrade-xudp-v2.sh not found" >&2; exit 1; }

# Xray detects config format from filename extension. The v2 script used
# /etc/anytls-tunnel/xudp-bridge.json.new, which has a final .new suffix and
# makes Xray fail before parsing JSON. Keep the temporary file ending in .json.
sed 's|local out="${BRIDGE_CONFIG}\.new"|local out="${CONFIG_DIR}/xudp-bridge.new.json"|' "$SRC" > "$TMP"
chmod 0700 "$TMP"
trap 'rm -f "$TMP"' EXIT

bash "$TMP" "$@"
