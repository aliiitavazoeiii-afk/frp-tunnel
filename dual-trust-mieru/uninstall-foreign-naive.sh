#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
systemctl disable --now dual-naive-endpoint.service dual-xudp-naive.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/dual-naive-endpoint.service /etc/systemd/system/dual-xudp-naive.service
systemctl daemon-reload
rm -rf /etc/dual-trust-mieru/naive
rm -f /root/dual-naive-client.json
sed -i '/# dual-naive-xudp-backend$/d' /etc/hosts 2>/dev/null || true
echo 'Naive foreign services/config removed. Shared downloaded binaries and Caddy certificate storage were retained.'
