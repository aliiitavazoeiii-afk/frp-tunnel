#!/usr/bin/env bash
# Maya3 helper-only ANSI colors; NO daemon restart or live tunnel mutation.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 && $# == 1 && $1 =~ ^[a-f0-9]{40}$ ]] || {
  echo "Usage: sudo bash install-dual-colors-maya3.sh EXACT_COMMIT_SHA" >&2; exit 2;
}
REF="$1"
DIR=/opt/dual-ha/helper
DEST="$DIR/dual_backhaul_menu.py"
URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2/dual_backhaul_menu.py"
[[ "$(readlink -f /usr/local/bin/dual)" == "$DEST" && -s "$DEST" &&
   -r /etc/dual-ha/bh2-experiment/state.json ]] || {
  echo "STOP: unfamiliar Maya3 dual-backhaul helper/layout"; exit 3;
}
python3 - <<'PY'
import json
d=json.load(open("/etc/dual-ha/bh2-experiment/state.json"))
assert d.get("mode")=="active"
assert d.get("foreign_ip")=="82.152.132.112"
assert "BH_IRAN_IP='185.215.230.221'" in open("/etc/dual-ha/backhaul-bundle.env").read()
PY
STAGE="$(mktemp /root/.dual-color-helper.XXXXXXXX.py)"
trap 'rm -f "$STAGE"' EXIT
curl --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 \
  -fsSLo "$STAGE" "$URL"
python3 -m py_compile "$STAGE"
grep -Fq 'def lane_health(' "$STAGE"
grep -Fq 'NO_COLOR' "$STAGE"
# Validate output in non-TTY restricted-SSH mode: must contain both roles
# and never output color sequences or secret values.
PROBE="$(NO_COLOR=1 python3 "$STAGE" status)"
grep -Fq "BACKHAUL1" <<<"$PROBE"
grep -Fq "BACKHAUL2" <<<"$PROBE"
if [[ "$PROBE" == *$'\033'* ]]; then
  echo "STOP: ANSI leaked into restricted SSH telemetry" >&2;exit 3;
fi
BACKUP="/root/dual-backhaul-backups/color-helper-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$BACKUP"
cp -a "$DEST" "$BACKUP/dual_backhaul_menu.py"
cat >"$BACKUP/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID == 0 ]] || exit 2
install -m 0700 "$BACKUP/dual_backhaul_menu.py" "$DEST"
echo 'Original helper restored. No service restarted.'
EOF
chmod 0700 "$BACKUP/rollback.sh"
install -m 0700 "$STAGE" "$DEST"
if ! NO_COLOR=1 /usr/local/bin/dual status >/dev/null; then
  install -m 0700 "$BACKUP/dual_backhaul_menu.py" "$DEST"
  echo "HELPER ROLLED BACK" >&2;exit 4
fi
echo "SUCCESS=DUAL_HELPER_COLORS_INSTALLED"
echo "Green=fresh verified healthy | Red=observed DOWN | Yellow=unknown/stale"
echo "Foreign IPs=cyan | Status colors shown only in interactive terminals"
echo "NO_CADDY_XRAY_HAPROXY_BACKHAUL_RESTART_OR_CHANGES=TRUE"
echo "ROLLBACK: sudo bash $BACKUP/rollback.sh"
echo "NEXT: sudo dual"
