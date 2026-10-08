#!/usr/bin/env bash
set -Eeuo pipefail

D=/etc/dual-trust-mieru/iran
REPO_URL='https://github.com/aliiitavazoeiii-afk/frp-tunnel.git'
BRANCH='triple-carrier-naive'
HEALTH=/usr/local/sbin/dual-health
REPLACE=/usr/local/sbin/dual-replace-carrier
OPTIMIZER=/usr/local/sbin/dual-optimizer
AUTOHEAL_INSTALL=/usr/local/lib/dual-trust-mieru-manager/install-autoheal.sh
STATE=/var/lib/dual-trust-mieru/manager
SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=600 -o ControlPath=/run/dual-ssh-%C)
mkdir -p "$STATE" 2>/dev/null || true

if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; M=$'\e[35m'; B=$'\e[1m'; N=$'\e[0m'
else G=''; R=''; Y=''; C=''; M=''; B=''; N=''; fi

banner(){
  clear 2>/dev/null || true
  printf '%b' "$R$B"
  echo '██████╗ ██╗   ██╗ █████╗ ██╗     '
  echo '██╔══██╗██║   ██║██╔══██╗██║     '
  echo '██║  ██║██║   ██║███████║██║     '
  echo '██║  ██║██║   ██║██╔══██║██║     '
  echo '██████╔╝╚██████╔╝██║  ██║███████╗'
  echo '╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝'
  echo '      DUAL MIERU TRUST TUNNEL'
  echo '      power by ali tavazoei'
  printf '%b\n' "$N"
}

die(){ printf '%bERROR:%b %s\n' "$R" "$N" "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo -- "$0" "$@"; }
valid_ip(){
  local IFS=. a b c d extra o
  read -r a b c d extra <<<"$1"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for o in "$a" "$b" "$c" "$d"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] && (( 10#$o <= 255 )) || return 1; done
}
role_bundle(){ [[ "$1" == trust ]] && echo "$D/trust-bundle.json" || echo "$D/mieru-bundle.json"; }
role_node(){ [[ "$1" == trust ]] && echo 'XUDP-TRUST' || echo 'XUDP-MIERU'; }
role_tag(){ [[ "$1" == trust ]] && echo 'xudp-trust' || echo 'xudp-mieru'; }

endpoint_summary(){
  local t='unknown' m='unknown' n='not configured' np='DISABLED' a='unknown' d='unknown' x='unknown'
  [[ -s "$D/trust-bundle.json" ]] && t=$(jq -r '.public_ip // "unknown"' "$D/trust-bundle.json")
  [[ -s "$D/mieru-bundle.json" ]] && m=$(jq -r '.public_ip // "unknown"' "$D/mieru-bundle.json")
  [[ -s /etc/dual-trust-mieru/lane3/bundle.json ]] && n=$(jq -r '.public_ip // "unknown"' /etc/dual-trust-mieru/lane3/bundle.json)
  if [[ -s "$D/dispatcher.yaml" ]] && grep -Eq '^[[:space:]]*-[[:space:]]+XUDP-NAIVE[[:space:]]*
  d=$(systemctl is-active dual-dispatcher 2>/dev/null || true); [[ -n "$d" ]] || d=unknown
  x=$(systemctl is-active x-ui 2>/dev/null || true); [[ -n "$x" ]] || x=unknown
  printf '%b' "$R$B"
  printf '%-16s | %-24s\n' 'ROLE / SERVICE' 'STATUS / VALUE'
  printf '%-16s-+-%-24s\n' '----------------' '------------------------'
  printf '%-16s | %-24s\n' 'Trust IP' "$t"
  printf '%-16s | %-24s\n' 'Mieru IP' "$m"
  printf '%-16s | %-24s\n' 'Naive IP' "$n"
  printf '%-16s | %-24s\n' 'Naive in pool' "$np"
  printf '%-16s | %-24s\n' 'Autoheal' "$a"
  printf '%-16s | %-24s\n' 'Dispatcher' "$d"
  printf '%-16s | %-24s\n' 'x-ui' "$x"
  printf '%b' "$N"
}

apply_safe_profile(){
  [[ -s "$D/dispatcher.yaml" ]] || die 'dispatcher config missing'
  cp -a "$D/dispatcher.yaml" "$D/dispatcher.yaml.before-safe-profile-$(date -u +%Y%m%dT%H%M%SZ)"
  python3 - "$D/dispatcher.yaml" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'(?m)^(\s*interval:)\s*\d+\s*$', r'\1 120', s, count=1)
s=re.sub(r'(?m)^(\s*lazy:)\s*(?:true|false)\s*$', r'\1 true', s, count=1)
s=re.sub(r'(?m)^(\s*max-failed-times:)\s*\d+\s*
PY
  chmod 0600 "$D/dispatcher.yaml"
  /usr/local/lib/dual-trust-mieru/mihomo -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null
  systemctl restart dual-dispatcher.service
  sleep 2
  systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher failed after safe profile'
  if [[ -x "$AUTOHEAL_INSTALL" ]]; then bash "$AUTOHEAL_INSTALL"; fi
  echo "Applied: dispatcher strategy=sticky-sessions, interval=120s, lazy=true; autoheal=5m with randomized jitter."
}

refresh_node_health(){
  local role=$1 node secret
  node=$(role_node "$role")
  [[ -s "$D/controller.secret" ]] || return 0
  secret=$(<"$D/controller.secret")
  curl -sS --max-time 8 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:19090/proxies/$node/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000&expected=204" \
    >/dev/null 2>&1 || true
}

close_ssh_master(){
  local ip=$1
  ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true
}

remote_bootstrap(){
  local role=$1 ip=$2 uuid_file=$3 bundle=$4 domain='' email='' range=''
  scp "${SSH_OPTS[@]}" "$uuid_file" "root@$ip:/root/dual-live-uuid.txt"
  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    email=$(jq -r '.cert_email // empty' "$bundle")
    if [[ -z "$email" && -s "$STATE/trust-email" ]]; then email=$(<"$STATE/trust-email"); fi
    if [[ -z "$email" ]]; then
      read -r -p "Let's Encrypt email (one time): " email
      [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'invalid email'
      printf '%s\n' "$email" > "$STATE/trust-email"; chmod 0600 "$STATE/trust-email"
    fi
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$ip" || {
      echo
      printf '%bDNS is not pointing %s to %s yet.%b\n' "$Y" "$domain" "$ip" "$N"
      echo 'Change the A record, wait for it to resolve, then run Replace Trust again.'
      return 3
    }
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$domain" "$email" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role trust --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  else
    range=$(jq -r '.port_range // "20000-20020"' "$bundle")
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$range" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; REPO=$3; BRANCH=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  fi
}

cleanup_old_foreign(){
  local role=$1 old=$2
  valid_ip "$old" || return 0
  echo "Trying role-only cleanup on old $role foreign $old (key-auth only; no blocking password prompt)..."
  if [[ "$role" == trust ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/trust /root/dual-trust-client.json' \
      >/dev/null 2>&1 || echo 'Old Trust VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'mita stop >/dev/null 2>&1 || true; systemctl disable --now dual-xudp-mieru.service mita.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-xudp-mieru.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/mieru /root/dual-mieru-client.json' \
      >/dev/null 2>&1 || echo 'Old Mieru VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  fi
}

replace_role(){
  local role=$1 bundle old new tag live_uuid uuid_file new_bundle auto_was=0 domain remote_path rc
  bundle=$(role_bundle "$role"); [[ -s "$bundle" ]] || die "$role bundle missing"
  old=$(jq -r '.public_ip // empty' "$bundle")
  tag=$(role_tag "$role")
  live_uuid=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
  [[ "$live_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'live XUDP UUID missing'
  echo "Current $role foreign: $old"
  read -r -p "New $role foreign IPv4: " new
  valid_ip "$new" || die 'invalid IPv4'
  [[ "$new" != "$old" ]] || die 'new IP equals current IP'

  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || {
      printf '%bBefore Trust replacement, point %s A record to %s.%b\n' "$Y" "$domain" "$new" "$N"
      return 0
    }
  fi

  echo "Connecting to new VPS. SSH will ask for its root password once; the session is reused for the migration."
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-FOREIGN-SSH=OK' || die 'cannot SSH to new foreign'
  uuid_file=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$uuid_file"; printf '%s\n' "$live_uuid" > "$uuid_file"
  if ! remote_bootstrap "$role" "$new" "$uuid_file" "$bundle"; then
    rm -f "$uuid_file"; close_ssh_master "$new"; return 1
  fi
  rm -f "$uuid_file"

  new_bundle=$(mktemp "/root/new-${role}-bundle.XXXXXX.json")
  if [[ "$role" == trust ]]; then remote_path=/root/dual-trust-client.json; else remote_path=/root/dual-mieru-client.json; fi
  if ! scp "${SSH_OPTS[@]}" "root@$new:$remote_path" "$new_bundle"; then
    rm -f "$new_bundle"; close_ssh_master "$new"; return 1
  fi
  close_ssh_master "$new"
  chmod 0600 "$new_bundle"
  [[ $(jq -r '.kind' "$new_bundle") == "$role" ]] || die 'downloaded bundle has wrong role'
  [[ $(jq -r '.public_ip' "$new_bundle") == "$new" ]] || die 'downloaded bundle has wrong IP'
  [[ $(jq -r '.xudp_uuid' "$new_bundle") == "$live_uuid" ]] || die 'new foreign UUID does not match live Iran UUID'

  systemctl is-active --quiet dual-tunnel-autoheal.timer 2>/dev/null && auto_was=1 || true
  systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
  set +e
  "$REPLACE" "$role" "$new_bundle"
  rc=$?
  set -e
  (( auto_was )) && systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
  (( rc == 0 )) || { echo "Cutover failed; old $role carrier was restored by rollback."; rm -f "$new_bundle"; return "$rc"; }

  refresh_node_health "$role"
  if "$HEALTH" --full "$role"; then
    printf '%b%s replacement PASSED full role health.%b\n' "$G" "${role^^}" "$N"
    echo "Old $role foreign $old was NOT deleted automatically; keep it available for rollback."
    echo 'New user connections are automatically eligible for load balancing now.'
  else
    printf '%b%s cutover is up but full post-check is degraded. Old foreign was NOT cleaned.%b\n' "$Y" "${role^^}" "$N"
  fi
  rm -f "$new_bundle"
}

restart_role(){
  local s
  case "$1" in trust) s=dual-trust-client.service;; mieru) s=dual-mieru-carrier.service;; esac
  systemctl restart "$s"; sleep 3; "$HEALTH" --quick "$1" || true
}

show_logs(){
  journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service \
    -u lane3-naive-client.service -u lane3-xudp-router.service --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|closed pipe|reset|failed' | tail -n 120 || true
}

run_optimizer(){
  [[ -x "$OPTIMIZER" ]] || die 'dual optimizer is not installed; run dual-install-iran.sh upgrade first'
  "$OPTIMIZER"
}

need_root "$@"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'

case "${1:-}" in
  --apply-safe-profile) apply_safe_profile; exit 0 ;;
  --health) "$HEALTH" "${2:---quick}" "${3:-all}"; exit $? ;;
  --optimize) run_optimizer; exit $? ;;
esac

while true; do
  banner; endpoint_summary
  echo
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Trust foreign server'
  echo '  4) Replace Mieru foreign server'
  echo '  5) Restart Trust carrier only'
  echo '  6) Restart Mieru carrier only'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Re-apply low-noise health profile'
  echo '  9) Safe server optimizer / cleanup'
  echo ' 10) Manage Naive third carrier / unified pool'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$HEALTH" --quick all || true ;;
    2) "$HEALTH" --full all || true ;;
    3) replace_role trust || true ;;
    4) replace_role mieru || true ;;
    5) restart_role trust ;;
    6) restart_role mieru ;;
    7) show_logs ;;
    8) apply_safe_profile ;;
    9) run_optimizer ;;
    10) if [[ -x /usr/local/sbin/lane3-manager ]]; then /usr/local/sbin/lane3-manager; else echo 'Naive helper is not installed yet.'; fi ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  echo; read -r -p 'Press Enter to continue...' _
