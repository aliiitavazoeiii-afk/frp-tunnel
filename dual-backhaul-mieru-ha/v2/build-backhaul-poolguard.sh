#!/usr/bin/env bash
# Build a SEPARATE non-running custom Backhaul client poolguard binary.
# No systemd restarts, no live file overwrite, no anti-DPI config changes.
set -Eeuo pipefail
umask 077
[[ "$EUID" == 0 ]] || { echo "Root required"; exit 2; }
[[ $# == 1 && "$1" =~ ^[a-f0-9]{40}$ ]] || {
 echo "Usage: sudo bash $0 EXACT_40_HEX_COMMIT_SHA"; exit 2;
}
REF="$1"
[[ -x /opt/dual-ha/bin/backhaul ]] || {
 echo "STOP: existing Backhaul binary not found"; exit 3;
}
systemctl is-active --quiet dual-ha-backhaul-client || {
 echo "STOP: foreign Backhaul client must already be active"; exit 3;
}
[[ "$(uname -m)" == "x86_64" ]] || { echo "STOP: expected amd64"; exit 3; }
for bin in curl tar python3 sha256sum; do command -v "$bin" >/dev/null || {
 echo "STOP: missing $bin; no packages installed"; exit 3; }
done
ROOT="$(mktemp -d /root/.dual-poolguard.XXXXXXXX)"
cleanup(){ rm -rf "$ROOT"; }
trap cleanup EXIT
mkdir -p "$ROOT/src" "$ROOT/go"
GO_BIN=""
if command -v go >/dev/null 2>&1; then
 GO_BIN="$(command -v go)"
elif [[ -x /usr/lib/go-1.23/bin/go ]]; then
 GO_BIN=/usr/lib/go-1.23/bin/go
elif [[ -x /usr/local/go/bin/go ]]; then
 GO_BIN=/usr/local/go/bin/go
else
 echo "Using checksum-verified isolated Go 1.23.1 toolchain (no apt changes)"
 URL="https://go.dev/dl/go1.23.1.linux-amd64.tar.gz"
 SHA="49bbb517cfa9eee677e1e7897f7cf9cfdbcf49e05f61984a2789136de359f9bd"
 curl -fLSs --retry 2 --connect-timeout 10 --max-time 180 "$URL" -o "$ROOT/go.tar.gz"
 echo "$SHA  $ROOT/go.tar.gz" | sha256sum -c --status || {
   echo "STOP: Go archive sha256 mismatch"; exit 3;
 }
 tar -xzf "$ROOT/go.tar.gz" -C "$ROOT/go"
 GO_BIN="$ROOT/go/go/bin/go"
fi
"$GO_BIN" version | grep -Eq ' go1\.(2[3-9]|[3-9][0-9])\.' || {
 echo "STOP: need Go >= 1.23; system toolchain not changed"; exit 3;
}
UPSTREAM="df7966f8f725837a680ea7b90bd37ea52666c277"
PATCH_REF="e9111c6d78a922972482e3de720d1f82dca062d8"
RAW="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/$PATCH_REF/custom-backhaul"
BROOT="https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/dual-backhaul-mieru-ha/v2"
curl -fLSs --retry 2 --connect-timeout 10 --max-time 180 \
 "https://codeload.github.com/Musixal/Backhaul/tar.gz/$UPSTREAM" \
 -o "$ROOT/src.tar.gz"
tar -xzf "$ROOT/src.tar.gz" -C "$ROOT/src" --strip-components=1
for patch in apply_patch.py fix_wsmux_config.py fix_wss_alpn.py; do
 curl -fsSLo "$ROOT/$patch" "$RAW/$patch"
 python3 "$ROOT/$patch" "$ROOT/src"
done
curl -fsSLo "$ROOT/client-pool-guard.py" "$BROOT/client-pool-guard.py"
python3 "$ROOT/client-pool-guard.py" "$ROOT/src"
export GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org,direct GOSUMDB=sum.golang.org
cd "$ROOT/src"
"$GO_BIN" get github.com/refraction-networking/utls@v1.6.7
if command -v gofmt >/dev/null 2>&1; then
  gofmt -w internal/client/transport/wsmux.go
elif [[ -x "$(dirname "$GO_BIN")/gofmt" ]]; then
  "$(dirname "$GO_BIN")/gofmt" -w internal/client/transport/wsmux.go
fi
"$GO_BIN" test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GO_BIN" \
 build -trimpath -ldflags='-s -w' -o "$ROOT/backhaul-poolguard" .
test -s "$ROOT/backhaul-poolguard"
test ! -e /opt/dual-ha/bin/backhaul-poolguard-v1 || {
 echo "STOP: candidate already exists; no overwrite permitted"; exit 3;
}
install -m 0755 "$ROOT/backhaul-poolguard" /opt/dual-ha/bin/backhaul-poolguard-v1
echo "POOLGUARD_CANDIDATE_BUILT (not activated)"
echo "Previous running Backhaul binary has not been replaced."
echo "Candidate SHA256:"
sha256sum /opt/dual-ha/bin/backhaul-poolguard-v1
echo "Running foreign service untouched. No changes to anti-DPI settings."
