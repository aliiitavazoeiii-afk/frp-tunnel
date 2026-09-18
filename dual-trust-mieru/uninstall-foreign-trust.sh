#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service
systemctl daemon-reload
rm -rf /etc/dual-trust-mieru/trust
rm -f /root/dual-trust-client.json
rm -f /etc/letsencrypt/renewal-hooks/deploy/dual-trust-restart.sh
echo 'Trust foreign dual-tunnel services/config removed. Let’s Encrypt certificate and shared downloaded binaries were retained.'
