#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Final attach wrapper: the historical attach script requires dual-probe.sh to
# be executable. Fresh Git checkouts may preserve it as a non-executable text
# file, so normalize only this repo helper before running the audited attach.
[[ -s "$B/dual-probe.sh" ]] || { echo "ERROR: missing $B/dual-probe.sh" >&2; exit 1; }
chmod 0755 "$B/dual-probe.sh"
exec bash "$B/attach-xui.sh" "$@"
