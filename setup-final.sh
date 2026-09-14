#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROLE="${1:-}"

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
case "$ROLE" in
  foreign-a|foreign-b|iran) ;;
  *) die "usage: sudo bash setup-final.sh foreign-a|foreign-b|iran" ;;
esac

[[ -f "$BASE_DIR/setup.sh" ]] || die "setup.sh missing"
[[ -f "$BASE_DIR/upgrade-xudp-v3.sh" ]] || die "upgrade-xudp-v3.sh missing"
[[ -f "$BASE_DIR/replace-node.sh" ]] || die "replace-node.sh missing"
[[ -f "$BASE_DIR/repair-xui-anytls.sh" ]] || die "repair-xui-anytls.sh missing"
[[ -f "$BASE_DIR/sync-xui-working-state.sh" ]] || die "sync-xui-working-state.sh missing"
[[ -f "$BASE_DIR/sync-xui-sniffing.sh" ]] || die "sync-xui-sniffing.sh missing"

cat <<EOF
============================================================
AnyTLS Tunnel FINAL installer v1.5.3
Role: $ROLE
Base AnyTLS + automatic XUDP compatibility layer
============================================================
EOF

bash "$BASE_DIR/setup.sh" "$ROLE"

if [[ "$ROLE" == "iran" ]]; then
  set +e
  bash "$BASE_DIR/upgrade-xudp-v3.sh" iran
  xudp_rc=$?
  set -e
  if (( xudp_rc != 0 )); then
    log "XUDP upgrade returned rc=${xudp_rc}; checking fresh-x-ui bootstrap path"
    bash "$BASE_DIR/repair-xui-anytls.sh"
  fi

  # Known-good production state for NPV/Google/YouTube compatibility:
  # 1) x-ui outbound -> XUDP SOCKS 127.0.0.1:7891
  # 2) targetStrategy=ForceIPv4
  # 3) public :443 VLESS inbound sniffing enabled for http/tls/quic/fakedns
  bash "$BASE_DIR/sync-xui-working-state.sh"
  bash "$BASE_DIR/sync-xui-sniffing.sh"
else
  bash "$BASE_DIR/upgrade-xudp-v3.sh" "$ROLE"
fi

if [[ "$ROLE" == "iran" ]]; then
  install -m 0755 "$BASE_DIR/replace-node.sh" /usr/local/sbin/anytls-replace
  install -m 0755 "$BASE_DIR/repair-xui-anytls.sh" /usr/local/sbin/anytls-repair-xui
  install -m 0755 "$BASE_DIR/sync-xui-working-state.sh" /usr/local/sbin/anytls-sync-xui
  install -m 0755 "$BASE_DIR/sync-xui-sniffing.sh" /usr/local/sbin/anytls-sync-sniffing
  log "Installed safe replacement command: sudo anytls-replace"
  log "Installed x-ui bootstrap/repair command: sudo anytls-repair-xui"
  log "Installed known-good x-ui sync command: sudo anytls-sync-xui"
  log "Installed known-good sniffing sync command: sudo anytls-sync-sniffing"
  log "Verifying final Iran services"
  systemctl is-active --quiet anytls-tunnel || die "anytls-tunnel inactive"
  systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge inactive"
  systemctl is-active --quiet x-ui || die "x-ui inactive"
  ss -H -ltn 'sport = :7890' | grep -q . || die "Mihomo SOCKS 7890 missing"
  ss -H -ltn 'sport = :7891' | grep -q . || die "XUDP SOCKS 7891 missing"
  ss -H -ltn 'sport = :9090' | grep -q . || die "Mihomo controller 9090 missing"
  ss -H -ltn 'sport = :443' | grep -q . || die "public x-ui/Xray TCP/443 missing"
  log "SUCCESS: FINAL Iran install complete"
  echo
  echo "Operational commands:"
  echo "  sudo anytls-xudp-health"
  echo "  sudo anytls-tunnel-health"
  echo "  sudo anytls-replace"
  echo "  sudo anytls-repair-xui"
  echo "  sudo anytls-sync-xui"
  echo "  sudo anytls-sync-sniffing"
else
  systemctl is-active --quiet anytls-tunnel || die "anytls-tunnel inactive"
  systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge inactive"
  ss -H -ltn 'sport = :443' | grep -q . || die "AnyTLS TCP/443 missing"
  ss -H -ltn 'sport = :2443' | grep -q . || die "XUDP loopback endpoint 2443 missing"
  log "SUCCESS: FINAL $ROLE install complete"
fi
