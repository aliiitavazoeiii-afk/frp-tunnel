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

for f in setup.sh install.sh upgrade-xudp-v3.sh replace-node.sh repair-xui-anytls.sh \
         sync-xui-working-state.sh sync-xui-sniffing.sh sync-xui-remote-dns.sh \
         health-final.sh uninstall-final.sh; do
  [[ -f "$BASE_DIR/$f" ]] || die "$f missing"
done

cat <<EOF
============================================================
AnyTLS Tunnel FINAL installer v1.6.0
Role: $ROLE

Final Iran state:
  x-ui public VLESS/REALITY :443 unchanged
  sniffing = ON (http/tls/quic/fakedns)
  x-ui SOCKS outbound -> 127.0.0.1:7891
  targetStrategy = AsIs (preserve hostname for remote DNS)
  XUDP bridge = ON
  QUIC_SAFE_MODE = false
============================================================
EOF

# Base role install. Existing role secrets/config are backed up by install.sh.
bash "$BASE_DIR/setup.sh" "$ROLE"

if [[ "$ROLE" == "iran" ]]; then
  # Final mode must not reject UDP/443 in Mihomo. XUDP is responsible for UDP,
  # while application/CDN hostnames must remain available for remote resolution.
  ROOT_ENV=/root/anytls-iran.env
  [[ -f "$ROOT_ENV" ]] || die "missing $ROOT_ENV after base setup"
  if ! grep -qx 'QUIC_SAFE_MODE=false' "$ROOT_ENV"; then
    log "Final mode forces QUIC_SAFE_MODE=false; normalizing Iran AnyTLS config"
    sed -i -E 's/^QUIC_SAFE_MODE=.*/QUIC_SAFE_MODE=false/' "$ROOT_ENV"
    bash "$BASE_DIR/install.sh" iran "$ROOT_ENV"
  fi

  # Build/prove the XUDP bridge. Fresh x-ui installs may not already have the
  # anytls-tunnel outbound; repair-xui-anytls handles only that bootstrap case.
  set +e
  bash "$BASE_DIR/upgrade-xudp-v3.sh" iran
  xudp_rc=$?
  set -e
  if (( xudp_rc != 0 )); then
    log "XUDP upgrade returned rc=${xudp_rc}; trying fail-closed fresh-x-ui bootstrap"
    bash "$BASE_DIR/repair-xui-anytls.sh"
  fi

  # Intermediate compatibility state is needed because sync-xui-sniffing.sh
  # validates the previously proven 7891/ForceIPv4 path before touching the
  # inbound DB record. After sniffing is enabled, the final step switches to
  # AsIs so sniffed hostnames are resolved remotely through XUDP/AnyTLS.
  bash "$BASE_DIR/sync-xui-working-state.sh"
  bash "$BASE_DIR/sync-xui-sniffing.sh"
  bash "$BASE_DIR/sync-xui-remote-dns.sh"
else
  bash "$BASE_DIR/upgrade-xudp-v3.sh" "$ROLE"
fi

# Operational helpers.
install -m 0755 "$BASE_DIR/health-final.sh" /usr/local/sbin/anytls-final-health
install -m 0755 "$BASE_DIR/uninstall-final.sh" /usr/local/sbin/anytls-uninstall

if [[ "$ROLE" == "iran" ]]; then
  install -m 0755 "$BASE_DIR/replace-node.sh" /usr/local/sbin/anytls-replace
  install -m 0755 "$BASE_DIR/repair-xui-anytls.sh" /usr/local/sbin/anytls-repair-xui
  install -m 0755 "$BASE_DIR/sync-xui-working-state.sh" /usr/local/sbin/anytls-sync-xui-legacy
  install -m 0755 "$BASE_DIR/sync-xui-sniffing.sh" /usr/local/sbin/anytls-sync-sniffing
  install -m 0755 "$BASE_DIR/sync-xui-remote-dns.sh" /usr/local/sbin/anytls-sync-remote-dns

  log "Installed operational commands:"
  log "  sudo anytls-final-health"
  log "  sudo anytls-replace"
  log "  sudo anytls-sync-remote-dns"
  log "  sudo anytls-uninstall"
else
  log "Installed operational commands:"
  log "  sudo anytls-final-health"
  log "  sudo anytls-uninstall"
fi

log "Running final health validation"
/usr/local/sbin/anytls-final-health

log "SUCCESS: AnyTLS Tunnel FINAL v1.6.0 role=$ROLE installed and healthy"
