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

cat <<EOF
============================================================
AnyTLS Tunnel FINAL installer v1.5.0
Role: $ROLE
Base AnyTLS + automatic XUDP compatibility layer
============================================================
EOF

# Base installation creates/stores the role-specific AnyTLS environment.
bash "$BASE_DIR/setup.sh" "$ROLE"

# The proven Google/YouTube/NPV compatibility fix is mandatory in final mode.
bash "$BASE_DIR/upgrade-xudp-v3.sh" "$ROLE"

if [[ "$ROLE" == "iran" ]]; then
  install -m 0755 "$BASE_DIR/replace-node.sh" /usr/local/sbin/anytls-replace
  log "Installed safe replacement command: sudo anytls-replace"
  log "Verifying final Iran services"
  systemctl is-active --quiet anytls-tunnel || die "anytls-tunnel inactive"
  systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge inactive"
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
else
  systemctl is-active --quiet anytls-tunnel || die "anytls-tunnel inactive"
  systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge inactive"
  ss -H -ltn 'sport = :443' | grep -q . || die "AnyTLS TCP/443 missing"
  ss -H -ltn 'sport = :2443' | grep -q . || die "XUDP loopback endpoint 2443 missing"
  log "SUCCESS: FINAL $ROLE install complete"
fi