done
 "$D/dispatcher.yaml"; then np='ENABLED'; fi
  a=$(systemctl is-active dual-tunnel-autoheal.timer 2>/dev/null || true); [[ -n "$a" ]] || a=unknown
  d=$(systemctl is-active dual-dispatcher 2>/dev/null || true); [[ -n "$d" ]] || d=unknown
  x=$(systemctl is-active x-ui 2>/dev/null || true); [[ -n "$x" ]] || x=unknown
  printf '%b' "$R$B"
  printf '%-16s | %-24s\n' 'ROLE / SERVICE' 'STATUS / VALUE'
  printf '%-16s-+-%-24s\n' '----------------' '------------------------'
  printf '%-16s | %-24s\n' 'Trust IP' "$t"
  printf '%-16s | %-24s\n' 'Mieru IP' "$m"
  printf '%-16s | %-24s\n' 'Autoheal' "$a"
  printf '%-16s | %-24s\n' 'Dispatcher' "$d"
  printf '%-16s | %-24s\n' 'x-ui' "$x"
  printf '%b' "$N"
}

apply_safe_profile(){
  [[ -s "$D/dispatcher.yaml" ]] || die 'dispatcher config missing'
  cp -a "$D/dispatcher.yaml" "$D/dispatcher.yaml.before-safe-profile-$(date -u +%Y%m%dT%H%M%SZ)"
  python3 - "$D/dispatcher.yaml" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'(?m)^(\s*interval:)\s*\d+\s*$', r'\1 120', s, count=1)
s=re.sub(r'(?m)^(\s*lazy:)\s*(?:true|false)\s*$', r'\1 true', s, count=1)
s=re.sub(r'(?m)^(\s*max-failed-times:)\s*\d+\s*$', r'\1 2', s, count=1)
open(p,'w').write(s)
PY
  chmod 0600 "$D/dispatcher.yaml"
  /usr/local/lib/dual-trust-mieru/mihomo -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null
  systemctl restart dual-dispatcher.service
  sleep 2
  systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher failed after safe profile'
  if [[ -x "$AUTOHEAL_INSTALL" ]]; then bash "$AUTOHEAL_INSTALL"; fi
  echo "Applied: dispatcher health interval=120s, lazy=true; autoheal=5m with randomized jitter."
}

refresh_node_health(){
  local role=$1 node secret
  node=$(role_node "$role")
  [[ -s "$D/controller.secret" ]] || return 0
  secret=$(<"$D/controller.secret")
  curl -sS --max-time 8 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:19090/proxies/$node/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000&expected=204" \
    >/dev/null 2>&1 || true
}

close_ssh_master(){
  local ip=$1
  ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true
}

remote_bootstrap(){
  local role=$1 ip=$2 uuid_file=$3 bundle=$4 domain='' email='' range=''
  scp "${SSH_OPTS[@]}" "$uuid_file" "root@$ip:/root/dual-live-uuid.txt"
  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    email=$(jq -r '.cert_email // empty' "$bundle")
    if [[ -z "$email" && -s "$STATE/trust-email" ]]; then email=$(<"$STATE/trust-email"); fi
    if [[ -z "$email" ]]; then
      read -r -p "Let's Encrypt email (one time): " email
      [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'invalid email'
      printf '%s\n' "$email" > "$STATE/trust-email"; chmod 0600 "$STATE/trust-email"
    fi
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$ip" || {
      echo
      printf '%bDNS is not pointing %s to %s yet.%b\n' "$Y" "$domain" "$ip" "$N"
      echo 'Change the A record, wait for it to resolve, then run Replace Trust again.'
      return 3
    }
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$domain" "$email" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role trust --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  else
    range=$(jq -r '.port_range // "20000-20020"' "$bundle")
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$range" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; REPO=$3; BRANCH=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  fi
}

cleanup_old_foreign(){
  local role=$1 old=$2
  valid_ip "$old" || return 0
  echo "Trying role-only cleanup on old $role foreign $old (key-auth only; no blocking password prompt)..."
  if [[ "$role" == trust ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/trust /root/dual-trust-client.json' \
      >/dev/null 2>&1 || echo 'Old Trust VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'mita stop >/dev/null 2>&1 || true; systemctl disable --now dual-xudp-mieru.service mita.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-xudp-mieru.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/mieru /root/dual-mieru-client.json' \
      >/dev/null 2>&1 || echo 'Old Mieru VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  fi
}

replace_role(){
  local role=$1 bundle old new tag live_uuid uuid_file new_bundle auto_was=0 domain remote_path rc
  bundle=$(role_bundle "$role"); [[ -s "$bundle" ]] || die "$role bundle missing"
  old=$(jq -r '.public_ip // empty' "$bundle")
  tag=$(role_tag "$role")
  live_uuid=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
  [[ "$live_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'live XUDP UUID missing'
  echo "Current $role foreign: $old"
  read -r -p "New $role foreign IPv4: " new
  valid_ip "$new" || die 'invalid IPv4'
  [[ "$new" != "$old" ]] || die 'new IP equals current IP'

  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || {
      printf '%bBefore Trust replacement, point %s A record to %s.%b\n' "$Y" "$domain" "$new" "$N"
      return 0
    }
  fi

  echo "Connecting to new VPS. SSH will ask for its root password once; the session is reused for the migration."
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-FOREIGN-SSH=OK' || die 'cannot SSH to new foreign'
  uuid_file=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$uuid_file"; printf '%s\n' "$live_uuid" > "$uuid_file"
  if ! remote_bootstrap "$role" "$new" "$uuid_file" "$bundle"; then
    rm -f "$uuid_file"; close_ssh_master "$new"; return 1
  fi
  rm -f "$uuid_file"

  new_bundle=$(mktemp "/root/new-${role}-bundle.XXXXXX.json")
  if [[ "$role" == trust ]]; then remote_path=/root/dual-trust-client.json; else remote_path=/root/dual-mieru-client.json; fi
  if ! scp "${SSH_OPTS[@]}" "root@$new:$remote_path" "$new_bundle"; then
    rm -f "$new_bundle"; close_ssh_master "$new"; return 1
  fi
  close_ssh_master "$new"
  chmod 0600 "$new_bundle"
  [[ $(jq -r '.kind' "$new_bundle") == "$role" ]] || die 'downloaded bundle has wrong role'
  [[ $(jq -r '.public_ip' "$new_bundle") == "$new" ]] || die 'downloaded bundle has wrong IP'
  [[ $(jq -r '.xudp_uuid' "$new_bundle") == "$live_uuid" ]] || die 'new foreign UUID does not match live Iran UUID'

  systemctl is-active --quiet dual-tunnel-autoheal.timer 2>/dev/null && auto_was=1 || true
  systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
  set +e
  "$REPLACE" "$role" "$new_bundle"
  rc=$?
  set -e
  (( auto_was )) && systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
  (( rc == 0 )) || { echo "Cutover failed; old $role carrier was restored by rollback."; rm -f "$new_bundle"; return "$rc"; }

  refresh_node_health "$role"
  if "$HEALTH" --full "$role"; then
    printf '%b%s replacement PASSED full role health.%b\n' "$G" "${role^^}" "$N"
    cleanup_old_foreign "$role" "$old"
    echo 'New user connections are automatically eligible for load balancing now.'
  else
    printf '%b%s cutover is up but full post-check is degraded. Old foreign was NOT cleaned.%b\n' "$Y" "${role^^}" "$N"
  fi
  rm -f "$new_bundle"
}

restart_role(){
  local s
  case "$1" in trust) s=dual-trust-client.service;; mieru) s=dual-mieru-carrier.service;; esac
  systemctl restart "$s"; sleep 3; "$HEALTH" --quick "$1" || true
}

show_logs(){
  journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service \
    --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|closed pipe|reset|failed' | tail -n 120 || true
}

run_optimizer(){
  [[ -x "$OPTIMIZER" ]] || die 'dual optimizer is not installed; run dual-install-iran.sh upgrade first'
  "$OPTIMIZER"
}

need_root "$@"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'

case "${1:-}" in
  --apply-safe-profile) apply_safe_profile; exit 0 ;;
  --health) "$HEALTH" "${2:---quick}" "${3:-all}"; exit $? ;;
  --optimize) run_optimizer; exit $? ;;
