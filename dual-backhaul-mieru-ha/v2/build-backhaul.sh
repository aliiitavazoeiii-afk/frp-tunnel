#!/usr/bin/env bash
# Rebuild exact Backhaul v0.7.2-derived Custom V2 from pinned source/patches.
# Does not overwrite the system Backhaul binary or restart any service.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "amd64 required"; exit 1; }
install -d -m 0755 /opt/dual-ha/bin
if [[ -x /opt/dual-ha/bin/backhaul ]] && [[ "$#" -eq 0 ]]; then
 echo "Isolated Backhaul already installed; re-build needs --rebuild."
 exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git tar python3 openssl
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
GO_VERSION=1.23.1
GO_SHA256=49bbb517cfa9eee677e1e7897f7cf9cfdbcf49e05f61984a2789136de359f9bd
UPSTREAM_COMMIT=df7966f8f725837a680ea7b90bd37ea52666c277
PATCH_REF=e9111c6d78a922972482e3de720d1f82dca062d8
RAW=https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer
curl -fL --retry 4 "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz" -o "$work/go.tar.gz"
echo "$GO_SHA256  $work/go.tar.gz" | sha256sum -c -
mkdir "$work/toolchain"
tar -xzf "$work/go.tar.gz" -C "$work/toolchain"
GO="$work/toolchain/go/bin/go"
GOFMT="$work/toolchain/go/bin/gofmt"
curl -fL --retry 4 "https://github.com/Musixal/Backhaul/archive/$UPSTREAM_COMMIT.tar.gz" -o "$work/backhaul.tar.gz"
mkdir "$work/src"
tar -xzf "$work/backhaul.tar.gz" -C "$work/src" --strip-components=1
for f in apply_patch.py fix_wsmux_config.py fix_wss_alpn.py; do
 curl -fsSL --retry 4 "$RAW/$PATCH_REF/custom-backhaul/$f" -o "$work/$f"
 python3 "$work/$f" "$work/src"
done
cd "$work/src"
export GOPROXY=https://proxy.golang.org,direct
export GOTOOLCHAIN=local
"$GO" get github.com/refraction-networking/utls@v1.6.7
"$GOFMT" -w config/config.go internal/server/server.go internal/client/client.go \
  internal/server/transport/wsmux.go internal/client/transport/wsmux.go \
  internal/utils/network/ws_dialer.go
grep -F 'alpn.AlpnProtocols = []string{"http/1.1"}' internal/utils/network/ws_dialer.go
"$GO" test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GO" build -trimpath -ldflags='-s -w' -o "$work/backhaul" .
install -m 0755 "$work/backhaul" /opt/dual-ha/bin/backhaul
sha256sum /opt/dual-ha/bin/backhaul | tee /opt/dual-ha/backhaul-build.sha256
echo "Custom Backhaul V2 built in /opt/dual-ha/bin/backhaul. No running service modified."
