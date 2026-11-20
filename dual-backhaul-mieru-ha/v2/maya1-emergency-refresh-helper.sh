#!/usr/bin/env bash
# Maya1 emergency UI-only correction. Keep controller OFF and HAProxy live.
# Change only existing helper /opt/dual-ha/helper/maya1_dual_backhaul_menu.py.
set -Eeuo pipefail
umask 077
[[ "$EUID" == 0 && $# == 1 && "$1" =~ ^[a-f0-9]{40}$ ]] || {
  echo "Usage: sudo bash maya1-emergency-refresh-helper.sh PINNED_COMMIT";exit 2;
}
[[ "$(readlink -f /usr/local/bin/dual)" == /opt/dual-ha/helper/maya1_dual_backhaul_menu.py ]] || {
  echo "STOP: live sudo dual target not the expected Maya1 helper";exit 3;
}
TARGET=/opt/dual-ha/helper/maya1_dual_backhaul_menu.py
[[ -f "$TARGET" && ! -L "$TARGET" && "$(stat -c '%u' "$TARGET")" == 0 ]] || {
  echo "STOP: helper target missing, symlink or not root-owned";exit 3;
}
if systemctl is-active --quiet dual-ha-v2-health.service;then
  echo "STOP: old health controller still running; disable --now first";exit 3
fi
[[ "$(systemctl is-active dual-ha-v2-gateway.service || true)" == active ]] || {
  echo "STOP: HAProxy is not running";exit 3;
}
REF="$1"
URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2/maya1-dual-helper.py"
TEMP="$(mktemp /root/.maya1-helper-repair.XXXXXXXX.py)"
STAGE="$TARGET.maya1-repair.new"
trap 'rm -f "$TEMP" "$STAGE"' EXIT
[[ ! -e "$STAGE" && ! -L "$STAGE" ]] || {
  echo "STOP: partial helper replacement exists";exit 3;
}
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 8 --max-time 45 \
  -o "$TEMP" "$URL"
python3 -m py_compile "$TEMP"
OUT="$(NO_COLOR=1 python3 "$TEMP" status)"
for key in "BACKHAUL1" "BACKHAUL2" "SOCKS=21101 UP" "SOCKS=21102 UP" "Health controller: STOPPED";do
  grep -Fq "$key" <<<"$OUT" || {
    echo "STOP: new helper could not verify live routing: $key";exit 3;
  }
done
BACKUP="/root/dual-backhaul-backups/maya1-helper-repair-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p -m 0700 "$BACKUP"
cp -a "$TARGET" "$BACKUP/maya1_dual_backhaul_menu.py.old"
echo "BACKUP=$BACKUP/maya1_dual_backhaul_menu.py.old"
install -o root -g root -m 0700 "$TEMP" "$STAGE"
mv -Tf "$STAGE" "$TARGET"
if ! NO_COLOR=1 /usr/local/bin/dual status | grep -Fq "SOCKS=21101 UP";then
  cp -a "$BACKUP/maya1_dual_backhaul_menu.py.old" "$STAGE"
  mv -Tf "$STAGE" "$TARGET"
  echo "STOP: Helper validation failed; original restored"
  exit 4
fi
echo "MAYA1_LIVE_STATUS_HELPER_CORRECTED"
echo "HAProxy/Xray/Backhauls/Controller unchanged"
echo "Restore helper: cp -a $BACKUP/maya1_dual_backhaul_menu.py.old $TARGET"
echo "NEXT: sudo dual status"
