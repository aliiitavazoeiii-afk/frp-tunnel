#!/usr/bin/env bash
# Retire only old local Trust service/files after a stable Naive cutover.
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
ROOT=/var/lib/dual-trust-mieru/naive-mieru
[[ -s "$ROOT/live-cutover.timestamp" ]] || { echo 'Naive cutover not confirmed' >&2; exit 1; }
for s in x-ui dual-dispatcher dual-xudp-bridge dual-mieru-carrier nm-naive-client; do
  systemctl is-active --quiet "$s.service" || { echo "Refuse: $s inactive"; exit 1; }
done
systemctl is-active --quiet dual-trust-client.service && {
  echo 'Refuse: old Trust still running'; exit 1;
}
for p in 7991 7992; do
  code=$(curl -sS -4 --socks5-hostname "127.0.0.1:$p" \
      --connect-timeout 4 --max-time 9 -o /dev/null -w '%{http_code}' \
      https://www.gstatic.com/generate_204 2>/dev/null || true)
  [[ "$code" == 204 ]] || { echo "Refuse: role on $p unhealthy"; exit 1; }
done
dir="$ROOT/legacy-trust-backup"
[[ ! -e "$dir" ]] || { echo 'Already backed up; refusing duplicate cleanup'; exit 1; }
install -d -m 0700 "$dir"
for f in /etc/dual-trust-mieru/iran/trust-client.toml \
         /etc/dual-trust-mieru/iran/trust-bundle.json \
         /etc/systemd/system/dual-trust-client.service; do
  [[ -f "$f" ]] || continue
  install -m 0600 "$f" "$dir/$(basename "$f")"
done
systemctl disable dual-trust-client.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/dual-trust-client.service \
      /etc/dual-trust-mieru/iran/trust-client.toml \
      /etc/dual-trust-mieru/iran/trust-bundle.json
systemctl daemon-reload
echo 'OLD LOCAL TRUST service/files retired. Root-only backups retained.'
echo 'Shared XUDP/Mihomo compatibility tags remain until the separately gated'
echo '50/50 pool reload with zero active connections. Mieru was not restarted.'
echo 'Old FOREIGN server is intentionally not accessed or deleted.'
