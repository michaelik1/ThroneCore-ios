#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT="$ROOT/apple/Smoke/ThroneCoreSmoke.xcodeproj"
FRAMEWORK="$ROOT/deployment/ios/ThroneCore.xcframework"
DERIVED_DATA="$ROOT/build/ios-smoke"
RESULT_BUNDLE="$ROOT/deployment/ios/RuntimeSmoke.xcresult"
LOG="$ROOT/deployment/ios/runtime-smoke.log"

fail() { echo "iOS smoke test: $*" >&2; exit 1; }

[[ $(uname -s) == Darwin ]] || fail "requires macOS and Xcode; Linux checks do not execute iOS tests."
for tool in xcrun xcodebuild python3; do
  command -v "$tool" >/dev/null || fail "missing prerequisite: $tool"
done
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null || fail "the iOS simulator SDK is not installed."
[[ -f "$FRAMEWORK/Info.plist" ]] || fail "missing $FRAMEWORK; run script/build_ios.sh first (with its default DEST)."

# Select an installed, available iPhone on the newest available iOS runtime.
# An optional SIMULATOR_UDID selects a specific available iPhone from that list.
DEVICES_JSON=$(mktemp)
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun simctl list devices available --json > "$DEVICES_JSON"
SIMULATOR_ID=$(python3 - "$DEVICES_JSON" "${SIMULATOR_UDID:-}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    devices = json.load(source).get("devices", {})
requested = sys.argv[2]
candidates = []
for runtime, entries in devices.items():
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match.group(1).split("-"))
    if version < (15,):
        continue
    for device in entries:
        if not device.get("isAvailable", False) or not device.get("name", "").startswith("iPhone"):
            continue
        if requested and device.get("udid") != requested:
            continue
        candidates.append((version, device.get("state") == "Booted", device["name"], device["udid"]))
if not candidates:
    detail = f"matching SIMULATOR_UDID={requested}" if requested else "running iOS 15 or newer"
    sys.exit(f"iOS smoke test: no available installed iPhone simulator {detail}; install an iOS runtime in Xcode Settings > Components.")
selected = max(candidates)
print(f"Using {selected[2]} (iOS {'.'.join(map(str, selected[0]))}), {selected[3]}", file=sys.stderr)
print(selected[3])
PY
)

mkdir -p "$DERIVED_DATA" "$ROOT/deployment/ios"
# xcodebuild refuses an existing result path. Preserve earlier results instead
# of deleting them, while giving CI a stable path for the newest result.
if [[ -e "$RESULT_BUNDLE" ]]; then
  mv "$RESULT_BUNDLE" "$ROOT/deployment/ios/RuntimeSmoke-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
fi
echo "Result bundle: $RESULT_BUNDLE"
xcodebuild test \
  -project "$PROJECT" \
  -scheme ThroneCoreSmoke \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -destination-timeout 180 \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG"
