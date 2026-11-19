#!/usr/bin/env bash
# Run ONLY on a NEW dedicated foreign Backhaul2 VPS already installed in --prepare mode.
# Retains the original isolated Backhaul transport and changes ONLY its remote port.
set -Eeuo pipefail
[[ "$EUID" == 0 ]] || { echo 'Run as root' >&2; exit 2; }
[[ $# == 1 ]] || { echo "Usage: bash maya3-bh2-foreign-start.sh EXPECTED_FOREIGN_IP" >&2; exit 2; }
EXPECTED_IP="$1"
BUNDLE=/root/dual-ha-backhaul-bundle.env
CFG=/etc/dual-ha/backhaul-foreign.toml
[[ -r "$BUNDLE" && -r "$CFG" ]] || { echo 'Foreign bundle or Backhaul config missing' >&2; exit 3; }
if systemctl is-active --quiet dual-ha-backhaul-client; then
  echo 'Foreign Backhaul client already active: refusing to reconfigure' >&2; exit 3
fi
systemctl is-active --quiet danted || { echo 'Fresh Dante egress is not active' >&2; exit 3; }
python3 - "$BUNDLE" "$CFG" "$EXPECTED_IP" <<'PY'
from pathlib import Path
import ipaddress,re,sys
envfile,cfgfile,expected = map(Path,sys.argv[1:3]) if False else (Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3])
assert ipaddress.ip_address(expected).version == 4
bundle={}
for row in envfile.read_text().splitlines():
    m=re.fullmatch(r"([A-Z_]+)='([^']*)'", row)
    if m: bundle[m.group(1)]=m.group(2)
assert bundle['BH_IRAN_IP']=='185.215.230.221', 'Wrong Iran (Maya3 required)'
assert bundle['BH_FOREIGN_IP']==expected, 'Foreign IP mismatch'
assert bundle['BH_TLS_PORT']=='18443', 'Expected legacy installer bundle'
domain=bundle['BH_DOMAIN']
cfg=cfgfile.read_text()
old='remote_addr = "'+domain+':18443"'
new='remote_addr = "'+domain+':18445"'
assert cfg.count(old)==1, 'Unexpected existing remote_addr'
assert cfg.count('token = "'+bundle['BH_TOKEN']+'"')==1, 'Foreign token mismatch'
assert cfg.count('tls_server_name = "'+domain+'"')==1, 'Foreign TLS SNI mismatch'
assert cfg.count('ws_control_path = "'+bundle['BH_CONTROL_PATH']+'"')==1
assert cfg.count('ws_tunnel_path = "'+bundle['BH_TUNNEL_PATH']+'"')==1
tmp=cfgfile.with_suffix(".toml.new")
with tmp.open('x') as f: f.write(cfg.replace(old,new))
tmp.chmod(0o600)
tmp.replace(cfgfile)
print('VERIFIED: independent Backhaul2 remote TLS port 18445')
PY
systemctl enable --now dual-ha-backhaul-client
systemctl is-active --quiet dual-ha-backhaul-client
echo "Foreign Backhaul2 started: connects to Iran Maya3 TCP/18445."
echo "Now run the isolated SOCKS canary test on Maya3 :21102."
