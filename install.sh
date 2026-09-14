#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="anytls-tunnel"
MIHOMO_VERSION="v1.19.30"
CONFIG_DIR="/etc/${PROJECT_NAME}"
STATE_DIR="/var/lib/${PROJECT_NAME}"
BIN_DIR="/usr/local/lib/${PROJECT_NAME}"
BIN_LINK="/usr/local/bin/mihomo-${PROJECT_NAME}"
UNIT_PATH="/etc/systemd/system/${PROJECT_NAME}.service"
SERVICE_USER="anytls-tunnel"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

usage(){
  cat <<'USAGE'
Usage:
  sudo ./install.sh foreign-a /path/to/deploy.env
  sudo ./install.sh foreign-b /path/to/deploy.env
  sudo ./install.sh iran      /path/to/deploy.env
USAGE
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ $# -eq 2 ]] || { usage; exit 2; }
ROLE=$1
ENV_FILE=$2
[[ "$ROLE" == "foreign-a" || "$ROLE" == "foreign-b" || "$ROLE" == "iran" ]] || die "invalid role: $ROLE"
[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"

require_var(){ local n=$1; [[ -n "${!n:-}" ]] || die "missing $n in env file"; }
require_secret(){ local n=$1 v; require_var "$n"; v=${!n}; [[ ${#v} -ge 24 ]] || die "$n is too short"; }
valid_atom(){ [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]; }
valid_host(){ [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" != *:* ]]; }
valid_uuid(){ [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-8][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; }
valid_short_id(){ [[ "$1" =~ ^([0-9A-Fa-f]{2}){1,8}$ ]]; }
valid_reality_key(){ [[ "$1" =~ ^[A-Za-z0-9_-]{40,64}$ ]]; }

if [[ "$ROLE" == "foreign-a" ]]; then
  require_var COVER_HOST_A; require_secret ANYTLS_PASS_A; require_secret SHADOWTLS_PASS_A
  valid_host "$COVER_HOST_A" || die "invalid COVER_HOST_A"
elif [[ "$ROLE" == "foreign-b" ]]; then
  require_var COVER_HOST_B; require_secret ANYTLS_PASS_B; require_secret RESTLS_PASS_B
  valid_host "$COVER_HOST_B" || die "invalid COVER_HOST_B"
else
  for n in NODE_A_ADDR NODE_B_ADDR COVER_HOST_A COVER_HOST_B LOCAL_MIXED_PORT LOCAL_CONTROLLER_PORT USER_LISTEN_PORT VLESS_UUID VLESS_REALITY_SNI REALITY_PRIVATE_KEY REALITY_SHORT_ID QUIC_SAFE_MODE; do require_var "$n"; done
  for n in ANYTLS_PASS_A SHADOWTLS_PASS_A ANYTLS_PASS_B RESTLS_PASS_B CONTROLLER_SECRET; do require_secret "$n"; done
  valid_atom "$NODE_A_ADDR" || die "invalid NODE_A_ADDR"
  valid_atom "$NODE_B_ADDR" || die "invalid NODE_B_ADDR"
  valid_host "$COVER_HOST_A" || die "invalid COVER_HOST_A"
  valid_host "$COVER_HOST_B" || die "invalid COVER_HOST_B"
  valid_host "$VLESS_REALITY_SNI" || die "invalid VLESS_REALITY_SNI"
  valid_uuid "$VLESS_UUID" || die "invalid VLESS_UUID"
  valid_short_id "$REALITY_SHORT_ID" || die "REALITY_SHORT_ID must be 2-16 hex characters with even length"
  valid_reality_key "$REALITY_PRIVATE_KEY" || die "REALITY_PRIVATE_KEY format looks invalid"
  [[ "$QUIC_SAFE_MODE" == "true" || "$QUIC_SAFE_MODE" == "false" ]] || die "QUIC_SAFE_MODE must be true or false"
  [[ "$LOCAL_MIXED_PORT" =~ ^[0-9]+$ && "$LOCAL_CONTROLLER_PORT" =~ ^[0-9]+$ && "$USER_LISTEN_PORT" =~ ^[0-9]+$ ]] || die "ports must be numeric"
  (( 1 <= 10#$USER_LISTEN_PORT && 10#$USER_LISTEN_PORT <= 65535 )) || die "invalid USER_LISTEN_PORT"
fi

install_packages(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gzip openssl iproute2 jq procps util-linux
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl gzip openssl iproute jq procps-ng util-linux
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl gzip openssl iproute jq procps-ng util-linux
  else
    die "supported package manager not found (apt/dnf/yum)"
  fi
}

select_asset(){
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      if grep -qw avx2 /proc/cpuinfo 2>/dev/null && grep -qw bmi2 /proc/cpuinfo 2>/dev/null; then
        ASSET="mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
        SHA256="cf06ce2c7d1421bdbda14ee4a5b6046672dc35ebf8eecd8e77504ec3c0ed9a84"
      else
        ASSET="mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz"
        SHA256="db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9"
      fi
      ;;
    aarch64|arm64)
      ASSET="mihomo-linux-arm64-${MIHOMO_VERSION}.gz"
      SHA256="58896873736d28628f66de3677c8654fa0f180662523148e136cff4f6e890069"
      ;;
    *) die "unsupported architecture: $arch" ;;
  esac
}

install_binary(){
  select_asset
  mkdir -p "$BIN_DIR"
  local target="$BIN_DIR/mihomo-${MIHOMO_VERSION}"
  if [[ -x "$target" ]]; then
    log "Pinned mihomo ${MIHOMO_VERSION} already installed"
  else
    local tmp gz url
    tmp=$(mktemp)
    gz=$(mktemp)
    url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${ASSET}"
    log "Downloading pinned ${ASSET}"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 180 -o "$gz" "$url"
    echo "${SHA256}  ${gz}" | sha256sum -c - >/dev/null || die "mihomo SHA256 mismatch"
    gzip -dc "$gz" > "$tmp"
    chmod 0755 "$tmp"
    "$tmp" -v >/dev/null || die "downloaded mihomo binary cannot execute"
    install -m 0755 "$tmp" "$target"
    rm -f "$tmp" "$gz"
  fi
  ln -sfn "$target" "$BIN_LINK"
  "$BIN_LINK" -v
}

create_user(){
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    local nologin_shell; nologin_shell=$(command -v nologin || true); [[ -n "$nologin_shell" ]] || nologin_shell=/sbin/nologin
    useradd --system --no-create-home --home-dir "$CONFIG_DIR" --shell "$nologin_shell" "$SERVICE_USER"
  fi
  mkdir -p "$CONFIG_DIR" "$STATE_DIR/backups"
  chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR"
  chmod 0750 "$CONFIG_DIR"
  chmod 0700 "$STATE_DIR" "$STATE_DIR/backups"
}

backup_current(){
  local ts b
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  b="$STATE_DIR/backups/$ts"
  mkdir -p "$b"
  [[ -f "$CONFIG_DIR/config.yaml" ]] && cp -a "$CONFIG_DIR/config.yaml" "$b/config.yaml"
  [[ -f "$UNIT_PATH" ]] && cp -a "$UNIT_PATH" "$b/anytls-tunnel.service"
  [[ -f /etc/sysctl.d/99-anytls-tunnel.conf ]] && cp -a /etc/sysctl.d/99-anytls-tunnel.conf "$b/sysctl.conf"
  printf '%s\n' "$ROLE" > "$b/role"
  echo "$b"
}

check_cover(){
  local host=$1
  log "Preflight TLS 1.3 cover check: $host"
  getent ahosts "$host" >/dev/null || die "cover host does not resolve: $host"
  curl -sS --noproxy '*' --tlsv1.3 --tls-max 1.3 --connect-timeout 6 --max-time 15 -o /dev/null "https://${host}/" \
    || die "cover host failed a validated TLS 1.3 HTTPS connection: $host"
}

port_in_use(){
  local p=$1
  ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .
}

preflight_ports(){
  local p
  if [[ "$ROLE" == foreign-* ]]; then
    p=443
    if port_in_use "$p" && ! systemctl is-active --quiet "$PROJECT_NAME" 2>/dev/null; then
      ss -ltnp "sport = :$p" || true
      die "TCP/$p is already in use by another service"
    fi
  else
    for p in "$USER_LISTEN_PORT" "$LOCAL_MIXED_PORT" "$LOCAL_CONTROLLER_PORT"; do
      if port_in_use "$p" && ! systemctl is-active --quiet "$PROJECT_NAME" 2>/dev/null; then
        ss -ltnp "sport = :$p" || true
        die "TCP/$p is already in use by another service"
      fi
    done
  fi
}

write_config(){
  local out="$CONFIG_DIR/config.yaml.new"
  umask 077
  if [[ "$ROLE" == "foreign-a" ]]; then
    cat > "$out" <<YAML
mode: rule
log-level: info
ipv6: false

listeners:
  - name: anytls-shadowtls-v3
    type: anytls
    listen: 0.0.0.0
    port: 443
    users:
      tunnel: "${ANYTLS_PASS_A}"
    shadow-tls:
      enable: true
      version: 3
      users:
        - name: tunnel
          password: "${SHADOWTLS_PASS_A}"
      handshake:
        dest: "${COVER_HOST_A}:443"

rules:
  - MATCH,DIRECT
YAML
  elif [[ "$ROLE" == "foreign-b" ]]; then
    cat > "$out" <<YAML
mode: rule
log-level: info
ipv6: false

listeners:
  - name: anytls-restls
    type: anytls
    listen: 0.0.0.0
    port: 443
    users:
      tunnel: "${ANYTLS_PASS_B}"
    res-tls:
      enable: true
      dest: "${COVER_HOST_B}:443"
      password: "${RESTLS_PASS_B}"

rules:
  - MATCH,DIRECT
YAML
  else
    local quic_rule=""
    if [[ "$QUIC_SAFE_MODE" == "true" ]]; then
      quic_rule='  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT'
    fi
    cat > "$out" <<YAML
mixed-port: ${LOCAL_MIXED_PORT}
bind-address: 127.0.0.1
allow-lan: false
mode: rule
log-level: info
ipv6: false
external-controller: "127.0.0.1:${LOCAL_CONTROLLER_PORT}"
secret: "${CONTROLLER_SECRET}"

listeners:
  - name: user-vless-reality
    type: vless
    listen: 0.0.0.0
    port: ${USER_LISTEN_PORT}
    udp: true
    users:
      - username: user
        uuid: "${VLESS_UUID}"
    reality-config:
      dest: "${VLESS_REALITY_SNI}:443"
      private-key: "${REALITY_PRIVATE_KEY}"
      short-id:
        - "${REALITY_SHORT_ID}"
      server-names:
        - "${VLESS_REALITY_SNI}"

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
${quic_rule}
  - MATCH,TUNNEL
YAML
  fi
  chown "$SERVICE_USER:$SERVICE_USER" "$out"
  chmod 0600 "$out"
  log "Validating candidate Mihomo configuration"
  runuser -u "$SERVICE_USER" -- "$BIN_LINK" -t -d "$CONFIG_DIR" -f "$out" \
    || { rm -f "$out"; die "candidate configuration failed mihomo -t; nothing was activated"; }
  mv -f "$out" "$CONFIG_DIR/config.yaml"
  chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR/config.yaml"
  chmod 0600 "$CONFIG_DIR/config.yaml"
}

write_unit(){
  local tmp="/run/anytls-tunnel-verify.service"
  rm -f "$tmp"
  cat > "$tmp" <<UNIT
[Unit]
Description=AnyTLS Tunnel (${ROLE})
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=10

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${CONFIG_DIR}
Environment=HOME=${CONFIG_DIR}
ExecStartPre=${BIN_LINK} -t -d ${CONFIG_DIR} -f ${CONFIG_DIR}/config.yaml
ExecStart=${BIN_LINK} -d ${CONFIG_DIR} -f ${CONFIG_DIR}/config.yaml
Restart=always
RestartSec=2s
TimeoutStopSec=10s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${CONFIG_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$tmp" >/dev/null || { rm -f "$tmp"; die "systemd unit verification failed"; }
  fi
  install -m 0644 "$tmp" "$UNIT_PATH"
  rm -f "$tmp"
}

write_role_file(){
  install -m 0600 "$ENV_FILE" "$CONFIG_DIR/deploy.env"
  chown root:root "$CONFIG_DIR/deploy.env"
  printf '%s\n' "$ROLE" > "$CONFIG_DIR/role"
  chmod 0644 "$CONFIG_DIR/role"
}

apply_safe_network_tuning(){
  local cc_line=""
  modprobe tcp_bbr 2>/dev/null || true
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr; then
    cc_line=$'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr'
  else
    log "BBR unavailable on this kernel; leaving congestion control unchanged"
  fi
  cat > /etc/sysctl.d/99-anytls-tunnel.conf <<SYSCTL
# Conservative tuning for anytls-tunnel; no aggressive buffer overrides.
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=4
${cc_line}
SYSCTL
  sysctl --system >/dev/null || log "WARNING: one or more sysctl values could not be applied"
}

open_firewall_port(){
  local public_port=443
  [[ "$ROLE" == "iran" ]] && public_port="$USER_LISTEN_PORT"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${public_port}/tcp" comment 'anytls-tunnel' >/dev/null
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${public_port}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
}

install_helpers(){
  install -m 0755 "$(dirname "$0")/scripts/status.sh" /usr/local/sbin/anytls-tunnel-status
  install -m 0755 "$(dirname "$0")/scripts/health.sh" /usr/local/sbin/anytls-tunnel-health
  install -m 0755 "$(dirname "$0")/scripts/probe-test.sh" /usr/local/sbin/anytls-tunnel-probe-test
  install -m 0755 "$(dirname "$0")/scripts/rollback.sh" /usr/local/sbin/anytls-tunnel-rollback
}

restore_previous_after_failed_start(){
  local reason=$1
  log "ERROR: $reason"
  journalctl -u "$PROJECT_NAME" -n 80 --no-pager >&2 || true
  if [[ -n "${BACKUP_DIR:-}" && -f "$BACKUP_DIR/config.yaml" ]]; then
    log "Attempting automatic rollback to $BACKUP_DIR"
    cp -a "$BACKUP_DIR/config.yaml" "$CONFIG_DIR/config.yaml"
    chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR/config.yaml"
    if [[ -f "$BACKUP_DIR/anytls-tunnel.service" ]]; then
      cp -a "$BACKUP_DIR/anytls-tunnel.service" "$UNIT_PATH"
    fi
    if [[ -f "$BACKUP_DIR/sysctl.conf" ]]; then
      cp -a "$BACKUP_DIR/sysctl.conf" /etc/sysctl.d/99-anytls-tunnel.conf
      sysctl --system >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload
    if systemctl restart "$PROJECT_NAME" && systemctl is-active --quiet "$PROJECT_NAME"; then
      die "new deployment failed and the previous service was restored successfully"
    fi
    die "new deployment failed; automatic rollback was attempted but the previous service also failed"
  fi
  die "initial deployment failed; there was no previous service to roll back to"
}

start_and_verify(){
  systemctl daemon-reload
  systemctl enable "$PROJECT_NAME" >/dev/null
  if ! systemctl restart "$PROJECT_NAME"; then
    restore_previous_after_failed_start "service failed to start"
  fi
  sleep 2
  systemctl is-active --quiet "$PROJECT_NAME" || restore_previous_after_failed_start "service is not active after restart"
  if [[ "$ROLE" == foreign-* ]]; then
    ss -H -ltn "sport = :443" | grep -q . || restore_previous_after_failed_start "service active but TCP/443 is not listening"
  else
    ss -H -ltn "sport = :${USER_LISTEN_PORT}" | grep -q . || restore_previous_after_failed_start "service active but VLESS user port is not listening"
    ss -H -ltn "sport = :${LOCAL_MIXED_PORT}" | grep -q . || restore_previous_after_failed_start "service active but local mixed port is not listening"
    ss -H -ltn "sport = :${LOCAL_CONTROLLER_PORT}" | grep -q . || restore_previous_after_failed_start "service active but controller port is not listening"
  fi
}

log "Installing dependencies"
install_packages
log "Installing pinned Mihomo"
install_binary
create_user
preflight_ports
if [[ "$ROLE" == "foreign-a" ]]; then check_cover "$COVER_HOST_A"; fi
if [[ "$ROLE" == "foreign-b" ]]; then check_cover "$COVER_HOST_B"; fi
BACKUP_DIR=$(backup_current)
log "Backup snapshot: $BACKUP_DIR"
write_config
write_unit
write_role_file
apply_safe_network_tuning
open_firewall_port
install_helpers
start_and_verify
log "SUCCESS: ${PROJECT_NAME} role=${ROLE} is active"
if [[ "$ROLE" == "iran" ]]; then
  log "VLESS/REALITY user listener is active on TCP/${USER_LISTEN_PORT}"
  log "Run: sudo anytls-tunnel-health"
  log "Run: sudo anytls-tunnel-probe-test"
else
  log "Ensure provider/security-group firewall also allows TCP/443."
fi
