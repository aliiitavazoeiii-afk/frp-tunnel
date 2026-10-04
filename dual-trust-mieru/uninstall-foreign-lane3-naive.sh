#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
systemctl disable --now lane3-naive-endpoint.service lane3-xudp.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/lane3-naive-endpoint.service /etc/systemd/system/lane3-xudp.service
systemctl daemon-reload
rm -rf /etc/dual-trust-mieru/lane3-foreign /root/lane3-naive-client.json /var/www/lane3-naive
sed -i '/# lane3-naive-xudp$/d' /etc/hosts 2>/dev/null || true
echo 'Lane 3 foreign services/config removed. Shared binaries and Caddy storage retained.'
