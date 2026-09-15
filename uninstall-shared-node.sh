#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
STATE_DIR="/var/lib/${PROJECT}"
DEPLOY_ENV="${CONFIG_DIR}/deploy.env"
CONFIG="${CONFIG_DIR}/config.yaml"
MIHOMO="/usr/local/bin/mihomo-${PROJECT}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$DEPLOY_ENV" && -f "$CONFIG" ]] || die "base AnyTLS files missing"
[[ -x "$MIHOMO" ]] || die "Mihomo binary missing"
source "$DEPLOY_ENV"
for n in NODE_A_ADDR NODE_B_ADDR COVER_HOST_A COVER_HOST_B ANYTLS_PASS_A SHADOWTLS_PASS_A ANYTLS_PASS_B RESTLS_PASS_B CONTROLLER_SECRET LOCAL_SOCKS_PORT LOCAL_CONTROLLER_PORT; do
  [[ -n "${!n:-}" ]] || die "missing $n in deploy.env"
done

API="http://127.0.0.1:${LOCAL_CONTROLLER_PORT}"
AUTH=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")
TMP=$(mktemp -d /tmp/anytls-shared-uninstall.XXXXXX)
chmod 0711 "$TMP"
trap 'rm -rf "$TMP"' EXIT

systemctl disable --now anytls-shared-scheduler.timer >/dev/null 2>&1 || true
if curl -fsS "${AUTH[@]}" "$API/proxies/TUNNEL" >/dev/null 2>&1; then
  curl -sS -o /dev/null "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X PUT "$API/proxies/TUNNEL" -d '{"name":"TUNNEL-BASE"}' || true
fi

cat >"$TMP/config.yaml" <<EOF
mode: rule
log-level: info
ipv6: false
external-controller: "127.0.0.1:${LOCAL_CONTROLLER_PORT}"
secret: "${CONTROLLER_SECRET}"
listeners:
  - name: xray-socks-backend
    type: socks
    listen: 127.0.0.1
    port: ${LOCAL_SOCKS_PORT}
    udp: true
    users: []
proxies:
  - name: foreign-a-shadowtls
    type: anytls
    server: "${NODE_A_ADDR}"
    port: 443
    password: "${ANYTLS_PASS_A}"
    tls: true
    sni: "${COVER_HOST_A}"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    shadow-tls-opts:
      version: 3
      password: "${SHADOWTLS_PASS_A}"
  - name: foreign-b-restls
    type: anytls
    server: "${NODE_B_ADDR}"
    port: 443
    password: "${ANYTLS_PASS_B}"
    tls: true
    sni: "${COVER_HOST_B}"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    restls-opts:
      password: "${RESTLS_PASS_B}"
      version-hint: tls13
proxy-groups:
  - name: TUNNEL
    type: load-balance
    proxies:
      - foreign-a-shadowtls
      - foreign-b-restls
    url: "https://www.gstatic.com/generate_204"
    expected-status: 204
    interval: 5
    lazy: false
    timeout: 3500
    max-failed-times: 2
    strategy: sticky-sessions
rules:
  - MATCH,TUNNEL
EOF

chmod 0600 "$TMP/config.yaml"
chown anytls-tunnel:anytls-tunnel "$TMP/config.yaml"
runuser -u anytls-tunnel -- "$MIHOMO" -t -d "$CONFIG_DIR" -f "$TMP/config.yaml" >/dev/null \
  || die "base candidate invalid; shared config left in place"

mkdir -p "$STATE_DIR/backups"
BACKUP="$STATE_DIR/backups/shared-uninstall-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
cp -a "$CONFIG" "$BACKUP/config.yaml"
[[ -f "$CONFIG_DIR/shared-node.env" ]] && cp -a "$CONFIG_DIR/shared-node.env" "$BACKUP/shared-node.env"

reload(){
  [[ "$(curl -sS -o "$TMP/r" -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -X PUT "$API/configs?force=true" -d '{"path":"/etc/anytls-tunnel/config.yaml","payload":""}' || true)" == 204 ]]
}
rollback(){ log "ROLLBACK: restoring shared config"; cp -a "$BACKUP/config.yaml" "$CONFIG"; chown anytls-tunnel:anytls-tunnel "$CONFIG"; chmod 0600 "$CONFIG"; reload || systemctl restart anytls-tunnel || true; }
trap 'rc=$?; if ((rc!=0)); then rollback; fi; rm -rf "$TMP"' EXIT

cp "$TMP/config.yaml" "$CONFIG"
chown anytls-tunnel:anytls-tunnel "$CONFIG"
chmod 0600 "$CONFIG"
reload || die "base config API reload failed"
sleep 2
curl -fsS "${AUTH[@]}" "$API/proxies/foreign-a-shadowtls" >/dev/null || die "F1 missing after removal"
curl -fsS "${AUTH[@]}" "$API/proxies/foreign-b-restls" >/dev/null || die "F2 missing after removal"
if curl -fsS "${AUTH[@]}" "$API/proxies/foreign-shared-shadowtls" >/dev/null 2>&1; then die "F5 still exists after removal"; fi
code=$(curl -4 -sS --socks5-hostname 127.0.0.1:7891 --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || die "production XUDP path unhealthy after removal"

rm -f /etc/systemd/system/anytls-shared-scheduler.{timer,service}
rm -f /usr/local/sbin/anytls-shared-{probe,scheduler,uninstall}
rm -f "$CONFIG_DIR/shared-node.env" "$STATE_DIR/shared-node.state"
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true
trap - EXIT
rm -rf "$TMP"
log "SUCCESS: shared F5 removed; base F1+F2 path remains active; backup=$BACKUP"
