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
  echo '              DUAL MIERU NAIVE TUNNEL'
  echo '                 power by ali tavazoei'
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
  install -m 0755 "$B/dual-optimizer.sh" /usr/local/sbin/dual-optimizer
  install -m 0755 "$B/host-optimizer.sh" /usr/local/sbin/dual-host-optimizer
  install -m 0644 "$B/common.sh" /usr/local/lib/dual-trust-mieru-manager/common.sh
  install -m 0755 "$B/migrate-trust-to-naive.sh" /usr/local/sbin/dual-naive-migrate
  install -m 0755 "$B/replace-carrier-only-final.sh" /usr/local/sbin/dual-replace-carrier
  install -m 0755 "$B/dual-autoheal.sh" /usr/local/lib/dual-trust-mieru-manager/dual-autoheal.sh
  install -m 0755 "$B/install-autoheal.sh" /usr/local/lib/dual-trust-mieru-manager/install-autoheal.sh
}

ensure_dispatcher_profile(){
  local cfg=/etc/dual-trust-mieru/iran/dispatcher.yaml
  [[ -s "$cfg" ]] || { echo 'ERROR: dispatcher config missing' >&2; return 1; }

  if grep -Eq '^[[:space:]]*interval:[[:space:]]*120[[:space:]]*$' "$cfg" \
     && grep -Eq '^[[:space:]]*lazy:[[:space:]]*true[[:space:]]*$' "$cfg" \
     && grep -Eq '^[[:space:]]*max-failed-times:[[:space:]]*2[[:space:]]*$' "$cfg" \
     && grep -Eq '^[[:space:]]*strategy:[[:space:]]*sticky-sessions[[:space:]]*$' "$cfg"; then
    echo 'Sticky low-noise dispatcher profile already active; no dispatcher restart needed.'
  else
    cp -a "$cfg" "$cfg.before-sticky-profile-$(date -u +%Y%m%dT%H%M%SZ)"
    python3 - "$cfg" <<'PY'
import re,sys
p=sys.argv[1]
s=open(p).read()
s=re.sub(r'(?m)^(\s*interval:)\s*\d+\s*$', r'\1 120', s, count=1)
s=re.sub(r'(?m)^(\s*lazy:)\s*(?:true|false)\s*$', r'\1 true', s, count=1)
s=re.sub(r'(?m)^(\s*max-failed-times:)\s*\d+\s*$', r'\1 2', s, count=1)
if re.search(r'(?m)^\s*strategy:\s*\S+\s*$', s):
    s=re.sub(r'(?m)^(\s*strategy:)\s*\S+\s*$', r'\1 sticky-sessions', s, count=1)
else:
    raise SystemExit('dispatcher strategy line missing')
open(p,'w').write(s)
PY
    chmod 0600 "$cfg"
    /usr/local/lib/dual-trust-mieru/mihomo -t -d /etc/dual-trust-mieru/iran/dispatcher-data -f "$cfg" >/dev/null
    systemctl restart dual-dispatcher.service
    sleep 2
    systemctl is-active --quiet dual-dispatcher.service || { echo 'ERROR: dispatcher failed after sticky profile' >&2; return 1; }
    echo 'Applied: strategy=sticky-sessions, interval=120s, lazy=true.'
  fi

  if [[ -x /usr/local/lib/dual-trust-mieru-manager/install-autoheal.sh ]]; then
    bash /usr/local/lib/dual-trust-mieru-manager/install-autoheal.sh >/dev/null
  fi
}

# Existing production: upgrade management/health in place. Carrier services and
# x-ui are untouched. The dispatcher restarts only when the profile needs a
# change (including round-robin -> sticky-sessions).
if [[ -s /etc/dual-trust-mieru/iran/xudp.json ]]; then
  echo 'Existing dual installation detected: upgrading in place.'
  install_manager
  install -m 0755 "$B/dual-probe-final.sh" /usr/local/sbin/dual-tunnel-probe
  ensure_dispatcher_profile
  echo
  /usr/local/sbin/dual-health --full all || true
  echo
  echo 'UPGRADE COMPLETE. Use: dual status (option 3 migrates/replaces Naive)'
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

ensure_dispatcher_profile
/usr/local/sbin/dual-health --full all

echo
echo 'INSTALL COMPLETE'
echo 'Management menu: dual status'
echo 'Health only:     dual health --full'
echo 'Safe optimizer:  dual optimize'
