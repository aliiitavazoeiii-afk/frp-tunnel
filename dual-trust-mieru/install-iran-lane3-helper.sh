#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo bash "$0" "$@"

D=/etc/dual-trust-mieru/iran
[[ -s "$D/xudp.json" ]] || { echo 'ERROR: existing Trust/Mieru production stack not found on this Iran server' >&2; exit 1; }
systemctl is-active --quiet x-ui.service || { echo 'ERROR: x-ui is not active' >&2; exit 1; }
systemctl is-active --quiet dual-dispatcher.service || { echo 'ERROR: existing dual dispatcher is not active' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends ca-certificates curl jq python3 openssh-client git xz-utils tar >/dev/null

LIB=/usr/local/lib/dual-trust-mieru-lane3
mkdir -p "$LIB" /etc/dual-trust-mieru/lane3 /var/lib/dual-trust-mieru/lane3/backups
chmod 0755 "$LIB"; chmod 0700 /etc/dual-trust-mieru/lane3 /var/lib/dual-trust-mieru/lane3 /var/lib/dual-trust-mieru/lane3/backups
install -m 0644 "$B/lane3-common.sh" "$LIB/lane3-common.sh"
install -m 0755 "$B/lane3-health.sh" /usr/local/sbin/lane3-health
install -m 0755 "$B/lane3-xui-route.sh" /usr/local/sbin/lane3-xui-route
install -m 0755 "$B/lane3-manager.sh" /usr/local/sbin/lane3-manager
printf '#!/usr/bin/env bash\nexec /usr/local/sbin/lane3-manager "$@"\n' > /usr/local/bin/lane3
chmod 0755 /usr/local/bin/lane3

[[ -s /etc/dual-trust-mieru/lane3/routing-mode ]] || echo all-legacy > /etc/dual-trust-mieru/lane3/routing-mode
touch /etc/dual-trust-mieru/lane3/assigned-users.txt
chmod 0600 /etc/dual-trust-mieru/lane3/routing-mode /etc/dual-trust-mieru/lane3/assigned-users.txt

if [[ ! -s /etc/dual-trust-mieru/lane3/bundle.json ]]; then
  for p in 7995 7996; do
    if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
      echo "ERROR: TCP/$p is already in use; Lane 3 requires 7995 and 7996" >&2
      exit 1
    fi
  done
fi

echo '============================================================'
echo '       MAYA3 MULTI-LANE HELPER INSTALLED'
echo '============================================================'
echo "Lane 3 version: $(cat "$B/LANE3_VERSION")"
echo 'Legacy Trust/Mieru services were NOT restarted or modified.'
echo 'x-ui routing was NOT changed.'
echo
echo 'Open panel with: lane3'
