#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
systemctl disable --now dual-xudp-mieru.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/dual-xudp-mieru.service
mita stop >/dev/null 2>&1 || true
systemctl disable --now mita.service >/dev/null 2>&1 || true
dpkg -r mita >/dev/null 2>&1 || true
systemctl daemon-reload
rm -rf /etc/dual-trust-mieru/mieru
rm -f /root/dual-mieru-client.json
echo 'Mieru foreign dual-tunnel services/config and project-installed mita package removed. Shared downloaded binaries were retained.'
