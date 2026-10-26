#!/usr/bin/env bash
# Installs/upgrades the Maya4 dashboard and safe replacement helpers.
# Does not restart or modify x-ui, subscriptions, firewall, or live tunnel configs.
set -Eeuo pipefail

[[ $(id -u) -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

SRC=/opt/frp-tunnel/maya4-naive-lite
CLI=/usr/local/bin/maya4
LIB=/usr/local/lib/maya4-naive

for f in manager.sh replace-foreign-auto.sh replace-foreign.sh health.sh attach-xui.sh; do
  [[ -s "$SRC/$f" ]] || { echo "Missing source file: $SRC/$f" >&2; exit 1; }
  bash -n "$SRC/$f"
done

mkdir -p "$LIB"
chmod 0755 "$LIB"
install -m 0755 "$SRC/manager.sh" /usr/local/sbin/maya4-manager
install -m 0755 "$SRC/replace-foreign-auto.sh" /usr/local/sbin/maya4-replace-auto
install -m 0755 "$SRC/replace-foreign.sh" "$LIB/replace-foreign.sh"
install -m 0755 "$SRC/health.sh" /usr/local/sbin/maya4-health
install -m 0755 "$SRC/attach-xui.sh" /usr/local/sbin/maya4-attach

if [[ -e "$CLI" && ! -e "$CLI.before-dashboard" ]]; then
  cp -a "$CLI" "$CLI.before-dashboard"
fi

cat > "$CLI" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-dashboard}" in
  dashboard|menu) exec /usr/local/sbin/maya4-manager ;;
  status|health) exec /usr/local/sbin/maya4-health ;;
  attach) exec /usr/local/sbin/maya4-attach ;;
  replace)
    shift
    exec /usr/local/sbin/maya4-replace-auto "$@"
    ;;
  replace-bundle)
    shift
    exec /bin/bash /usr/local/lib/maya4-naive/replace-foreign.sh "$@"
    ;;
  restart)
    systemctl restart maya4-naive-client.service maya4-xudp-router.service
    sleep 3
    exec /usr/local/sbin/maya4-health
    ;;
  *)
    echo 'usage: maya4 [dashboard|health|attach|replace [NEW_IP]|replace-bundle BUNDLE|restart]' >&2
    exit 2
    ;;
esac
EOF
chmod 0755 "$CLI"
bash -n "$CLI"

echo 'SUCCESS: Maya4 dashboard installed.'
echo 'Run: sudo maya4'
echo 'Dashboard option 1 asks only for the new foreign IPv4.'
