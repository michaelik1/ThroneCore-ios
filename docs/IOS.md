# ThroneCore on iOS

## Build and test

Requirements: macOS, Xcode with the iOS/device and simulator SDKs, and Go 1.27.1.
Select the full Xcode installation with `xcode-select` before building.

```sh
./script/build_ios.sh          # deployment/ios/ThroneCore.xcframework
./script/test_ios.sh           # Swift/iOS Simulator runtime tests
./script/build_ios_example.sh  # unsigned app + packet-tunnel extension, both SDKs
```

The build installs the exact SagerNet gomobile/gobind version in `core/go.mod`.
It builds the existing `core/mobile`, retaining both Throne forks and the Android
feature tags: gVisor, QUIC, WireGuard, uTLS, Clash API, OpenVPN, OpenConnect, and
Naive. Xray's full protocol distribution remains linked; there is no separate
reduced iOS core. Retaining a feature does not establish device interoperability
for every protocol.

Default slices: iOS arm64 and simulator arm64/x86_64, deployment target iOS 15.0.
`DEST`, `IOS_VERSION`, and `IOS_TARGETS` can override the build defaults; e.g.
`IOS_TARGETS=ios/arm64,iossimulator/arm64 ./script/build_ios.sh`.
The example/test scripts expect the default framework location.

The `iOS` GitHub Actions workflow uses macOS/Xcode for the actual build and
simulator execution. It publishes a ZIP preserving framework symlinks plus
`build-info.txt`, which records the revision and toolchain/dependency versions.
It also runs Darwin FD ownership tests, the unchanged full Android build, and a
Linux desktop core compile smoke without Naive (not a full desktop release).
`script/build_android.sh` and desktop build scripts remain unchanged.

Unzip the artifact before adding it to Xcode. The framework is static: link it,
do not embed it. It already contains native static libraries, including Cronet.
The final Swift link also needs `libresolv` and the Apple system frameworks in
`apple/Smoke/ThroneCoreSmoke.xcodeproj`'s `OTHER_LDFLAGS`; do not add another
Cronet archive or force-load the whole framework. The checked-in projects show
the complete link setup.

## Integration

```text
Swift host -> NETunnelProviderManager -> NEPacketTunnelProvider
                                           |
                                  ThroneApplePlatform
                                           |
                         NewApplePlatform -> NewInstance
                                           |
                                  sing-box + Xray
                                           |
                   NE-owned utun -> Go-owned duplicate -> sing-tun
```

The reusable Swift adapter is `apple/Sources/ThroneApplePlatform.swift`.
The minimal signed-device host is `apple/Example`; see its [README](../apple/Example/README.md)
for bundle IDs, signing, profile ownership, and running the two sample routes.
There is no Flutter UI or App Group dependency.

On a dedicated serial queue, the provider calls `MobileSetup`,
`MobileNewApplePlatform`, `MobileNewInstance`, and `instance.start()`.
Stop/error paths call `instance.close()`, release the platform and instance,
and clear NE settings. Sleep/wake forward `pause()`/`wake()`. Setup/protector
state is process-wide: run one active instance and close it before replacing it.

`ApplePlatformInterface` supplies only TUN creation, network-interface discovery
and monitoring, and NetworkExtension flags. The Go adapter preserves the existing
Android interface while disabling Android socket protection, procfs/owner lookup,
platform Wi-Fi state, notifications, and custom platform DNS on Apple. DNS uses
the core's transports and the servers supplied to NetworkExtension.

The Swift layer builds IPv4/IPv6 addresses, included/excluded routes, DNS, MTU,
and optional HTTP proxy settings from the final Go `TunOptions`. It waits for
`setTunnelNetworkSettings` before returning the descriptor. `NWPathMonitor`
reports initial and changing default paths, including offline/cost/constrained
state, without holding locks across reentrant Go callbacks. Each Go listener
has its own monitor and teardown.

### Descriptor ownership and API limitation

