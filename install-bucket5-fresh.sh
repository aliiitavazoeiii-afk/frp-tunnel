#!/usr/bin/env bash
set -Eeuo pipefail

B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROFILE=${1:-}
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ "$PROFILE" == maya1 || "$PROFILE" == maya3 ]] || { echo "ERROR: usage: sudo bash install-bucket5-fresh.sh maya1|maya3" >&2; exit 2; }
[[ -f "$B/install-bucket5.sh" ]] || { echo "ERROR: install-bucket5.sh missing" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 missing" >&2; exit 1; }

R="$B/.install-bucket5-fresh-runtime.sh"
cleanup(){ rm -f "$R"; }
trap cleanup EXIT
cp -a "$B/install-bucket5.sh" "$R"

RUNTIME="$R" python3 <<'PY'
import os
from pathlib import Path
p=Path(os.environ['RUNTIME'])
s=p.read_text()

# Fresh-five: never reuse old Foreign addresses/credentials.
start=s.find('if [[ "$PROFILE" == maya1 ]]; then')
end=s.find('\nprompt_node(){', start)
if start < 0 or end < 0:
    raise SystemExit('ERROR: could not locate credential-reuse block; refusing to run')
replacement='log "FRESH-FIVE mode: ignoring all previous Foreign node addresses/credentials; F1..F5 will be entered explicitly"\n'
s=s[:start]+replacement+s[end:]

# Actual five-node topology installed by the user:
# F1/F2/F3 = foreign-a (ShadowTLS), F4/F5 = foreign-b (ResTLS).
old='TYPE[F1]=shadow; TYPE[F2]=restls; TYPE[F3]=shadow; TYPE[F4]=restls; TYPE[F5]=shadow'
new='TYPE[F1]=shadow; TYPE[F2]=shadow; TYPE[F3]=shadow; TYPE[F4]=restls; TYPE[F5]=restls'
if old not in s:
    raise SystemExit('ERROR: expected node-type declaration not found; refusing to run')
s=s.replace(old,new,1)

# Covers intentionally alternate independently of transport type:
# F1 cloudflare, F2 microsoft, F3 cloudflare, F4 microsoft, F5 cloudflare.
old_cover='[[ "${TYPE[$n]}" == shadow ]] && default_cover=www.cloudflare.com || default_cover=www.microsoft.com'
new_cover='case "$n" in F1|F3|F5) default_cover=www.cloudflare.com ;; F2|F4) default_cover=www.microsoft.com ;; esac'
if old_cover not in s:
    raise SystemExit('ERROR: expected cover-default declaration not found; refusing to run')
s=s.replace(old_cover,new_cover,1)

p.write_text(s)
PY
chmod 0700 "$R"

echo "============================================================"
echo "Bucket5 FRESH-FIVE migration"
echo "Profile: $PROFILE"
echo "Topology: F1/F2/F3=ShadowTLS, F4/F5=ResTLS"
echo "Covers:   F1/F3/F5=Cloudflare, F2/F4=Microsoft"
echo "All F1..F5 addresses and credentials will be requested anew."
echo "Existing x-ui users/UUIDs are preserved."
echo "============================================================"

bash "$R" "$PROFILE"
