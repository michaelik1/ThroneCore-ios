#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${DEST:-$ROOT/deployment/ios}
IOS_VERSION=${IOS_VERSION:-15.0}
IOS_TARGETS=${IOS_TARGETS:-ios/arm64,iossimulator/arm64,iossimulator/amd64}
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_openvpn,with_openconnect,with_naive_outbound,badlinkname,tfogo_checklinkname0"

if [[ $(uname -s) != Darwin ]]; then
  echo "iOS builds require macOS and Xcode (including the iOS SDK)." >&2
  exit 1
fi
xcrun --sdk iphoneos --show-sdk-path >/dev/null
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)

cd "$ROOT/core"
# Use the fork pinned by the core, rather than whichever gomobile is on PATH.
export GOBIN=${MOBILE_TOOLS_DIR:-$ROOT/build/mobile-tools}
mkdir -p "$GOBIN"
export PATH="$GOBIN:$PATH"
GOMOBILE_VERSION=$(go list -mod=readonly -m -f '{{.Version}}' github.com/sagernet/gomobile)
go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"
VERSION_SINGBOX=$(go list -mod=readonly -m -f '{{.Version}}' github.com/sagernet/sing-box)

gomobile bind -v -o "$DEST/ThroneCore.xcframework" \
  -target "$IOS_TARGETS" -iosversion "$IOS_VERSION" -trimpath \
  -ldflags "-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=${VERSION_SINGBOX} -X runtime.godebugDefault=multipathtcp=0" \
  -tags "$TAGS" ./mobile

{
  git -C "$ROOT" rev-parse HEAD
  go version
  xcodebuild -version
  echo "gomobile $GOMOBILE_VERSION"
  echo "targets $IOS_TARGETS"
  echo "minimum iOS $IOS_VERSION"
  echo "tags $TAGS"
  go list -mod=readonly -m github.com/sagernet/sing-box github.com/xtls/xray-core github.com/sagernet/sing-tun
} > "$DEST/build-info.txt"
