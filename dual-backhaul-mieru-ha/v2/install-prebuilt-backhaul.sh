#!/usr/bin/env bash
# Install CI-compiled pinned custom Backhaul V2; no compilation, no system service changes.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "amd64 only"; exit 1; }
if [[ $# -ne 1 ]]; then
  echo "Usage: sudo bash install-prebuilt-backhaul.sh dual-backhaul-v2-build-<12-hex-sha>" >&2
  exit 2
fi
TAG="$1"
[[ "$TAG" =~ ^dual-backhaul-v2-build-[0-9a-f]{12}$ ]] || {
  echo "Invalid release tag" >&2
  exit 2
}
for cmd in curl sha256sum python3; do
 command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 2; }
done
BASE="https://github.com/aliiitavazoeiii-afk/frp-tunnel/releases/download/$TAG"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "[i] Downloading pinned release $TAG..."
curl -fL --retry 2 --connect-timeout 12 --max-time 180 \
  "$BASE/backhaul-custom-v2-linux-amd64" \
  -o "$WORK/backhaul-custom-v2-linux-amd64"
curl -fL --retry 2 --connect-timeout 12 --max-time 35 \
  "$BASE/SHA256SUMS" \
  -o "$WORK/SHA256SUMS"

# Refuse arbitrary manifest contents; only the exact release executable is permitted.
python3 - "$WORK/SHA256SUMS" <<'PY'
import re,sys
manifest=open(sys.argv[1]).read()
if not re.fullmatch(r'[0-9a-f]{64}  backhaul-custom-v2-linux-amd64\n',manifest):
    raise SystemExit("Invalid SHA256SUMS manifest; refusing downloaded file.")
PY
(cd "$WORK" && sha256sum --check SHA256SUMS)
python3 - "$WORK/backhaul-custom-v2-linux-amd64" <<'PY'
import sys
h=open(sys.argv[1],"rb").read(20)
assert h[:4]==b'\x7fELF', "Not ELF"
assert h[4]==2, "Not 64-bit"
assert h[5]==1, "Not little-endian"
assert int.from_bytes(h[18:20],"little")==62, "Not x86_64"
PY

install -d -m 0755 /opt/dual-ha/bin
target=/opt/dual-ha/bin/backhaul
if [[ -e "$target" ]]; then
  if cmp -s "$WORK/backhaul-custom-v2-linux-amd64" "$target"; then
    echo "[+] Binary already installed and identical; no changes."
    exit 0
  fi
  echo "[x] Existing isolated Backhaul binary differs. Refusing to replace it." >&2
  echo "[x] Inspect manually before any upgrade. No running service modified." >&2
  exit 3
fi
install -m 0755 "$WORK/backhaul-custom-v2-linux-amd64" "$target"
sha256sum "$target" > /opt/dual-ha/backhaul-build.sha256
echo "$TAG" > /opt/dual-ha/backhaul-build-release.txt
echo "[+] CI-compiled custom Backhaul V2 installed at $target."
echo "[+] SHA256: $(sha256sum "$target" | awk '{print $1}')"
echo "[+] No systemd service, port, X-UI or Reality configurations modified."
