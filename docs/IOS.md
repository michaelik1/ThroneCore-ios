# ThroneCore on iOS

## Build

Requirements: macOS, Xcode with the iOS and simulator SDKs, and Go 1.27.1.
Select the full Xcode installation with `xcode-select` before building.

From the repository root:

```sh
./script/build_ios.sh
```

The script installs the exact SagerNet gomobile/gobind version pinned in
`core/go.mod`, then builds the existing `core/mobile` package. It retains the
Throne sing-box and Xray forks and the Android feature tags, including Naive,
QUIC, WireGuard, uTLS, OpenVPN, and OpenConnect. There is no separate iOS core.

Outputs:

- `deployment/ios/ThroneCore.xcframework`
- `deployment/ios/build-info.txt` (revision and toolchain/dependency versions)

The default slices are iOS arm64 and simulator arm64/x86_64, with iOS 15.0 as
the deployment target. Override `DEST`, `IOS_VERSION`, or `IOS_TARGETS` if needed;
for example, `IOS_TARGETS=ios/arm64,iossimulator/arm64 ./script/build_ios.sh`.
The `iOS` GitHub Actions workflow runs the same build on a macOS/Xcode runner.
Its ZIP artifact preserves framework symlinks; unzip it before adding the
XCFramework to Xcode. The static framework should be linked, not embedded.

## Integration status

The intended integration is:

```text
iOS app -> NEPacketTunnelProvider -> core/mobile -> sing-box + Xray
                    |                    |
                    +-- borrowed utun ---+ (Go owns a duplicate)
```

The build is the first milestone. NetworkExtension platform glue, a minimal
Swift host, and traffic/lifecycle validation follow separately. A successful
XCFramework build does not establish that a VPN tunnel works on a device.
Running a real packet tunnel requires a signed app/extension with the Network
Extension entitlement and a physical iOS device; the simulator can validate
imports and runtime calls but cannot establish this acceptance criterion.

Android continues to use `script/build_android.sh` unchanged.
