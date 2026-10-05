#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/deployment/ios-trollstore"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/ios-trollstore}"
BUNDLE_ID="${THRONE_APP_BUNDLE_IDENTIFIER:-org.thronecore.example}"
fail() { echo "TrollStore package: $*" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || fail "requires macOS and Xcode"
for tool in xcodebuild xcrun codesign python3 ditto; do
  command -v "$tool" >/dev/null || fail "missing $tool"
done
[[ -f "$ROOT/deployment/ios/ThroneCore.xcframework/Info.plist" ]] || fail "build or restore the full XCFramework first"
mkdir -p "$OUT"
# This path is only for an existing, supported TrollStore installation. No Apple
# account, certificate, provisioning profile, or private entitlement is used.
xcodebuild build \
  -project "$ROOT/apple/Example/ThroneCoreExample.xcodeproj" \
  -scheme ThroneCoreExample -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED_DATA" \
  THRONE_APP_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=NO \
  2>&1 | tee "$OUT/build.log"

STAGE=$(mktemp -d "$DERIVED_DATA/package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
APP="$STAGE/Payload/ThroneCoreExample.app"
ditto "$DERIVED_DATA/Build/Products/Release-iphoneos/ThroneCoreExample.app" "$APP"
# Add deterministic native PNG icons and usage text before sealing the bundle.
python3 "$ROOT/script/prepare_ios_trollstore.py" "$APP" "$ROOT"

# Sign inside-out. Do not use --deep when signing: the extension has different
# entitlements from its parent. TrollStore preserves these on installation.
while IFS= read -r -d '' library; do
  codesign --force --sign - --timestamp=none "$library"
done < <(find "$APP" -type f -name '*.dylib' -print0)
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements "$STAGE/extension-entitlements.plist" \
  "$APP/PlugIns/PacketTunnel.appex"
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements "$STAGE/host-entitlements.plist" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
{
  xcodebuild -version
  for bundle in "$APP" "$APP/PlugIns/PacketTunnel.appex"; do
    echo "===== $(basename "$bundle") ====="
    codesign -dvvv "$bundle" 2>&1
    codesign -d --entitlements :- "$bundle" 2>/dev/null
    binary=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")
    xcrun vtool -show-build "$bundle/$binary"
    xcrun otool -L "$bundle/$binary"
  done
} > "$OUT/signing-and-platform.txt"
IPA="$OUT/ThroneCoreExample-TrollStore.ipa"
[[ ! -e "$IPA" ]] || rm "$IPA"
(cd "$STAGE" && COPYFILE_DISABLE=1 /usr/bin/zip -qry "$IPA" Payload)
python3 "$ROOT/script/verify_ios_ipa.py" "$IPA" | tee "$OUT/verification.json"
(cd "$OUT" && shasum -a 256 ThroneCoreExample-TrollStore.ipa > SHA256SUMS)
{
  echo "app source $(git -C "$ROOT" rev-parse HEAD)"
  echo "framework source follows:"
  cat "$ROOT/deployment/ios/build-info.txt"
} > "$OUT/build-info.txt"
cp "$ROOT/docs/IOS_TROLLSTORE.md" "$OUT/INSTALL.md"
echo "Packaged $IPA. Static verification passed; physical VPN testing remains required."
