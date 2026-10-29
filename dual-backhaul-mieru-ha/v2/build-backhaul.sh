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
# First try the pinned official Go archive via independent official mirrors.
# Some VPS networks receive an HTTP 404 from the redirect target at dl.google.com.
# Never silently accept a different toolchain or an unverified archive.
GO=""
GOFMT=""

# Ubuntu 24.04's signed APT repository ships exactly Go 1.23.1.
# Use it first to avoid blocked go.dev/dl and proxy.golang.org toolchain hosts.
if apt-cache show golang-1.23-go >/dev/null 2>&1; then
  echo "[i] Trying Ubuntu-signed Go 1.23.1 package (golang-1.23-go)..."
  if apt-get install -y golang-1.23-go; then
    CANDIDATE=/usr/lib/go-1.23/bin/go
    CANDIDATE_FMT=/usr/lib/go-1.23/bin/gofmt
    if [[ -x "$CANDIDATE" && -x "$CANDIDATE_FMT" ]] &&
        "$CANDIDATE" version | grep -q ' go1[.]23[.]1 '; then
      GO="$CANDIDATE"
      GOFMT="$CANDIDATE_FMT"
      export GOTOOLCHAIN=local
      export GOPROXY=https://proxy.golang.org,direct
      echo "[+] Verified Ubuntu Go toolchain: $("$GO" version)"
    else
      echo "[!] Ubuntu Go package is not exactly 1.23.1. Trying checksummed upstream archive." >&2
    fi
  fi
fi

# Only use official mirrors if the signed Ubuntu toolchain was unavailable.
if [[ -z "$GO" ]]; then
for url in \
  "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz" \
  "https://dl.google.com/go/go$GO_VERSION.linux-amd64.tar.gz" \
  "https://storage.googleapis.com/golang/go$GO_VERSION.linux-amd64.tar.gz"; do
  echo "[i] Fetching pinned Go $GO_VERSION from $url ..."
  if curl -fLSs --retry 2 --retry-delay 1 --connect-timeout 12 --max-time 180 \
     "$url" -o "$work/go.tar.gz"; then
    if echo "$GO_SHA256  $work/go.tar.gz" | sha256sum --check --status; then
      mkdir -p "$work/toolchain"
      tar -xzf "$work/go.tar.gz" -C "$work/toolchain"
      GO="$work/toolchain/go/bin/go"
      GOFMT="$work/toolchain/go/bin/gofmt"
      echo "[+] Official Go archive verified by SHA256."
      break
    else
      echo "[!] Downloaded Go archive did not match the pinned SHA256. Trying next official mirror." >&2
    fi
  else
    echo "[!] Official Go download failed; trying next mirror." >&2
  fi
  rm -f "$work/go.tar.gz"
done
fi

if [[ -z "$GO" ]]; then
  echo "[i] Official archives failed. Trying Go toolchain module via proxy.golang.org..."
  apt-get install -y golang-go
  SYSTEM_GO="$(command -v go || true)"
  [[ -n "$SYSTEM_GO" ]] || { echo "[x] golang-go did not install a Go binary"; exit 5; }
  export GOPROXY="https://proxy.golang.org"
  export GOSUMDB="sum.golang.org"
  export GOTOOLCHAIN="go$GO_VERSION+auto"
  "$SYSTEM_GO" version || {
    echo "[x] Official Go archives and verified Go toolchain module are unavailable." >&2
    echo "[x] No Backhaul service has been modified." >&2
    exit 5
  }
  GO="$SYSTEM_GO"
  GOFMT=""
else
  export GOTOOLCHAIN="local"
  export GOPROXY="https://proxy.golang.org,direct"
fi

echo "[i] Fetching pinned Backhaul source $UPSTREAM_COMMIT..."
if ! curl -fLSs --retry 2 --connect-timeout 12 --max-time 180 \
    "https://github.com/Musixal/Backhaul/archive/$UPSTREAM_COMMIT.tar.gz" \
    -o "$work/backhaul.tar.gz"; then
  echo "[!] GitHub archive unavailable, trying codeload..."
  curl -fLSs --retry 2 --connect-timeout 12 --max-time 180 \
    "https://codeload.github.com/Musixal/Backhaul/tar.gz/$UPSTREAM_COMMIT" \
    -o "$work/backhaul.tar.gz" || {
      echo "[x] Backhaul pinned source unavailable; no services changed." >&2
      exit 6
    }
fi
mkdir "$work/src"
tar -xzf "$work/backhaul.tar.gz" -C "$work/src" --strip-components=1
for f in apply_patch.py fix_wsmux_config.py fix_wss_alpn.py; do
 curl -fsSL --retry 4 "$RAW/$PATCH_REF/custom-backhaul/$f" -o "$work/$f"
 python3 "$work/$f" "$work/src"
done
cd "$work/src"
"$GO" get github.com/refraction-networking/utls@v1.6.7
if [[ -z "$GOFMT" ]]; then
  "$GO" fmt ./...
else
  "$GOFMT" -w config/config.go internal/server/server.go internal/client/client.go \
    internal/server/transport/wsmux.go internal/client/transport/wsmux.go \
    internal/utils/network/ws_dialer.go
fi
grep -F 'alpn.AlpnProtocols = []string{"http/1.1"}' internal/utils/network/ws_dialer.go
"$GO" test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GO" build -trimpath -ldflags='-s -w' -o "$work/backhaul" .
install -m 0755 "$work/backhaul" /opt/dual-ha/bin/backhaul
sha256sum /opt/dual-ha/bin/backhaul | tee /opt/dual-ha/backhaul-build.sha256
echo "Custom Backhaul V2 built in /opt/dual-ha/bin/backhaul. No running service modified."