esac

while true; do
  banner; endpoint_summary
  echo
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Trust foreign server'
  echo '  4) Replace Mieru foreign server'
  echo '  5) Restart Trust carrier only'
  echo '  6) Restart Mieru carrier only'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Re-apply low-noise health profile'
  echo '  9) Safe server optimizer / cleanup'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$HEALTH" --quick all || true ;;
    2) "$HEALTH" --full all || true ;;
    3) replace_role trust || true ;;
    4) replace_role mieru || true ;;
    5) restart_role trust ;;
    6) restart_role mieru ;;
    7) show_logs ;;
    8) apply_safe_profile ;;
    9) run_optimizer ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  echo; read -r -p 'Press Enter to continue...' _
done
, r'\1 2', s, count=1)
if re.search(r'(?m)^\s*strategy:\s*\S+\s*
PY
  chmod 0600 "$D/dispatcher.yaml"
  /usr/local/lib/dual-trust-mieru/mihomo -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null
  systemctl restart dual-dispatcher.service
  sleep 2
  systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher failed after safe profile'
  if [[ -x "$AUTOHEAL_INSTALL" ]]; then bash "$AUTOHEAL_INSTALL"; fi
  echo "Applied: dispatcher health interval=120s, lazy=true; autoheal=5m with randomized jitter."
}

refresh_node_health(){
  local role=$1 node secret
  node=$(role_node "$role")
  [[ -s "$D/controller.secret" ]] || return 0
  secret=$(<"$D/controller.secret")
  curl -sS --max-time 8 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:19090/proxies/$node/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000&expected=204" \
    >/dev/null 2>&1 || true
}

close_ssh_master(){
  local ip=$1
  ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true
}

remote_bootstrap(){
  local role=$1 ip=$2 uuid_file=$3 bundle=$4 domain='' email='' range=''
  scp "${SSH_OPTS[@]}" "$uuid_file" "root@$ip:/root/dual-live-uuid.txt"
  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    email=$(jq -r '.cert_email // empty' "$bundle")
    if [[ -z "$email" && -s "$STATE/trust-email" ]]; then email=$(<"$STATE/trust-email"); fi
    if [[ -z "$email" ]]; then
      read -r -p "Let's Encrypt email (one time): " email
      [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'invalid email'
      printf '%s\n' "$email" > "$STATE/trust-email"; chmod 0600 "$STATE/trust-email"
    fi
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$ip" || {
      echo
      printf '%bDNS is not pointing %s to %s yet.%b\n' "$Y" "$domain" "$ip" "$N"
      echo 'Change the A record, wait for it to resolve, then run Replace Trust again.'
      return 3
    }
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$domain" "$email" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role trust --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  else
    range=$(jq -r '.port_range // "20000-20020"' "$bundle")
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$range" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; REPO=$3; BRANCH=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  fi
}

cleanup_old_foreign(){
  local role=$1 old=$2
  valid_ip "$old" || return 0
  echo "Trying role-only cleanup on old $role foreign $old (key-auth only; no blocking password prompt)..."
  if [[ "$role" == trust ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/trust /root/dual-trust-client.json' \
      >/dev/null 2>&1 || echo 'Old Trust VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'mita stop >/dev/null 2>&1 || true; systemctl disable --now dual-xudp-mieru.service mita.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-xudp-mieru.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/mieru /root/dual-mieru-client.json' \
      >/dev/null 2>&1 || echo 'Old Mieru VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  fi
}

replace_role(){
  local role=$1 bundle old new tag live_uuid uuid_file new_bundle auto_was=0 domain remote_path rc
  bundle=$(role_bundle "$role"); [[ -s "$bundle" ]] || die "$role bundle missing"
  old=$(jq -r '.public_ip // empty' "$bundle")
  tag=$(role_tag "$role")
  live_uuid=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
  [[ "$live_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'live XUDP UUID missing'
  echo "Current $role foreign: $old"
  read -r -p "New $role foreign IPv4: " new
  valid_ip "$new" || die 'invalid IPv4'
  [[ "$new" != "$old" ]] || die 'new IP equals current IP'

  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || {
      printf '%bBefore Trust replacement, point %s A record to %s.%b\n' "$Y" "$domain" "$new" "$N"
      return 0
    }
  fi

  echo "Connecting to new VPS. SSH will ask for its root password once; the session is reused for the migration."
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-FOREIGN-SSH=OK' || die 'cannot SSH to new foreign'
  uuid_file=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$uuid_file"; printf '%s\n' "$live_uuid" > "$uuid_file"
  if ! remote_bootstrap "$role" "$new" "$uuid_file" "$bundle"; then
    rm -f "$uuid_file"; close_ssh_master "$new"; return 1
  fi
  rm -f "$uuid_file"

  new_bundle=$(mktemp "/root/new-${role}-bundle.XXXXXX.json")
  if [[ "$role" == trust ]]; then remote_path=/root/dual-trust-client.json; else remote_path=/root/dual-mieru-client.json; fi
  if ! scp "${SSH_OPTS[@]}" "root@$new:$remote_path" "$new_bundle"; then
    rm -f "$new_bundle"; close_ssh_master "$new"; return 1
  fi
  close_ssh_master "$new"
  chmod 0600 "$new_bundle"
  [[ $(jq -r '.kind' "$new_bundle") == "$role" ]] || die 'downloaded bundle has wrong role'
  [[ $(jq -r '.public_ip' "$new_bundle") == "$new" ]] || die 'downloaded bundle has wrong IP'
  [[ $(jq -r '.xudp_uuid' "$new_bundle") == "$live_uuid" ]] || die 'new foreign UUID does not match live Iran UUID'

  systemctl is-active --quiet dual-tunnel-autoheal.timer 2>/dev/null && auto_was=1 || true
  systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
  set +e
  "$REPLACE" "$role" "$new_bundle"
  rc=$?
  set -e
  (( auto_was )) && systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
  (( rc == 0 )) || { echo "Cutover failed; old $role carrier was restored by rollback."; rm -f "$new_bundle"; return "$rc"; }

  refresh_node_health "$role"
  if "$HEALTH" --full "$role"; then
    printf '%b%s replacement PASSED full role health.%b\n' "$G" "${role^^}" "$N"
    echo "Old $role foreign $old was NOT deleted automatically; keep it available for rollback."
    echo 'New user connections are automatically eligible for load balancing now.'
  else
    printf '%b%s cutover is up but full post-check is degraded. Old foreign was NOT cleaned.%b\n' "$Y" "${role^^}" "$N"
  fi
  rm -f "$new_bundle"
}

restart_role(){
  local s
  case "$1" in trust) s=dual-trust-client.service;; mieru) s=dual-mieru-carrier.service;; esac
  systemctl restart "$s"; sleep 3; "$HEALTH" --quick "$1" || true
}

show_logs(){
  journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service \
    -u lane3-naive-client.service -u lane3-xudp-router.service --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|closed pipe|reset|failed' | tail -n 120 || true
}

run_optimizer(){
  [[ -x "$OPTIMIZER" ]] || die 'dual optimizer is not installed; run dual-install-iran.sh upgrade first'
  "$OPTIMIZER"
}

need_root "$@"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'

case "${1:-}" in
  --apply-safe-profile) apply_safe_profile; exit 0 ;;
  --health) "$HEALTH" "${2:---quick}" "${3:-all}"; exit $? ;;
  --optimize) run_optimizer; exit $? ;;
