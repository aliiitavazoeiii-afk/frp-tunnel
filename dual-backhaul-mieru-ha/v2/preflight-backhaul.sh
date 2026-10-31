#!/usr/bin/env bash
# Read-only Backhaul reverse preflight on Iran or Foreign-1.
# No packages, firewall, systemd, Xray or certificate modifications.
set -Eeuo pipefail
ROLE="${1:-}"
DOMAIN="${2:-}"
IRAN_IP="${3:-94.184.4.38}"
FOREIGN_IP="${4:-152.237.230.159}"
if [[ "$ROLE" != "iran" && "$ROLE" != "foreign" ]]; then
  echo "Usage: bash preflight-backhaul.sh iran BACKHAUL_DOMAIN"
  echo "   or: bash preflight-backhaul.sh foreign"
  exit 2
fi
echo "=== Host identity / OS ==="
hostname
uname -m
ip -4 route get 1.1.1.1 2>/dev/null | head -n 1 || true
echo "=== Custom Backhaul binary ==="
if [[ -x /opt/dual-ha/bin/backhaul ]]; then
  sha256sum /opt/dual-ha/bin/backhaul
else
  echo "NOT INSTALLED: /opt/dual-ha/bin/backhaul"
fi
echo "=== Existing services (informational) ==="
for svc in x-ui dual-ha-mieru dual-ha-backhaul dual-ha-backhaul-router dual-ha-backhaul-tls dual-ha-backhaul-client danted haproxy; do
  printf '%s: ' "$svc"
  systemctl is-active "$svc" 2>/dev/null || true
done
echo "=== Port listeners ==="
for p in 22 80 443 18443 19080 19081 21001 11080; do
  printf ':%-5s ' "$p"
  result="$(ss -Hlnpt "( sport = :$p )" 2>/dev/null || true)"
  if [[ -n "$result" ]]; then
    printf '%s\n' "$result" | sed -E 's/pid=[0-9]+/pid=REDACTED/g'
  else
    echo "free"
  fi
done
if [[ "$ROLE" == "iran" ]]; then
  [[ -n "$DOMAIN" ]] || { echo "DOMAIN_REQUIRED: Please choose a dedicated DNS-only hostname pointing to Iran."; exit 2; }
  [[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]] || { echo "Invalid hostname"; exit 2; }
  echo "=== Public IP and direct DNS ==="
  echo "Expected Iran public IPv4: $IRAN_IP"
  echo "Expected Foreign-1 public IPv4: $FOREIGN_IP"
  DNS_IPS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  echo "$DOMAIN -> $DNS_IPS"
  if [[ "$DNS_IPS" != "$IRAN_IP" ]]; then
    echo "NOT READY: A record must point ONLY to Iran $IRAN_IP (DNS only, no proxy)."
  else
    echo "DNS_OK"
  fi
  if [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
    echo "Existing certificate:"
    openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -subject -enddate
    openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -checkhost "$DOMAIN"
  else
    echo "No existing Let's Encrypt certificate for this hostname."
    echo "TLS issuance needs domain A record and externally reachable TCP/80 on Iran."
  fi
  echo "Important: no configuration was modified, and public TCP/443 must remain Xray."
else
  echo "Foreign-1 should have 11080 free until its isolated loopback Dante SOCKS starts."
  echo "Reverse TLS carrier will connect to Iran $IRAN_IP:18443."
fi
