# ThroneCore iOS packet-tunnel example

A small SwiftUI host plus `NEPacketTunnelProvider` extension for exercising the
full ThroneCore XCFramework. This is a developer example, not a complete VPN
client. It has no Flutter UI, subscription, remote proxy account, App Group, or
production provisioning setup.

## Build without signing

On macOS with Xcode and its iOS/device simulator SDKs installed, from the repository root:

```sh
bash script/build_ios.sh
bash script/build_ios_example.sh
```

The second script builds `ThroneCoreExample` and its embedded `PacketTunnel.appex`
for both a generic iOS Simulator and a generic iOS device with signing disabled.
It expects the freshly built framework at
`deployment/ios/ThroneCore.xcframework`; an older framework without the Apple
platform bridge will not compile. Build products are under `build/ios-example`,
and logs are `deployment/ios/example-iphonesimulator.log` and
`deployment/ios/example-iphoneos.log`.

Optional build settings:

```sh
THRONE_APP_BUNDLE_IDENTIFIER=com.yourteam.ThroneCoreExample \
  DERIVED_DATA="$PWD/build/my-ios-example" bash script/build_ios_example.sh
```

`THRONE_APP_BUNDLE_IDENTIFIER` is one shared project setting; the extension bundle
ID always adds `.PacketTunnel`. The app derives that extension ID from its own
bundle ID at runtime. Do not override the two product bundle IDs separately.

The framework is static and linked only into the extension. The project links the
same system frameworks and `-lresolv` as the Swift smoke target, without a second
Cronet archive or force-load flag. No framework embedding step is needed.

## Run on a device

1. Open `ThroneCoreExample.xcodeproj` in Xcode and choose the shared
   `ThroneCoreExample` scheme.
2. Set a unique project-level `THRONE_APP_BUNDLE_IDENTIFIER` and a development
   team for both targets. Use an Apple developer team and provisioning profiles
   that support the Network Extensions packet-tunnel capability. Both targets
   already declare the `packet-tunnel-provider` entitlement.
3. Choose a physical iPhone/iPad running iOS 15 or newer and run the host. Accept
   iOS's VPN configuration permission when prompted.
4. Choose a route, tap **Start VPN**, and wait for **Connected**. Tap
   **Read status and counters** to see the core/Xray/Go versions and byte totals.
5. Generate ordinary device traffic, such as opening a website in Safari, then
   read the counters again. `trafficAvailable` and increasing totals are useful
   inspection points, not proof that every traffic class is routed correctly.
6. Stop, reconnect, and repeat with the other route. The sample retains only its
   own matching VPN profile and closes the old core before starting another.

Unsigned builds cannot be installed as a working device VPN. Simulator compilation
and the separate non-TUN smoke suite do not establish device VPN success. Actual
VPN traffic, DNS behavior, IPv4/IPv6 behavior, and network transitions need signed
physical-device verification; no device test result is implied by these files.

## What the two routes do

- **sing-box direct:** TUN traffic exits through sing-box's direct outbound
- **sing-box through Xray:** sing-box sends TUN traffic to an in-process Xray
  SOCKS5 listener on `127.0.0.1:10808`; Xray's `freedom` outbound exits directly

Both examples use TUN addresses `172.19.0.1/30` and `fdfe:dcba:9876::1/126`, MTU
1500, automatic routes, and DNS interception. They send DNS queries to Cloudflare
using HTTPS at `1.1.1.1`, with TLS server name `cloudflare-dns.com`. In the Xray
example the DNS connection also uses the Xray SOCKS outbound. There are no proxy
credentials or private remote proxy endpoints; the Xray route is not a remote
privacy proxy. The local SOCKS listener has no authentication and exists only
while this developer tunnel is running.

The host sets `includeAllNetworks = false`. There is no kill switch or fail-closed
guarantee. Changing that setting requires separate routing and physical-device
validation; the platform adapter reads the actual saved protocol value.

## Lifecycle and configuration boundary

The host loads and saves only profiles whose provider bundle identifier and
`exampleOwner` marker match this app. It refuses ambiguous duplicate matches,
does not delete profiles, and never enables on-demand VPN. The three checked-in
JSON files are bundled with the host and passed as strings in
`NETunnelProviderProtocol.providerConfiguration`. Do not put credentials in these
public sample files; this sample does not implement secret storage.

The provider uses its own Application Support and temporary directories. On a
dedicated serial queue it calls `MobileSetup`, `MobileNewApplePlatform`,
`MobileNewInstance`, and `start()`. All status, pause, wake, and close calls use
that queue too. Stop and startup-error paths close the instance, reset remaining
platform monitors, release retained references, then clear NE settings before
finishing their pending callbacks. The adapter holds the provider weakly.

The system TUN file descriptor is borrowed by Go. Swift never duplicates or
closes it, and the extension must not concurrently read/write `packetFlow` while
the core owns the packet path. Debug configuration logging is disabled, and the
provider reports stage-only startup errors rather than logging config contents.
The app's `status` provider message returns versions, state, totals, connection
counts, and memory/goroutine counts. Startup and cleanup errors are retained as
in-memory stage/domain/code/description diagnostics, exposed only on that explicit
status request and cleared on the next successful start. iOS can terminate the
provider after a failure; a disconnected session may no longer deliver status
messages, so these diagnostics are not a persistent failure history. `uplinkSinceLastRead` and
`downlinkSinceLastRead` are byte deltas since the previous status call, not rates.

This intentionally omits production reconnect policy, background UI polling,
credential handling, an App Store distribution flow, and a device acceptance
matrix. Keep the separate Swift/runtime smoke gate and signed-device acceptance
as distinct checks.