esac

while true; do
  banner; endpoint_summary
  echo
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Trust foreign server'
  echo '  4) Replace Mieru foreign server'
  echo '  5) Restart Trust carrier only'
  echo '  6) Restart Mieru carrier only'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Re-apply low-noise health profile'
  echo '  9) Safe server optimizer / cleanup'
  echo ' 10) Manage Naive third carrier / unified pool'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$HEALTH" --quick all || true ;;
    2) "$HEALTH" --full all || true ;;
    3) replace_role trust || true ;;
    4) replace_role mieru || true ;;
    5) restart_role trust ;;
    6) restart_role mieru ;;
    7) show_logs ;;
    8) apply_safe_profile ;;
    9) run_optimizer ;;
    10) if [[ -x /usr/local/sbin/lane3-manager ]]; then /usr/local/sbin/lane3-manager; else echo 'Naive helper is not installed yet.'; fi ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  echo; read -r -p 'Press Enter to continue...' _
done
 "$D/dispatcher.yaml"; then np='ENABLED'; fi
  a=$(systemctl is-active dual-tunnel-autoheal.timer 2>/dev/null || true); [[ -n "$a" ]] || a=unknown
  d=$(systemctl is-active dual-dispatcher 2>/dev/null || true); [[ -n "$d" ]] || d=unknown
  x=$(systemctl is-active x-ui 2>/dev/null || true); [[ -n "$x" ]] || x=unknown
  printf '%b' "$R$B"
  printf '%-16s | %-24s\n' 'ROLE / SERVICE' 'STATUS / VALUE'
  printf '%-16s-+-%-24s\n' '----------------' '------------------------'
  printf '%-16s | %-24s\n' 'Trust IP' "$t"
  printf '%-16s | %-24s\n' 'Mieru IP' "$m"
  printf '%-16s | %-24s\n' 'Autoheal' "$a"
  printf '%-16s | %-24s\n' 'Dispatcher' "$d"
  printf '%-16s | %-24s\n' 'x-ui' "$x"
  printf '%b' "$N"
}

apply_safe_profile(){
  [[ -s "$D/dispatcher.yaml" ]] || die 'dispatcher config missing'
  cp -a "$D/dispatcher.yaml" "$D/dispatcher.yaml.before-safe-profile-$(date -u +%Y%m%dT%H%M%SZ)"
  python3 - "$D/dispatcher.yaml" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'(?m)^(\s*interval:)\s*\d+\s*$', r'\1 120', s, count=1)
s=re.sub(r'(?m)^(\s*lazy:)\s*(?:true|false)\s*$', r'\1 true', s, count=1)
s=re.sub(r'(?m)^(\s*max-failed-times:)\s*\d+\s*$', r'\1 2', s, count=1)
open(p,'w').write(s)
PY
  chmod 0600 "$D/dispatcher.yaml"
  /usr/local/lib/dual-trust-mieru/mihomo -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null
  systemctl restart dual-dispatcher.service
  sleep 2
  systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher failed after safe profile'
  if [[ -x "$AUTOHEAL_INSTALL" ]]; then bash "$AUTOHEAL_INSTALL"; fi
  echo "Applied: dispatcher health interval=120s, lazy=true; autoheal=5m with randomized jitter."
}

refresh_node_health(){
  local role=$1 node secret
  node=$(role_node "$role")
  [[ -s "$D/controller.secret" ]] || return 0
  secret=$(<"$D/controller.secret")
  curl -sS --max-time 8 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:19090/proxies/$node/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000&expected=204" \
    >/dev/null 2>&1 || true
}

close_ssh_master(){
  local ip=$1
  ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true
}

remote_bootstrap(){
  local role=$1 ip=$2 uuid_file=$3 bundle=$4 domain='' email='' range=''
  scp "${SSH_OPTS[@]}" "$uuid_file" "root@$ip:/root/dual-live-uuid.txt"
  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    email=$(jq -r '.cert_email // empty' "$bundle")
    if [[ -z "$email" && -s "$STATE/trust-email" ]]; then email=$(<"$STATE/trust-email"); fi
    if [[ -z "$email" ]]; then
      read -r -p "Let's Encrypt email (one time): " email
      [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'invalid email'
      printf '%s\n' "$email" > "$STATE/trust-email"; chmod 0600 "$STATE/trust-email"
    fi
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$ip" || {
      echo
      printf '%bDNS is not pointing %s to %s yet.%b\n' "$Y" "$domain" "$ip" "$N"
      echo 'Change the A record, wait for it to resolve, then run Replace Trust again.'
      return 3
    }
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$domain" "$email" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role trust --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  else
    range=$(jq -r '.port_range // "20000-20020"' "$bundle")
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$range" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; REPO=$3; BRANCH=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  fi
}

cleanup_old_foreign(){
  local role=$1 old=$2
  valid_ip "$old" || return 0
  echo "Trying role-only cleanup on old $role foreign $old (key-auth only; no blocking password prompt)..."
  if [[ "$role" == trust ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/trust /root/dual-trust-client.json' \
      >/dev/null 2>&1 || echo 'Old Trust VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'mita stop >/dev/null 2>&1 || true; systemctl disable --now dual-xudp-mieru.service mita.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-xudp-mieru.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/mieru /root/dual-mieru-client.json' \
      >/dev/null 2>&1 || echo 'Old Mieru VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  fi
}

replace_role(){
  local role=$1 bundle old new tag live_uuid uuid_file new_bundle auto_was=0 domain remote_path rc
  bundle=$(role_bundle "$role"); [[ -s "$bundle" ]] || die "$role bundle missing"
  old=$(jq -r '.public_ip // empty' "$bundle")
  tag=$(role_tag "$role")
  live_uuid=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
  [[ "$live_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'live XUDP UUID missing'
  echo "Current $role foreign: $old"
  read -r -p "New $role foreign IPv4: " new
  valid_ip "$new" || die 'invalid IPv4'
  [[ "$new" != "$old" ]] || die 'new IP equals current IP'

  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || {
      printf '%bBefore Trust replacement, point %s A record to %s.%b\n' "$Y" "$domain" "$new" "$N"
      return 0
    }
  fi

  echo "Connecting to new VPS. SSH will ask for its root password once; the session is reused for the migration."
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-FOREIGN-SSH=OK' || die 'cannot SSH to new foreign'
  uuid_file=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$uuid_file"; printf '%s\n' "$live_uuid" > "$uuid_file"
  if ! remote_bootstrap "$role" "$new" "$uuid_file" "$bundle"; then
    rm -f "$uuid_file"; close_ssh_master "$new"; return 1
  fi
  rm -f "$uuid_file"

  new_bundle=$(mktemp "/root/new-${role}-bundle.XXXXXX.json")
  if [[ "$role" == trust ]]; then remote_path=/root/dual-trust-client.json; else remote_path=/root/dual-mieru-client.json; fi
  if ! scp "${SSH_OPTS[@]}" "root@$new:$remote_path" "$new_bundle"; then
    rm -f "$new_bundle"; close_ssh_master "$new"; return 1
  fi
  close_ssh_master "$new"
  chmod 0600 "$new_bundle"
  [[ $(jq -r '.kind' "$new_bundle") == "$role" ]] || die 'downloaded bundle has wrong role'
  [[ $(jq -r '.public_ip' "$new_bundle") == "$new" ]] || die 'downloaded bundle has wrong IP'
  [[ $(jq -r '.xudp_uuid' "$new_bundle") == "$live_uuid" ]] || die 'new foreign UUID does not match live Iran UUID'

  systemctl is-active --quiet dual-tunnel-autoheal.timer 2>/dev/null && auto_was=1 || true
  systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
  set +e
  "$REPLACE" "$role" "$new_bundle"
  rc=$?
  set -e
  (( auto_was )) && systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
  (( rc == 0 )) || { echo "Cutover failed; old $role carrier was restored by rollback."; rm -f "$new_bundle"; return "$rc"; }

  refresh_node_health "$role"
  if "$HEALTH" --full "$role"; then
    printf '%b%s replacement PASSED full role health.%b\n' "$G" "${role^^}" "$N"
    cleanup_old_foreign "$role" "$old"
    echo 'New user connections are automatically eligible for load balancing now.'
  else
    printf '%b%s cutover is up but full post-check is degraded. Old foreign was NOT cleaned.%b\n' "$Y" "${role^^}" "$N"
  fi
  rm -f "$new_bundle"
}

restart_role(){
  local s
  case "$1" in trust) s=dual-trust-client.service;; mieru) s=dual-mieru-carrier.service;; esac
  systemctl restart "$s"; sleep 3; "$HEALTH" --quick "$1" || true
}

show_logs(){
  journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service \
    --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|closed pipe|reset|failed' | tail -n 120 || true
}

run_optimizer(){
  [[ -x "$OPTIMIZER" ]] || die 'dual optimizer is not installed; run dual-install-iran.sh upgrade first'
  "$OPTIMIZER"
}

need_root "$@"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'

case "${1:-}" in
  --apply-safe-profile) apply_safe_profile; exit 0 ;;
  --health) "$HEALTH" "${2:---quick}" "${3:-all}"; exit $? ;;
  --optimize) run_optimizer; exit $? ;;
