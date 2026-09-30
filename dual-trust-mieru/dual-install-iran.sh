#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo bash "$0" "$@"
TRUST_IP=''; MIERU_IP=''; TRUST_BUNDLE=''; MIERU_BUNDLE=''; NO_ATTACH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --trust-ip) TRUST_IP=${2:-}; shift 2;;
    --mieru-ip) MIERU_IP=${2:-}; shift 2;;
    --trust-bundle) TRUST_BUNDLE=${2:-}; shift 2;;
    --mieru-bundle) MIERU_BUNDLE=${2:-}; shift 2;;
    --no-attach) NO_ATTACH=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

banner(){
  echo '============================================================'
  echo '              DUAL MIERU TRUST TUNNEL'
  echo '                 powered by ali tavazoei'
  echo '============================================================'
}
banner
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends openssh-client git curl jq ca-certificates >/dev/null

install_manager(){
  mkdir -p /usr/local/lib/dual-trust-mieru-manager
  install -m 0755 "$B/dual-health.sh" /usr/local/sbin/dual-health
  install -m 0755 "$B/dual-manager.sh" /usr/local/sbin/dual-manager
  install -m 0755 "$B/dual-cli.sh" /usr/local/bin/dual
  install -m 0755 "$B/replace-carrier-only-final.sh" /usr/local/sbin/dual-replace-carrier
  install -m 0755 "$B/dual-autoheal.sh" /usr/local/lib/dual-trust-mieru-manager/dual-autoheal.sh
  install -m 0755 "$B/install-autoheal.sh" /usr/local/lib/dual-trust-mieru-manager/install-autoheal.sh
}

# Existing production: upgrade management/health in place, do not reinstall
# carriers or x-ui. Only the dispatcher is briefly restarted after its health
# cadence is changed.
if [[ -s /etc/dual-trust-mieru/iran/xudp.json ]]; then
  echo 'Existing dual installation detected: upgrading in place.'
  install_manager
  install -m 0755 "$B/dual-probe-final.sh" /usr/local/sbin/dual-tunnel-probe
  /usr/local/sbin/dual-manager --apply-safe-profile
  echo
  /usr/local/sbin/dual-health --full all || true
  echo
  echo 'UPGRADE COMPLETE. Use: dual status'
  exit 0
fi

SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
if [[ -z "$TRUST_BUNDLE" ]]; then
  [[ -n "$TRUST_IP" ]] || read -r -p 'Trust foreign IPv4: ' TRUST_IP
  TRUST_BUNDLE=/root/dual-trust-client.import.json
  echo 'Copying Trust bundle; SSH may ask for root password.'
  scp "${SSH_OPTS[@]}" "root@$TRUST_IP:/root/dual-trust-client.json" "$TRUST_BUNDLE"
fi
if [[ -z "$MIERU_BUNDLE" ]]; then
  [[ -n "$MIERU_IP" ]] || read -r -p 'Mieru foreign IPv4: ' MIERU_IP
  MIERU_BUNDLE=/root/dual-mieru-client.import.json
  echo 'Copying Mieru bundle; SSH may ask for root password.'
  scp "${SSH_OPTS[@]}" "root@$MIERU_IP:/root/dual-mieru-client.json" "$MIERU_BUNDLE"
fi
chmod 0600 "$TRUST_BUNDLE" "$MIERU_BUNDLE"
jq -e '.version==1 and .kind=="trust" and .public_ip and .domain and .xudp_uuid' "$TRUST_BUNDLE" >/dev/null
jq -e '.version==1 and .kind=="mieru" and .public_ip and .port_range and .xudp_uuid' "$MIERU_BUNDLE" >/dev/null
T=$(jq -r '.public_ip' "$TRUST_BUNDLE"); M=$(jq -r '.public_ip' "$MIERU_BUNDLE")
[[ "$T" != "$M" ]] || { echo 'ERROR: Trust and Mieru must use separate foreign VPS IPs.' >&2; exit 1; }
if [[ "$T" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\. && "$M" == "${BASH_REMATCH[1]}."* ]]; then
  echo 'WARNING: both foreign IPs are in the same /24; different prefixes/providers give better failure isolation.'
fi

echo 'Installing production split stack (TCP direct, UDP XUDP, Mieru multiplexing OFF)...'
bash "$B/install-iran-final.sh" "$TRUST_BUNDLE" "$MIERU_BUNDLE"
install_manager

if (( NO_ATTACH == 0 )) && systemctl is-active --quiet x-ui.service 2>/dev/null; then
  echo 'Attaching x-ui public inbound to dual dispatcher...'
  bash "$B/attach-xui-final.sh"
fi

/usr/local/sbin/dual-manager --apply-safe-profile
/usr/local/sbin/dual-health --full all

echo
echo 'INSTALL COMPLETE'
echo 'Management menu: dual status'
echo 'Health only:     dual health --full'
