#!/usr/bin/env bash
# Stage role-local self-heal/selector failover; NO production reload/restart.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root';exit 1; }
B=$(cd -- "$(dirname -- "$0")" && pwd)
STATE=/var/lib/dual-trust-mieru/naive-mieru/ha
[[ -s /etc/dual-trust-mieru/iran/controller.secret ]] || { echo 'Mihomo secret absent';exit 1; }
for s in x-ui dual-dispatcher dual-xudp-bridge nm-naive-client dual-mieru-carrier;do
  systemctl is-active --quiet "$s.service" || { echo "Live service $s inactive; refuse install";exit 1; }
done
python3 -m py_compile "$B/nm-ha-agent.py" "$B/nm-ha-telemetry.py"
mkdir -p "$STATE"
chmod 0700 "$STATE"
if [[ -f /usr/local/sbin/nm-ha ]];then cp -a /usr/local/sbin/nm-ha "$STATE/previous-nm-ha-$(date -u +%Y%m%dT%H%M%SZ)";fi
# Timers may be active: upgrade executables by atomic rename so they never
# execute a half-written Python file. Both temporary files live on same FS.
for entry in "nm-ha-agent.py:nm-ha" "nm-ha-telemetry.py:nm-ha-telemetry";do
  src=${entry%%:*}; dest=${entry#*:}
  tmp=$(mktemp "/usr/local/sbin/.${dest}.XXXXXXXX")
  install -m 0755 "$B/$src" "$tmp"
  mv -f "$tmp" "/usr/local/sbin/$dest"
done
for unit in nm-ha.service nm-ha.timer nm-ha-telemetry.service nm-ha-telemetry.timer;do
  if [[ -e /etc/systemd/system/$unit ]];then
     grep -Fq 'NAIVE-MIERU-HA-MANAGED' "/etc/systemd/system/$unit" ||
       { echo "Refuse to overwrite unrelated unit: $unit";exit 1; }
  fi
done
cat >/etc/systemd/system/nm-ha.service <<'UNIT'
# NAIVE-MIERU-HA-MANAGED
[Unit]
Description=Naive/Mieru conservative role-local health and selector failover
After=network-online.target dual-dispatcher.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nm-ha once
TimeoutStartSec=90
UMask=0077
NoNewPrivileges=false
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT
cat >/etc/systemd/system/nm-ha.timer <<'UNIT'
# NAIVE-MIERU-HA-MANAGED
[Unit]
Description=Periodic Naive/Mieru self-heal check, one job at a time
[Timer]
OnBootSec=70s
OnUnitInactiveSec=40s
AccuracySec=5s
Unit=nm-ha.service
Persistent=false
[Install]
WantedBy=timers.target
UNIT
cat >/etc/systemd/system/nm-ha-telemetry.service <<'UNIT'
# NAIVE-MIERU-HA-MANAGED
[Unit]
Description=One-way HMAC signed Hesab VPN tunnel status push
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nm-ha-telemetry
TimeoutStartSec=12
UMask=0077
PrivateTmp=true
UNIT
cat >/etc/systemd/system/nm-ha-telemetry.timer <<'UNIT'
# NAIVE-MIERU-HA-MANAGED
[Unit]
Description=Push tunnel telemetry to Hesab Control Room over outbound HTTPS
[Timer]
OnBootSec=90s
OnUnitInactiveSec=60s
AccuracySec=10s
Unit=nm-ha-telemetry.service
[Install]
WantedBy=timers.target
UNIT
systemd-analyze verify /etc/systemd/system/nm-ha.service /etc/systemd/system/nm-ha.timer \
 /etc/systemd/system/nm-ha-telemetry.service /etc/systemd/system/nm-ha-telemetry.timer >/dev/null
systemctl daemon-reload
echo '=== NON-DISRUPTIVE HA VERIFICATION (NO RESTART, NO POOL CHANGES) ==='
if systemctl is-active --quiet nm-ha.timer;then
  # Production HA is already running: do not mutate live status/counters by
  # sending a dry-run. New code is picked up automatically on the next tick.
  /usr/local/sbin/nm-ha status
  echo 'HA timer already active; left enabled without interruption.'
else
  /usr/local/sbin/nm-ha dry-run
  echo 'HA timer is not active; bootstrap and enable it separately if intended.'
fi
echo 'SUCCESS: HA code installed without restarting production services.'
echo 'First-time DUAL Selector bootstrap is explicitly separate and can affect existing user connections.'
echo 'If user traffic exists, activation refuses unless you explicitly opt into the one-time live reload.'
echo 'To activate when connections=0: sudo nm-ha bootstrap && sudo systemctl enable --now nm-ha.timer'
echo 'To view state: sudo nm-ha status'
echo 'For panel telemetry: configure /etc/dual-trust-mieru/ha-telemetry.json and enable nm-ha-telemetry.timer'