esac

while true; do
  banner; endpoint_summary
  echo
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Trust foreign server'
  echo '  4) Replace Mieru foreign server'
  echo '  5) Restart Trust carrier only'
  echo '  6) Restart Mieru carrier only'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Re-apply low-noise health profile'
  echo '  9) Safe server optimizer / cleanup'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$HEALTH" --quick all || true ;;
    2) "$HEALTH" --full all || true ;;
    3) replace_role trust || true ;;
    4) replace_role mieru || true ;;
    5) restart_role trust ;;
    6) restart_role mieru ;;
    7) show_logs ;;
    8) apply_safe_profile ;;
    9) run_optimizer ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  echo; read -r -p 'Press Enter to continue...' _
done
, s):
    s=re.sub(r'(?m)^(\s*strategy:)\s*\S+\s*
PY
  chmod 0600 "$D/dispatcher.yaml"
  /usr/local/lib/dual-trust-mieru/mihomo -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null
  systemctl restart dual-dispatcher.service
  sleep 2
  systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher failed after safe profile'
  if [[ -x "$AUTOHEAL_INSTALL" ]]; then bash "$AUTOHEAL_INSTALL"; fi
  echo "Applied: dispatcher health interval=120s, lazy=true; autoheal=5m with randomized jitter."
}

refresh_node_health(){
  local role=$1 node secret
  node=$(role_node "$role")
  [[ -s "$D/controller.secret" ]] || return 0
  secret=$(<"$D/controller.secret")
  curl -sS --max-time 8 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:19090/proxies/$node/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000&expected=204" \
    >/dev/null 2>&1 || true
}

close_ssh_master(){
  local ip=$1
  ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true
}

remote_bootstrap(){
  local role=$1 ip=$2 uuid_file=$3 bundle=$4 domain='' email='' range=''
  scp "${SSH_OPTS[@]}" "$uuid_file" "root@$ip:/root/dual-live-uuid.txt"
  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    email=$(jq -r '.cert_email // empty' "$bundle")
    if [[ -z "$email" && -s "$STATE/trust-email" ]]; then email=$(<"$STATE/trust-email"); fi
    if [[ -z "$email" ]]; then
      read -r -p "Let's Encrypt email (one time): " email
      [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'invalid email'
      printf '%s\n' "$email" > "$STATE/trust-email"; chmod 0600 "$STATE/trust-email"
    fi
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$ip" || {
      echo
      printf '%bDNS is not pointing %s to %s yet.%b\n' "$Y" "$domain" "$ip" "$N"
      echo 'Change the A record, wait for it to resolve, then run Replace Trust again.'
      return 3
    }
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$domain" "$email" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role trust --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  else
    range=$(jq -r '.port_range // "20000-20020"' "$bundle")
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$range" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; REPO=$3; BRANCH=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  fi
}

cleanup_old_foreign(){
  local role=$1 old=$2
  valid_ip "$old" || return 0
  echo "Trying role-only cleanup on old $role foreign $old (key-auth only; no blocking password prompt)..."
  if [[ "$role" == trust ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/trust /root/dual-trust-client.json' \
      >/dev/null 2>&1 || echo 'Old Trust VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'mita stop >/dev/null 2>&1 || true; systemctl disable --now dual-xudp-mieru.service mita.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-xudp-mieru.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/mieru /root/dual-mieru-client.json' \
      >/dev/null 2>&1 || echo 'Old Mieru VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  fi
}

replace_role(){
  local role=$1 bundle old new tag live_uuid uuid_file new_bundle auto_was=0 domain remote_path rc
  bundle=$(role_bundle "$role"); [[ -s "$bundle" ]] || die "$role bundle missing"
  old=$(jq -r '.public_ip // empty' "$bundle")
  tag=$(role_tag "$role")
  live_uuid=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
  [[ "$live_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'live XUDP UUID missing'
  echo "Current $role foreign: $old"
  read -r -p "New $role foreign IPv4: " new
  valid_ip "$new" || die 'invalid IPv4'
  [[ "$new" != "$old" ]] || die 'new IP equals current IP'

  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || {
      printf '%bBefore Trust replacement, point %s A record to %s.%b\n' "$Y" "$domain" "$new" "$N"
      return 0
    }
  fi

  echo "Connecting to new VPS. SSH will ask for its root password once; the session is reused for the migration."
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-FOREIGN-SSH=OK' || die 'cannot SSH to new foreign'
  uuid_file=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$uuid_file"; printf '%s\n' "$live_uuid" > "$uuid_file"
  if ! remote_bootstrap "$role" "$new" "$uuid_file" "$bundle"; then
    rm -f "$uuid_file"; close_ssh_master "$new"; return 1
  fi
  rm -f "$uuid_file"

  new_bundle=$(mktemp "/root/new-${role}-bundle.XXXXXX.json")
  if [[ "$role" == trust ]]; then remote_path=/root/dual-trust-client.json; else remote_path=/root/dual-mieru-client.json; fi
  if ! scp "${SSH_OPTS[@]}" "root@$new:$remote_path" "$new_bundle"; then
    rm -f "$new_bundle"; close_ssh_master "$new"; return 1
  fi
  close_ssh_master "$new"
  chmod 0600 "$new_bundle"
  [[ $(jq -r '.kind' "$new_bundle") == "$role" ]] || die 'downloaded bundle has wrong role'
  [[ $(jq -r '.public_ip' "$new_bundle") == "$new" ]] || die 'downloaded bundle has wrong IP'
  [[ $(jq -r '.xudp_uuid' "$new_bundle") == "$live_uuid" ]] || die 'new foreign UUID does not match live Iran UUID'

  systemctl is-active --quiet dual-tunnel-autoheal.timer 2>/dev/null && auto_was=1 || true
  systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
  set +e
  "$REPLACE" "$role" "$new_bundle"
  rc=$?
  set -e
  (( auto_was )) && systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
  (( rc == 0 )) || { echo "Cutover failed; old $role carrier was restored by rollback."; rm -f "$new_bundle"; return "$rc"; }

  refresh_node_health "$role"
  if "$HEALTH" --full "$role"; then
    printf '%b%s replacement PASSED full role health.%b\n' "$G" "${role^^}" "$N"
    echo "Old $role foreign $old was NOT deleted automatically; keep it available for rollback."
    echo 'New user connections are automatically eligible for load balancing now.'
  else
    printf '%b%s cutover is up but full post-check is degraded. Old foreign was NOT cleaned.%b\n' "$Y" "${role^^}" "$N"
  fi
  rm -f "$new_bundle"
}

restart_role(){
  local s
  case "$1" in trust) s=dual-trust-client.service;; mieru) s=dual-mieru-carrier.service;; esac
  systemctl restart "$s"; sleep 3; "$HEALTH" --quick "$1" || true
}

show_logs(){
  journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service \
    -u lane3-naive-client.service -u lane3-xudp-router.service --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|closed pipe|reset|failed' | tail -n 120 || true
}

run_optimizer(){
  [[ -x "$OPTIMIZER" ]] || die 'dual optimizer is not installed; run dual-install-iran.sh upgrade first'
  "$OPTIMIZER"
}

need_root "$@"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'

case "${1:-}" in
  --apply-safe-profile) apply_safe_profile; exit 0 ;;
  --health) "$HEALTH" "${2:---quick}" "${3:-all}"; exit $? ;;
  --optimize) run_optimizer; exit $? ;;
esac

while true; do
  banner; endpoint_summary
  echo
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Trust foreign server'
  echo '  4) Replace Mieru foreign server'
  echo '  5) Restart Trust carrier only'
  echo '  6) Restart Mieru carrier only'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Re-apply low-noise health profile'
  echo '  9) Safe server optimizer / cleanup'
  echo ' 10) Manage Naive third carrier / unified pool'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$HEALTH" --quick all || true ;;
    2) "$HEALTH" --full all || true ;;
    3) replace_role trust || true ;;
    4) replace_role mieru || true ;;
    5) restart_role trust ;;
    6) restart_role mieru ;;
    7) show_logs ;;
    8) apply_safe_profile ;;
    9) run_optimizer ;;
    10) if [[ -x /usr/local/sbin/lane3-manager ]]; then /usr/local/sbin/lane3-manager; else echo 'Naive helper is not installed yet.'; fi ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  echo; read -r -p 'Press Enter to continue...' _