NetworkExtension retains the original utun FD. Swift never closes or duplicates
it and must not read/write `packetFlow` concurrently with the core. Go validates
the TUN name, creates a nonzero CLOEXEC duplicate, closes that duplicate on
construction failure, and otherwise transfers ownership to `sing-tun.Close`.
Darwin uses `EXP_ExternalConfiguration` so sing-tun does not install/remove NE's
routes or invoke desktop DNS-cache commands.

The descriptor scan follows the upstream Apple-client compatibility pattern,
searching FDs 0–1023 for `com.apple.net.utun_control`. It assumes one active packet
tunnel in the process. **Apple does not provide a supported public utun-FD API
for `NEPacketTunnelFlow` and does not guarantee that such an FD exists.** The
adapter fails startup if it cannot find one; this is not an App Store/API-stability
guarantee. Apple documents the supported packet-flow API instead. See
[Apple DTS](https://developer.apple.com/forums/thread/756852).

### Routing and Xray

The adapter reports `UnderNetworkExtension=true` and reads `includeAllNetworks`
from the actual saved `NETunnelProviderProtocol`; the example defaults it to
false. The pinned sing-tun rejects `system`/`mixed` stacks with include-all enabled.
Do not treat that flag as Android-style socket protection or a kill switch.
Xray's ordinary sockets rely on Apple's in-provider routing behavior and require
separate physical-device verification, especially across network changes.

The direct sample exits through sing-box. The Xray sample sends sing-box traffic
to in-process SOCKS5 on `127.0.0.1:10808`, then Xray `freedom`. Both are connectivity
examples, not remote privacy proxies. Their DNS goes to Cloudflare over HTTPS;
in Xray mode that DNS connection also traverses Xray. No proxy credentials or
private endpoints are included.
The example does not bundle GeoIP/geosite databases or external rule sets.
Configs that use them must make those assets available inside the extension's
container (or an explicitly configured shared container) and set the appropriate
`SetupOptions` paths; Xray uses `BasePath` as `XRAY_LOCATION_ASSET`.

## What validation establishes

- XCFramework build: all three slices, full existing feature tags and both forks
- Swift simulator suite: version calls, NSError propagation, eager Xray startup,
  sing-box start/close/reconnect, real loopback TCP bytes through sing-box → Xray,
  listener-port release/reuse, and Go TUN-options-to-NE-settings translation
- Darwin tests: duplicate ownership, close/error cleanup, and external configuration
- Unsigned example build: Swift host and NetworkExtension compile/link for device
  and simulator; it cannot install a working device VPN

The settings tests deliberately stop before opening a real TUN. Simulator and
compile success do not establish real device VPN traffic. A signed app/extension,
a developer team/profile supporting packet-tunnel entitlements, and a physical
iPhone/iPad are still required for acceptance. Record these results separately:

1. Connect each sample, generate device traffic, and observe increasing core counters
2. Verify TCP/UDP traffic and DNS, including IPv4-only and IPv6-capable networks
3. Disconnect and verify resource release; reconnect repeatedly
4. Exercise sleep/wake and Wi-Fi ↔ cellular transitions
5. Verify the Xray route's actual data path and ordinary socket behavior
6. Exercise invalid config/startup errors, offline recovery, and any include-all mode
7. Measure startup peaks and sustained physical memory for direct/Xray traffic,
   bursts and reconnects, and inspect unexpected termination/jetsam reports

This initial port does not enable libbox's optional OOM policy or impose an
unmeasured fixed Go memory budget. `Status().Memory` reports Darwin physical
footprint, but periodic reads can miss peaks and a Go soft limit would not cover
all native/Swift allocations. Extension memory readiness remains a device gate.

No physical-device result or full protocol compatibility matrix is implied by
this repository's CI. See the example README for the current developer-host
limitations and diagnostics.

References: [sing-box for Apple](https://github.com/SagerNet/sing-box-for-apple),
[OpenRay](https://github.com/yinjiaming666/OpenRay), and
[Apple in-provider networking](https://developer.apple.com/documentation/networkextension/in-provider-networking).
