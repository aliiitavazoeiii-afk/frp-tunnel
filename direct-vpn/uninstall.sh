#!/usr/bin/env bash
set -Eeuo pipefail
PURGE=0
[[ ${1:-} == '--purge-bundle' ]] && PURGE=1
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
systemctl disable --now direct-naive.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/direct-naive.service
systemctl daemon-reload
rm -rf /etc/direct-naive /var/www/direct-naive /var/lib/direct-naive /usr/local/lib/direct-naive
if id direct-naive >/dev/null 2>&1; then userdel direct-naive >/dev/null 2>&1 || true; fi
if (( PURGE )); then rm -f /root/direct-naive-client.json; else echo 'Preserved /root/direct-naive-client.json'; fi
echo 'direct-naive removed'