done
 "$D/dispatcher.yaml"; then np='ENABLED'; fi
  a=$(systemctl is-active dual-tunnel-autoheal.timer 2>/dev/null || true); [[ -n "$a" ]] || a=unknown
  d=$(systemctl is-active dual-dispatcher 2>/dev/null || true); [[ -n "$d" ]] || d=unknown
  x=$(systemctl is-active x-ui 2>/dev/null || true); [[ -n "$x" ]] || x=unknown
  printf '%b' "$R$B"
  printf '%-16s | %-24s\n' 'ROLE / SERVICE' 'STATUS / VALUE'
  printf '%-16s-+-%-24s\n' '----------------' '------------------------'
  printf '%-16s | %-24s\n' 'Trust IP' "$t"
  printf '%-16s | %-24s\n' 'Mieru IP' "$m"
  printf '%-16s | %-24s\n' 'Autoheal' "$a"
  printf '%-16s | %-24s\n' 'Dispatcher' "$d"
  printf '%-16s | %-24s\n' 'x-ui' "$x"
  printf '%b' "$N"
}

apply_safe_profile(){
  [[ -s "$D/dispatcher.yaml" ]] || die 'dispatcher config missing'
  cp -a "$D/dispatcher.yaml" "$D/dispatcher.yaml.before-safe-profile-$(date -u +%Y%m%dT%H%M%SZ)"
  python3 - "$D/dispatcher.yaml" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'(?m)^(\s*interval:)\s*\d+\s*$', r'\1 120', s, count=1)
s=re.sub(r'(?m)^(\s*lazy:)\s*(?:true|false)\s*$', r'\1 true', s, count=1)
s=re.sub(r'(?m)^(\s*max-failed-times:)\s*\d+\s*$', r'\1 2', s, count=1)
open(p,'w').write(s)
PY
  chmod 0600 "$D/dispatcher.yaml"
  /usr/local/lib/dual-trust-mieru/mihomo -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null
  systemctl restart dual-dispatcher.service
  sleep 2
  systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher failed after safe profile'
  if [[ -x "$AUTOHEAL_INSTALL" ]]; then bash "$AUTOHEAL_INSTALL"; fi
  echo "Applied: dispatcher health interval=120s, lazy=true; autoheal=5m with randomized jitter."
}

refresh_node_health(){
  local role=$1 node secret
  node=$(role_node "$role")
  [[ -s "$D/controller.secret" ]] || return 0
  secret=$(<"$D/controller.secret")
  curl -sS --max-time 8 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:19090/proxies/$node/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000&expected=204" \
    >/dev/null 2>&1 || true
}

close_ssh_master(){
  local ip=$1
  ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true
}

remote_bootstrap(){
  local role=$1 ip=$2 uuid_file=$3 bundle=$4 domain='' email='' range=''
  scp "${SSH_OPTS[@]}" "$uuid_file" "root@$ip:/root/dual-live-uuid.txt"
  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    email=$(jq -r '.cert_email // empty' "$bundle")
    if [[ -z "$email" && -s "$STATE/trust-email" ]]; then email=$(<"$STATE/trust-email"); fi
    if [[ -z "$email" ]]; then
      read -r -p "Let's Encrypt email (one time): " email
      [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'invalid email'
      printf '%s\n' "$email" > "$STATE/trust-email"; chmod 0600 "$STATE/trust-email"
    fi
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$ip" || {
      echo
      printf '%bDNS is not pointing %s to %s yet.%b\n' "$Y" "$domain" "$ip" "$N"
      echo 'Change the A record, wait for it to resolve, then run Replace Trust again.'
      return 3
    }
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$domain" "$email" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role trust --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  else
    range=$(jq -r '.port_range // "20000-20020"' "$bundle")
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$range" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; REPO=$3; BRANCH=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  fi
}

cleanup_old_foreign(){
  local role=$1 old=$2
  valid_ip "$old" || return 0
  echo "Trying role-only cleanup on old $role foreign $old (key-auth only; no blocking password prompt)..."
  if [[ "$role" == trust ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/trust /root/dual-trust-client.json' \
      >/dev/null 2>&1 || echo 'Old Trust VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'mita stop >/dev/null 2>&1 || true; systemctl disable --now dual-xudp-mieru.service mita.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-xudp-mieru.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/mieru /root/dual-mieru-client.json' \
      >/dev/null 2>&1 || echo 'Old Mieru VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  fi
}

replace_role(){
  local role=$1 bundle old new tag live_uuid uuid_file new_bundle auto_was=0 domain remote_path rc
  bundle=$(role_bundle "$role"); [[ -s "$bundle" ]] || die "$role bundle missing"
  old=$(jq -r '.public_ip // empty' "$bundle")
  tag=$(role_tag "$role")
  live_uuid=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
  [[ "$live_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'live XUDP UUID missing'
  echo "Current $role foreign: $old"
  read -r -p "New $role foreign IPv4: " new
  valid_ip "$new" || die 'invalid IPv4'
  [[ "$new" != "$old" ]] || die 'new IP equals current IP'

  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || {
      printf '%bBefore Trust replacement, point %s A record to %s.%b\n' "$Y" "$domain" "$new" "$N"
      return 0
    }
  fi

  echo "Connecting to new VPS. SSH will ask for its root password once; the session is reused for the migration."
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-FOREIGN-SSH=OK' || die 'cannot SSH to new foreign'
  uuid_file=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$uuid_file"; printf '%s\n' "$live_uuid" > "$uuid_file"
  if ! remote_bootstrap "$role" "$new" "$uuid_file" "$bundle"; then
    rm -f "$uuid_file"; close_ssh_master "$new"; return 1
  fi
  rm -f "$uuid_file"

  new_bundle=$(mktemp "/root/new-${role}-bundle.XXXXXX.json")
  if [[ "$role" == trust ]]; then remote_path=/root/dual-trust-client.json; else remote_path=/root/dual-mieru-client.json; fi
  if ! scp "${SSH_OPTS[@]}" "root@$new:$remote_path" "$new_bundle"; then
    rm -f "$new_bundle"; close_ssh_master "$new"; return 1
  fi
  close_ssh_master "$new"
  chmod 0600 "$new_bundle"
  [[ $(jq -r '.kind' "$new_bundle") == "$role" ]] || die 'downloaded bundle has wrong role'
  [[ $(jq -r '.public_ip' "$new_bundle") == "$new" ]] || die 'downloaded bundle has wrong IP'
  [[ $(jq -r '.xudp_uuid' "$new_bundle") == "$live_uuid" ]] || die 'new foreign UUID does not match live Iran UUID'

  systemctl is-active --quiet dual-tunnel-autoheal.timer 2>/dev/null && auto_was=1 || true
  systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
  set +e
  "$REPLACE" "$role" "$new_bundle"
  rc=$?
  set -e
  (( auto_was )) && systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
  (( rc == 0 )) || { echo "Cutover failed; old $role carrier was restored by rollback."; rm -f "$new_bundle"; return "$rc"; }

  refresh_node_health "$role"
  if "$HEALTH" --full "$role"; then
    printf '%b%s replacement PASSED full role health.%b\n' "$G" "${role^^}" "$N"
    cleanup_old_foreign "$role" "$old"
    echo 'New user connections are automatically eligible for load balancing now.'
  else
    printf '%b%s cutover is up but full post-check is degraded. Old foreign was NOT cleaned.%b\n' "$Y" "${role^^}" "$N"
  fi
  rm -f "$new_bundle"
}

restart_role(){
  local s
  case "$1" in trust) s=dual-trust-client.service;; mieru) s=dual-mieru-carrier.service;; esac
  systemctl restart "$s"; sleep 3; "$HEALTH" --quick "$1" || true
}

show_logs(){
  journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service \
    --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|closed pipe|reset|failed' | tail -n 120 || true
}

run_optimizer(){
  [[ -x "$OPTIMIZER" ]] || die 'dual optimizer is not installed; run dual-install-iran.sh upgrade first'
  "$OPTIMIZER"
}

need_root "$@"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'

case "${1:-}" in
  --apply-safe-profile) apply_safe_profile; exit 0 ;;
  --health) "$HEALTH" "${2:---quick}" "${3:-all}"; exit $? ;;
  --optimize) run_optimizer; exit $? ;;
esac

while true; do
  banner; endpoint_summary
  echo
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Trust foreign server'
  echo '  4) Replace Mieru foreign server'
  echo '  5) Restart Trust carrier only'
  echo '  6) Restart Mieru carrier only'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Re-apply low-noise health profile'
  echo '  9) Safe server optimizer / cleanup'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$HEALTH" --quick all || true ;;
    2) "$HEALTH" --full all || true ;;
    3) replace_role trust || true ;;
    4) replace_role mieru || true ;;
    5) restart_role trust ;;
    6) restart_role mieru ;;
    7) show_logs ;;
    8) apply_safe_profile ;;
    9) run_optimizer ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  echo; read -r -p 'Press Enter to continue...' _
done
, r'\1 sticky-sessions', s, count=1)
else:
    raise SystemExit('dispatcher strategy line missing')
open(p,'w').write(s)
PY
  chmod 0600 "$D/dispatcher.yaml"
  /usr/local/lib/dual-trust-mieru/mihomo -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null
  systemctl restart dual-dispatcher.service
  sleep 2
  systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher failed after safe profile'
  if [[ -x "$AUTOHEAL_INSTALL" ]]; then bash "$AUTOHEAL_INSTALL"; fi
  echo "Applied: dispatcher health interval=120s, lazy=true; autoheal=5m with randomized jitter."
}

