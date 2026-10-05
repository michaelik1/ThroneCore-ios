#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT="$ROOT/apple/Example/ThroneCoreExample.xcodeproj"
FRAMEWORK="$ROOT/deployment/ios/ThroneCore.xcframework"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/ios-example}"
BUNDLE_ID="${THRONE_APP_BUNDLE_IDENTIFIER:-org.thronecore.example}"

fail() { echo "iOS example build: $*" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || fail "requires macOS and Xcode; no iOS compilation or VPN execution is possible here."
for tool in xcrun xcodebuild; do
  command -v "$tool" >/dev/null || fail "missing prerequisite: $tool"
done
[[ -f "$FRAMEWORK/Info.plist" ]] || fail "missing $FRAMEWORK; run script/build_ios.sh first (with its default DEST)."

mkdir -p "$DERIVED_DATA" "$ROOT/deployment/ios"
for sdk in iphonesimulator iphoneos; do
  xcrun --sdk "$sdk" --show-sdk-path >/dev/null || fail "$sdk SDK is not installed."
  if [[ $sdk == iphonesimulator ]]; then
    DESTINATION='generic/platform=iOS Simulator'
  else
    DESTINATION='generic/platform=iOS'
  fi
  # This builds the host and embedded extension without signing or Apple accounts.
  # It neither installs a VPN nor establishes that device packet traffic works.
  xcodebuild build \
    -project "$PROJECT" \
    -scheme ThroneCoreExample \
    -configuration Debug \
    -sdk "$sdk" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA/$sdk" \
    THRONE_APP_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=NO 2>&1 | tee "$ROOT/deployment/ios/example-$sdk.log"
done

echo "Built unsigned simulator and device examples. Actual VPN testing requires developer signing and a physical device."
