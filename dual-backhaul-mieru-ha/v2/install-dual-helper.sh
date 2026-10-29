#!/usr/bin/env bash
# Install/upgrade Iran dual HA operational console. NEVER restarts Xray or any live tunnel.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo "Use sudo"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$HERE/dual.py" && -f "$HERE/foreign-install.sh" ]] || {
 echo "Run from the complete repository checkout; helper files are missing"; exit 2;
}
python3 -m py_compile "$HERE/dual.py"
bash -n "$HERE/foreign-install.sh"
TARGET=/opt/dual-ha/helper
BIN=/usr/local/bin/dual
if [[ -e "$BIN" && ! -L "$BIN" ]]; then
 echo "[x] Unrelated existing $BIN found; refusing to overwrite" >&2; exit 3
fi
if [[ -L "$BIN" && "$(readlink "$BIN")" != "$TARGET/dual.py" ]]; then
 echo "[x] $BIN points elsewhere; refusing overwrite" >&2; exit 3
fi
install -d -m 0755 "$TARGET"
install -m 0755 "$HERE/dual.py" "$TARGET/dual.py"
install -m 0755 "$HERE/foreign-install.sh" "$TARGET/foreign-install.sh"
ln -sfn "$TARGET/dual.py" "$BIN"
echo "[+] dual console installed: sudo dual"
echo "[+] noninteractive: sudo dual status | sudo dual health | sudo dual logs"
echo "[+] replace: sudo dual replace backhaul NEW_PUBLIC_IPV4"
echo "[+] replace: sudo dual replace mieru NEW_PUBLIC_IPV4"
echo "[+] Existing REALITY, x-ui, HAProxy and transport services were not modified."
