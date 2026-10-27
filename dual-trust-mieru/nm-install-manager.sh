#!/usr/bin/env bash
# Install only the Naive/Mieru management CLI; never restart tunnel/x-ui services.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'ERROR: run as root' >&2;exit 1; }
B=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=/usr/local/lib/naive-mieru-manager
BK=/var/lib/dual-trust-mieru/naive-mieru/manager-backups
DIR=$BK/$(date -u +%Y%m%dT%H%M%SZ)
[[ -s /etc/dual-trust-mieru/naive-mieru/bundle.json ]] || { echo 'Missing live Naive bundle' >&2;exit 1; }
[[ -s /etc/dual-trust-mieru/iran/mieru-bundle.json ]] || { echo 'Missing live Mieru bundle' >&2;exit 1; }
for svc in x-ui dual-dispatcher dual-xudp-bridge nm-naive-client dual-mieru-carrier;do
  systemctl is-active --quiet "$svc.service" || { echo "$svc inactive; refusing management install" >&2;exit 1; }
done
for file in nm-cli.sh nm-health.sh nm-manager.sh nm-foreign-wizard.sh nm-helper.sh;do
  bash -n "$B/$file"
done
python3 -m py_compile "$B/nm-replace.py" "$B/nm-stats.py" "$B/nm-pool-balance.py" "$B/nm-live-audit.py" "$B/nm-naive-fresh-client-diagnose.py"
test -s "$B/nm-replace.py"
test -s "$B/nm-stats.py"
mkdir -p "$ROOT" "$DIR"
chmod 0700 "$BK" "$DIR"
for old in /usr/local/bin/dual /usr/local/sbin/dual-manager /usr/local/sbin/nm-health /usr/local/sbin/nm-pool-balance /usr/local/sbin/nm-live-audit /usr/local/sbin/nm-naive-fresh-client-diagnose;do
  if [[ -f "$old" ]];then cp -a "$old" "$DIR/$(basename "$old")";fi
done
echo '=== INSTALL NAIVE/MIERU MANAGER (NO SERVICE RESTART) ==='
install -m 0755 "$B/nm-manager.sh" "$ROOT/nm-manager.sh"
install -m 0755 "$B/nm-foreign-wizard.sh" "$ROOT/nm-foreign-wizard.sh"
install -m 0755 "$B/nm-replace.py" "$ROOT/nm-replace.py"
install -m 0755 "$B/nm-stats.py" "$ROOT/nm-stats.py"
install -m 0755 "$B/nm-live-audit.py" /usr/local/sbin/nm-live-audit
install -m 0755 "$B/nm-naive-fresh-client-diagnose.py" /usr/local/sbin/nm-naive-fresh-client-diagnose
install -m 0755 "$B/nm-health.sh" /usr/local/sbin/nm-health
install -m 0755 "$B/nm-pool-balance.py" /usr/local/sbin/nm-pool-balance
install -m 0755 "$B/nm-cli.sh" /usr/local/bin/dual
install -m 0755 "$B/nm-cli.sh" /usr/local/sbin/dual-manager
# Install dedicated simpler Helper; preserve unrelated commands if name is taken.
HELPER=/usr/local/bin/helper
if [[ ! -e "$HELPER" && ! -L "$HELPER" ]]; then
  install -m 0755 "$B/nm-helper.sh" "$HELPER"
  echo 'Friendly Helper installed: sudo helper'
elif [[ -L "$HELPER" && "$(readlink -f "$HELPER")" == /usr/local/bin/dual ]]; then
  rm -f "$HELPER"
  install -m 0755 "$B/nm-helper.sh" "$HELPER"
  echo 'Upgraded existing dual alias to dedicated Helper: sudo helper'
elif [[ -f "$HELPER" ]] && grep -Fq 'NAIVE + MIERU FRIENDLY HELPER' "$HELPER" 2>/dev/null; then
  cp -a "$HELPER" "$DIR/helper" || true
  install -m 0755 "$B/nm-helper.sh" "$HELPER"
  echo 'Updated friendly Helper: sudo helper'
else
  echo 'NOTICE: /usr/local/bin/helper exists and is unrelated; preserving it. Use: sudo dual'
fi
echo '=== READ ONLY VERIFICATION ==='
/usr/local/bin/dual status
for svc in x-ui dual-dispatcher dual-xudp-bridge nm-naive-client dual-mieru-carrier;do
  systemctl is-active --quiet "$svc.service" || { echo "WARNING: $svc inactive after install (no service restarts requested)" >&2;exit 1; }
done
echo 'MANAGER INSTALLED. Run: sudo helper (or sudo dual) for interactive menu.'
echo 'Quick commands: dual status | dual audit --seconds 60 | dual health --full all'
echo "Backups: $DIR"