refresh_node_health(){
  local role=$1 node secret
  node=$(role_node "$role")
  [[ -s "$D/controller.secret" ]] || return 0
  secret=$(<"$D/controller.secret")
  curl -sS --max-time 8 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:19090/proxies/$node/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000&expected=204" \
    >/dev/null 2>&1 || true
}

close_ssh_master(){
  local ip=$1
  ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true
}

remote_bootstrap(){
  local role=$1 ip=$2 uuid_file=$3 bundle=$4 domain='' email='' range=''
  scp "${SSH_OPTS[@]}" "$uuid_file" "root@$ip:/root/dual-live-uuid.txt"
  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    email=$(jq -r '.cert_email // empty' "$bundle")
    if [[ -z "$email" && -s "$STATE/trust-email" ]]; then email=$(<"$STATE/trust-email"); fi
    if [[ -z "$email" ]]; then
      read -r -p "Let's Encrypt email (one time): " email
      [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'invalid email'
      printf '%s\n' "$email" > "$STATE/trust-email"; chmod 0600 "$STATE/trust-email"
    fi
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$ip" || {
      echo
      printf '%bDNS is not pointing %s to %s yet.%b\n' "$Y" "$domain" "$ip" "$N"
      echo 'Change the A record, wait for it to resolve, then run Replace Trust again.'
      return 3
    }
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$domain" "$email" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role trust --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  else
    range=$(jq -r '.port_range // "20000-20020"' "$bundle")
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$range" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; REPO=$3; BRANCH=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  fi
}

cleanup_old_foreign(){
  local role=$1 old=$2
  valid_ip "$old" || return 0
  echo "Trying role-only cleanup on old $role foreign $old (key-auth only; no blocking password prompt)..."
  if [[ "$role" == trust ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/trust /root/dual-trust-client.json' \
      >/dev/null 2>&1 || echo 'Old Trust VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'mita stop >/dev/null 2>&1 || true; systemctl disable --now dual-xudp-mieru.service mita.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-xudp-mieru.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/mieru /root/dual-mieru-client.json' \
      >/dev/null 2>&1 || echo 'Old Mieru VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  fi
}

replace_role(){
  local role=$1 bundle old new tag live_uuid uuid_file new_bundle auto_was=0 domain remote_path rc
  bundle=$(role_bundle "$role"); [[ -s "$bundle" ]] || die "$role bundle missing"
  old=$(jq -r '.public_ip // empty' "$bundle")
  tag=$(role_tag "$role")
  live_uuid=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
  [[ "$live_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'live XUDP UUID missing'
  echo "Current $role foreign: $old"
  read -r -p "New $role foreign IPv4: " new
  valid_ip "$new" || die 'invalid IPv4'
  [[ "$new" != "$old" ]] || die 'new IP equals current IP'

  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || {
      printf '%bBefore Trust replacement, point %s A record to %s.%b\n' "$Y" "$domain" "$new" "$N"
      return 0
    }
  fi

  echo "Connecting to new VPS. SSH will ask for its root password once; the session is reused for the migration."
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-FOREIGN-SSH=OK' || die 'cannot SSH to new foreign'
  uuid_file=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$uuid_file"; printf '%s\n' "$live_uuid" > "$uuid_file"
  if ! remote_bootstrap "$role" "$new" "$uuid_file" "$bundle"; then
    rm -f "$uuid_file"; close_ssh_master "$new"; return 1
  fi
  rm -f "$uuid_file"

  new_bundle=$(mktemp "/root/new-${role}-bundle.XXXXXX.json")
  if [[ "$role" == trust ]]; then remote_path=/root/dual-trust-client.json; else remote_path=/root/dual-mieru-client.json; fi
  if ! scp "${SSH_OPTS[@]}" "root@$new:$remote_path" "$new_bundle"; then
    rm -f "$new_bundle"; close_ssh_master "$new"; return 1
  fi
  close_ssh_master "$new"
  chmod 0600 "$new_bundle"
  [[ $(jq -r '.kind' "$new_bundle") == "$role" ]] || die 'downloaded bundle has wrong role'
  [[ $(jq -r '.public_ip' "$new_bundle") == "$new" ]] || die 'downloaded bundle has wrong IP'
  [[ $(jq -r '.xudp_uuid' "$new_bundle") == "$live_uuid" ]] || die 'new foreign UUID does not match live Iran UUID'

  systemctl is-active --quiet dual-tunnel-autoheal.timer 2>/dev/null && auto_was=1 || true
  systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
  set +e
  "$REPLACE" "$role" "$new_bundle"
  rc=$?
  set -e
  (( auto_was )) && systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
  (( rc == 0 )) || { echo "Cutover failed; old $role carrier was restored by rollback."; rm -f "$new_bundle"; return "$rc"; }

  refresh_node_health "$role"
  if "$HEALTH" --full "$role"; then
    printf '%b%s replacement PASSED full role health.%b\n' "$G" "${role^^}" "$N"
    echo "Old $role foreign $old was NOT deleted automatically; keep it available for rollback."
    echo 'New user connections are automatically eligible for load balancing now.'
  else
    printf '%b%s cutover is up but full post-check is degraded. Old foreign was NOT cleaned.%b\n' "$Y" "${role^^}" "$N"
  fi
  rm -f "$new_bundle"
}

restart_role(){
  local s
  case "$1" in trust) s=dual-trust-client.service;; mieru) s=dual-mieru-carrier.service;; esac
  systemctl restart "$s"; sleep 3; "$HEALTH" --quick "$1" || true
}

show_logs(){
  journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service \
    -u lane3-naive-client.service -u lane3-xudp-router.service --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|closed pipe|reset|failed' | tail -n 120 || true
}

run_optimizer(){
  [[ -x "$OPTIMIZER" ]] || die 'dual optimizer is not installed; run dual-install-iran.sh upgrade first'
  "$OPTIMIZER"
}

need_root "$@"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'

case "${1:-}" in
  --apply-safe-profile) apply_safe_profile; exit 0 ;;
  --health) "$HEALTH" "${2:---quick}" "${3:-all}"; exit $? ;;
  --optimize) run_optimizer; exit $? ;;
esac

while true; do
  banner; endpoint_summary
  echo
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Trust foreign server'
  echo '  4) Replace Mieru foreign server'
  echo '  5) Restart Trust carrier only'
  echo '  6) Restart Mieru carrier only'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Re-apply low-noise health profile'
  echo '  9) Safe server optimizer / cleanup'
  echo ' 10) Manage Naive third carrier / unified pool'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$HEALTH" --quick all || true ;;
    2) "$HEALTH" --full all || true ;;
    3) replace_role trust || true ;;
    4) replace_role mieru || true ;;
    5) restart_role trust ;;
    6) restart_role mieru ;;
    7) show_logs ;;
    8) apply_safe_profile ;;
    9) run_optimizer ;;
    10) if [[ -x /usr/local/sbin/lane3-manager ]]; then /usr/local/sbin/lane3-manager; else echo 'Naive helper is not installed yet.'; fi ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  echo; read -r -p 'Press Enter to continue...' _
done
 "$D/dispatcher.yaml"; then np='ENABLED'; fi
  a=$(systemctl is-active dual-tunnel-autoheal.timer 2>/dev/null || true); [[ -n "$a" ]] || a=unknown
  d=$(systemctl is-active dual-dispatcher 2>/dev/null || true); [[ -n "$d" ]] || d=unknown
  x=$(systemctl is-active x-ui 2>/dev/null || true); [[ -n "$x" ]] || x=unknown
  printf '%b' "$R$B"
  printf '%-16s | %-24s\n' 'ROLE / SERVICE' 'STATUS / VALUE'
  printf '%-16s-+-%-24s\n' '----------------' '------------------------'
  printf '%-16s | %-24s\n' 'Trust IP' "$t"
  printf '%-16s | %-24s\n' 'Mieru IP' "$m"
  printf '%-16s | %-24s\n' 'Autoheal' "$a"
  printf '%-16s | %-24s\n' 'Dispatcher' "$d"
  printf '%-16s | %-24s\n' 'x-ui' "$x"
  printf '%b' "$N"
}

apply_safe_profile(){
  [[ -s "$D/dispatcher.yaml" ]] || die 'dispatcher config missing'
  cp -a "$D/dispatcher.yaml" "$D/dispatcher.yaml.before-safe-profile-$(date -u +%Y%m%dT%H%M%SZ)"
  python3 - "$D/dispatcher.yaml" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'(?m)^(\s*interval:)\s*\d+\s*$', r'\1 120', s, count=1)
