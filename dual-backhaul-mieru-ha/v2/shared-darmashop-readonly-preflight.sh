#!/usr/bin/env bash
# Read-only preflight beside Docker/DarmaShop. No side effects.
set -Eeuo pipefail
DOMAIN=''
if [ "$#" -gt 0 ]; then DOMAIN="$1"; fi
echo "=== DARMA SHOP / DOCKER READ-ONLY CHECK ==="
hostname
uname -m
ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true
echo '=== DOCKER ==='
if command -v docker >/dev/null 2>&1; then
  docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}' 2>/dev/null || true
fi
echo '=== SERVICES ==='
for s in docker caddy nginx apache2 x-ui dual-ha-backhaul dual-ha-mieru dual-ha-v2-gateway; do
  echo "$s: $(systemctl is-active "$s" 2>/dev/null || true)"
done
echo '=== PROTECTED WEB PORTS 80/443 ==='
for p in 80 443; do
  echo "TCP $p:"
  ss -H -lntp "( sport = :$p )" 2>/dev/null || true
done
echo '=== ISOLATED TUNNEL PORTS ==='
collision=0
for p in 18443 19080 19081 21001 21002 18080 28964; do
  if [ -n "$(ss -H -lnt "( sport = :$p )" 2>/dev/null || true)" ]; then
    echo "TCP $p: OCCUPIED"
    collision=1
  else
    echo "TCP $p: FREE"
  fi
done
echo '=== EXISTING TUNNEL FILES ==='
for f in /etc/dual-ha/backhaul-bundle.env /etc/dual-ha/mieru.json /etc/systemd/system/dual-ha-backhaul.service /etc/systemd/system/dual-ha-mieru.service /etc/systemd/system/dual-ha-v2-gateway.service; do
  if [ -e "$f" ]; then echo "ALREADY EXISTS: $f"; collision=1; fi
done
echo '=== CERTIFICATE / DNS ==='
cert_ready=0
if [ -n "$DOMAIN" ]; then
  echo "DOMAIN: $DOMAIN"
  getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true
  if [ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ] && openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 && openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -checkend 604800 >/dev/null 2>&1; then
    cert_ready=1
    echo 'CERT: VALID'
  else
    echo 'CERT: ABSENT/INVALID'
  fi
else
  echo 'DOMAIN: NOT SUPPLIED'
fi
echo '=== VERDICT ==='
if [ "$collision" = 1 ]; then
  echo 'STOP: Existing tunnel port or config conflict. Do not install.'
elif [ "$cert_ready" = 0 ]; then
  echo 'TUNNEL PORTS FREE; CERT PENDING. Never run certbot standalone on Docker TCP/80.'
else
  echo 'TUNNEL PORTS FREE; CERT PRESENT. Foreign VPS and firewall checks still required.'
fi
echo 'NO CHANGES WERE MADE TO THE HOST.'
