#!/usr/bin/env bash
set -Eeuo pipefail

B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROFILE=${1:-}
E=/etc/anytls-tunnel/bucket5.env
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ "$PROFILE" == maya1 || "$PROFILE" == maya3 ]] || { echo "ERROR: usage: sudo bash install-bucket5-resume.sh maya1|maya3" >&2; exit 2; }
[[ -f "$E" ]] || { echo "ERROR: saved $E not found; use install-bucket5-fresh.sh instead" >&2; exit 1; }
[[ -f "$B/install-bucket5.sh" && -f "$B/bucket5-runtime-patch.py" ]] || { echo "ERROR: required installer files missing" >&2; exit 1; }

# Validate saved env without printing secrets.
REQUESTED_PROFILE="$PROFILE"
# shellcheck disable=SC1090
source "$E"
[[ "${PROFILE:-}" == "$REQUESTED_PROFILE" ]] || { echo "ERROR: saved profile=${PROFILE:-missing}, requested=$REQUESTED_PROFILE" >&2; exit 1; }
for n in F1 F2 F3 F4 F5; do
  for suffix in ADDR TYPE COVER ANYTLS LAYER; do
    v="${n}_${suffix}"
    [[ -n "${!v:-}" ]] || { echo "ERROR: saved $v missing" >&2; exit 1; }
  done
done
[[ "$F1_TYPE" == shadow && "$F2_TYPE" == shadow && "$F3_TYPE" == shadow && "$F4_TYPE" == restls && "$F5_TYPE" == restls ]] || {
  echo "ERROR: saved topology mismatch; refusing resume" >&2; exit 1;
}
PROFILE="$REQUESTED_PROFILE"

R="$B/.install-bucket5-resume-runtime.sh"
cleanup(){ rm -f "$R"; }
trap cleanup EXIT
cp -a "$B/install-bucket5.sh" "$R"

RUNTIME="$R" python3 <<'PY'
import os
from pathlib import Path
p=Path(os.environ['RUNTIME'])
s=p.read_text()
start=s.find('declare -A ADDR TYPE COVER ANYTLS LAYER')
end=s.find('\n{\n  printf \'PROFILE=%q\\n\' "$PROFILE"', start)
if start < 0 or end < 0:
    raise SystemExit('ERROR: could not locate credential collection block; refusing to run')
replacement=r'''declare -A ADDR TYPE COVER ANYTLS LAYER
REQUESTED_PROFILE="$PROFILE"
source "$E"
[[ "${PROFILE:-}" == "$REQUESTED_PROFILE" ]] || die "saved bucket5.env profile mismatch"
PROFILE="$REQUESTED_PROFILE"
for n in F1 F2 F3 F4 F5; do
  av="${n}_ADDR"; tv="${n}_TYPE"; cv="${n}_COVER"; pv="${n}_ANYTLS"; lv="${n}_LAYER"
  ADDR[$n]="${!av}"; TYPE[$n]="${!tv}"; COVER[$n]="${!cv}"; ANYTLS[$n]="${!pv}"; LAYER[$n]="${!lv}"
  [[ -n "${ADDR[$n]}" && -n "${TYPE[$n]}" && -n "${COVER[$n]}" && -n "${ANYTLS[$n]}" && -n "${LAYER[$n]}" ]] || die "saved credentials incomplete for $n"
done
[[ "${TYPE[F1]}" == shadow && "${TYPE[F2]}" == shadow && "${TYPE[F3]}" == shadow && "${TYPE[F4]}" == restls && "${TYPE[F5]}" == restls ]] || die "saved topology mismatch"
log "RESUME mode: reusing saved F1..F5 credentials from $E; secrets will not be prompted or printed"
'''
s=s[:start]+replacement+s[end:]
p.write_text(s)
PY

python3 "$B/bucket5-runtime-patch.py" "$R"
chmod 0700 "$R"

echo "============================================================"
echo "Bucket5 RESUME migration"
echo "Profile: $PROFILE"
echo "Using saved /etc/anytls-tunnel/bucket5.env"
echo "Topology: F1/F2/F3=ShadowTLS, F4/F5=ResTLS"
echo "No Foreign credentials will be requested again."
echo "All five nodes will still be full-probed before activation."
echo "============================================================"

bash "$R" "$PROFILE"