s=re.sub(r'(?m)^(\s*lazy:)\s*(?:true|false)\s*$', r'\1 true', s, count=1)
s=re.sub(r'(?m)^(\s*max-failed-times:)\s*\d+\s*$', r'\1 2', s, count=1)
open(p,'w').write(s)
PY
  chmod 0600 "$D/dispatcher.yaml"
  /usr/local/lib/dual-trust-mieru/mihomo -t -d "$D/dispatcher-data" -f "$D/dispatcher.yaml" >/dev/null
  systemctl restart dual-dispatcher.service
  sleep 2
  systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher failed after safe profile'
  if [[ -x "$AUTOHEAL_INSTALL" ]]; then bash "$AUTOHEAL_INSTALL"; fi
  echo "Applied: dispatcher health interval=120s, lazy=true; autoheal=5m with randomized jitter."
}

refresh_node_health(){
  local role=$1 node secret
  node=$(role_node "$role")
  [[ -s "$D/controller.secret" ]] || return 0
  secret=$(<"$D/controller.secret")
  curl -sS --max-time 8 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:19090/proxies/$node/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000&expected=204" \
    >/dev/null 2>&1 || true
}

close_ssh_master(){
  local ip=$1
  ssh "${SSH_OPTS[@]}" -O exit "root@$ip" >/dev/null 2>&1 || true
}

remote_bootstrap(){
  local role=$1 ip=$2 uuid_file=$3 bundle=$4 domain='' email='' range=''
  scp "${SSH_OPTS[@]}" "$uuid_file" "root@$ip:/root/dual-live-uuid.txt"
  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    email=$(jq -r '.cert_email // empty' "$bundle")
    if [[ -z "$email" && -s "$STATE/trust-email" ]]; then email=$(<"$STATE/trust-email"); fi
    if [[ -z "$email" ]]; then
      read -r -p "Let's Encrypt email (one time): " email
      [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'invalid email'
      printf '%s\n' "$email" > "$STATE/trust-email"; chmod 0600 "$STATE/trust-email"
    fi
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$ip" || {
      echo
      printf '%bDNS is not pointing %s to %s yet.%b\n' "$Y" "$domain" "$ip" "$N"
      echo 'Change the A record, wait for it to resolve, then run Replace Trust again.'
      return 3
    }
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$domain" "$email" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; DOMAIN=$2; EMAIL=$3; REPO=$4; BRANCH=$5
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role trust --public-ip "$IP" --domain "$DOMAIN" --email "$EMAIL" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  else
    range=$(jq -r '.port_range // "20000-20020"' "$bundle")
    ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$ip" "$range" "$REPO_URL" "$BRANCH" <<'REMOTE'
set -Eeuo pipefail
IP=$1; RANGE=$2; REPO=$3; BRANCH=$4
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends git curl jq ca-certificates >/dev/null
rm -rf /opt/dual-frp-tunnel
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" --single-branch "$REPO" /opt/dual-frp-tunnel >/dev/null
cd /opt/dual-frp-tunnel/dual-trust-mieru
bash dual-install-foreign.sh --role mieru --public-ip "$IP" --port-range "$RANGE" --xudp-uuid-file /root/dual-live-uuid.txt --non-interactive
REMOTE
  fi
}

cleanup_old_foreign(){
  local role=$1 old=$2
  valid_ip "$old" || return 0
  echo "Trying role-only cleanup on old $role foreign $old (key-auth only; no blocking password prompt)..."
  if [[ "$role" == trust ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/trust /root/dual-trust-client.json' \
      >/dev/null 2>&1 || echo 'Old Trust VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$old" \
      'mita stop >/dev/null 2>&1 || true; systemctl disable --now dual-xudp-mieru.service mita.service >/dev/null 2>&1 || true; rm -f /etc/systemd/system/dual-xudp-mieru.service; systemctl daemon-reload; rm -rf /etc/dual-trust-mieru/mieru /root/dual-mieru-client.json' \
      >/dev/null 2>&1 || echo 'Old Mieru VPS could not be cleaned automatically; it is no longer referenced by Iran.'
  fi
}

replace_role(){
  local role=$1 bundle old new tag live_uuid uuid_file new_bundle auto_was=0 domain remote_path rc
  bundle=$(role_bundle "$role"); [[ -s "$bundle" ]] || die "$role bundle missing"
  old=$(jq -r '.public_ip // empty' "$bundle")
  tag=$(role_tag "$role")
  live_uuid=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
  [[ "$live_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'live XUDP UUID missing'
  echo "Current $role foreign: $old"
  read -r -p "New $role foreign IPv4: " new
  valid_ip "$new" || die 'invalid IPv4'
  [[ "$new" != "$old" ]] || die 'new IP equals current IP'

  if [[ "$role" == trust ]]; then
    domain=$(jq -r '.domain' "$bundle")
    mapfile -t dnsips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$new" || {
      printf '%bBefore Trust replacement, point %s A record to %s.%b\n' "$Y" "$domain" "$new" "$N"
      return 0
    }
  fi

  echo "Connecting to new VPS. SSH will ask for its root password once; the session is reused for the migration."
  ssh "${SSH_OPTS[@]}" "root@$new" 'echo NEW-FOREIGN-SSH=OK' || die 'cannot SSH to new foreign'
  uuid_file=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$uuid_file"; printf '%s\n' "$live_uuid" > "$uuid_file"
  if ! remote_bootstrap "$role" "$new" "$uuid_file" "$bundle"; then
    rm -f "$uuid_file"; close_ssh_master "$new"; return 1
  fi
  rm -f "$uuid_file"

  new_bundle=$(mktemp "/root/new-${role}-bundle.XXXXXX.json")
  if [[ "$role" == trust ]]; then remote_path=/root/dual-trust-client.json; else remote_path=/root/dual-mieru-client.json; fi
  if ! scp "${SSH_OPTS[@]}" "root@$new:$remote_path" "$new_bundle"; then
    rm -f "$new_bundle"; close_ssh_master "$new"; return 1
  fi
  close_ssh_master "$new"
  chmod 0600 "$new_bundle"
  [[ $(jq -r '.kind' "$new_bundle") == "$role" ]] || die 'downloaded bundle has wrong role'
  [[ $(jq -r '.public_ip' "$new_bundle") == "$new" ]] || die 'downloaded bundle has wrong IP'
  [[ $(jq -r '.xudp_uuid' "$new_bundle") == "$live_uuid" ]] || die 'new foreign UUID does not match live Iran UUID'

  systemctl is-active --quiet dual-tunnel-autoheal.timer 2>/dev/null && auto_was=1 || true
  systemctl stop dual-tunnel-autoheal.timer 2>/dev/null || true
  set +e
  "$REPLACE" "$role" "$new_bundle"
  rc=$?
  set -e
  (( auto_was )) && systemctl start dual-tunnel-autoheal.timer 2>/dev/null || true
  (( rc == 0 )) || { echo "Cutover failed; old $role carrier was restored by rollback."; rm -f "$new_bundle"; return "$rc"; }

  refresh_node_health "$role"
  if "$HEALTH" --full "$role"; then
    printf '%b%s replacement PASSED full role health.%b\n' "$G" "${role^^}" "$N"
    cleanup_old_foreign "$role" "$old"
    echo 'New user connections are automatically eligible for load balancing now.'
  else
    printf '%b%s cutover is up but full post-check is degraded. Old foreign was NOT cleaned.%b\n' "$Y" "${role^^}" "$N"
  fi
  rm -f "$new_bundle"
}

restart_role(){
  local s
  case "$1" in trust) s=dual-trust-client.service;; mieru) s=dual-mieru-carrier.service;; esac
  systemctl restart "$s"; sleep 3; "$HEALTH" --quick "$1" || true
}

show_logs(){
  journalctl -u dual-trust-client.service -u dual-mieru-carrier.service -u dual-xudp-bridge.service -u dual-dispatcher.service \
    --since '-30 min' --no-pager | grep -Ei 'error|warn|timeout|closed pipe|reset|failed' | tail -n 120 || true
}

run_optimizer(){
  [[ -x "$OPTIMIZER" ]] || die 'dual optimizer is not installed; run dual-install-iran.sh upgrade first'
  "$OPTIMIZER"
}

need_root "$@"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'

case "${1:-}" in
  --apply-safe-profile) apply_safe_profile; exit 0 ;;
  --health) "$HEALTH" "${2:---quick}" "${3:-all}"; exit $? ;;
  --optimize) run_optimizer; exit $? ;;
esac

while true; do
  banner; endpoint_summary
  echo
  echo '  1) Quick health check'
  echo '  2) Full health check (TCP + Telegram + UDP/XUDP)'
  echo '  3) Replace Trust foreign server'
  echo '  4) Replace Mieru foreign server'
  echo '  5) Restart Trust carrier only'
  echo '  6) Restart Mieru carrier only'
  echo '  7) Recent tunnel warnings/errors'
  echo '  8) Re-apply low-noise health profile'
  echo '  9) Safe server optimizer / cleanup'
  echo '  0) Exit'
  echo
  read -r -p 'Select: ' c
  echo
  case "$c" in
    1) "$HEALTH" --quick all || true ;;
    2) "$HEALTH" --full all || true ;;
    3) replace_role trust || true ;;
    4) replace_role mieru || true ;;
    5) restart_role trust ;;
    6) restart_role mieru ;;
    7) show_logs ;;
    8) apply_safe_profile ;;
    9) run_optimizer ;;
    0) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
  echo; read -r -p 'Press Enter to continue...' _
done
