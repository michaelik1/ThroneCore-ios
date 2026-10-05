# Physical-device test using an existing TrollStore installation

This package is the minimal **ThroneCore Example** host and packet-tunnel
extension. It includes the full previously tested ThroneCore runtime, including
Xray and all iOS build feature tags. It is not the full Throne application UI.

## Before installing

- Use an **existing, working TrollStore** on a supported iOS version. The intended
  first test device is an arm64 iPhone running iOS 16.4.1; minimum app OS is 15.0.
- This IPA is ad-hoc signed for TrollStore to re-sign during installation. It is
  not an App Store/TestFlight/ordinary sideloading package. No Apple account or
  developer certificate is needed for this specific installation path.
- Static IPA checks establish bundle structure, device architecture, deployment
  target, entitlements, and signature integrity. They do **not** establish that
  the VPN works on a physical phone. That is the purpose of the test below.
- The host's generic “Requires developer signing” text describes the ordinary
  Xcode installation path; an existing supported TrollStore is the alternative
  used for this package. Developer Mode is not requested by this package.

## Install on the phone

1. Save `ThroneCoreExample-TrollStore.ipa` in **Files** on the iPhone. If downloading
   the GitHub Actions artifact, unzip its outer artifact ZIP first to get the IPA.
   Do not unzip or rename the IPA itself.
2. In TrollStore, tap **+ → Install IPA File**, select the IPA, and confirm **Install**.
   Alternatively, use **Share → TrollStore** from Files if that share action appears.
3. Open **ThroneCore Example**, identifiable by its white T on a teal icon.
   If installation or launch fails, report the exact message or a screenshot before
   changing anything else. This build does not require changing TrollStore settings.

## First test: sing-box direct

1. Disconnect any other VPN manually. Use Wi-Fi for the first test, and confirm
   Safari works before starting this app's VPN.
2. Select **sing-box direct**, tap **Start VPN**, and approve iOS's request to add a
   VPN configuration. The app owns only its matching “ThroneCore Example” profile.
3. Wait for **Connected**. Tap **Read status and counters** and record the status.
4. In Safari, open a fresh web page, then return and read the counters again.
   Report whether the page loaded and whether `uplinkBytes` and `downlinkBytes`
   increased. Send a screenshot of the counters; avoid including unrelated private
   information in screenshots.
5. Tap **Stop VPN**, wait for **Disconnected**, and verify Safari still works.

## Second test: local Xray path

1. While disconnected, select **sing-box through Xray**, then tap **Start VPN**.
2. Repeat the status → Safari traffic → status comparison, then stop and reconnect
   once. Report the versions, `trafficAvailable`, byte totals, and `memoryBytes`.
3. After both basic routes work, separately test screen lock/unlock and Wi-Fi to
   cellular switching. If connectivity breaks, stop this test VPN and report which
   route and transition failed. Do not leave an unreliable test tunnel connected.

Both routes use the phone's existing internet connection. The Xray route passes
traffic through a local SOCKS5 listener and Xray's `freedom` outbound; it does **not**
connect to a remote proxy or change your public IP. DNS queries go to Cloudflare
via HTTPS. The sample has no subscription import, account, secret storage, bundled
GeoIP/geosite databases, or remote proxy configuration editor. It has no kill
switch or fail-closed guarantee. No real proxy credentials are included.

If the tunnel never reaches Connected, report the status and **Last error** text.
A provider crash can prevent status delivery; do not interpret missing counters as
a successful connection. Physical-device extension memory and routing behavior
are still acceptance gates. Remove this test app through TrollStore when finished;
remove its VPN profile manually in iOS Settings if you no longer need it.

## Rebuild and provenance

On macOS, first build the full runtime using `script/build_ios.sh`, then run
`script/package_ios_trollstore.sh`. The packaging script builds the existing host
and extension for arm64/iOS 15, adds native-resolution icons, ad-hoc signs each
bundle inside-out, verifies signatures, creates the IPA, and validates its contents.

The separate `iOS TrollStore IPA` workflow reuses the immutable full XCFramework
from green run 37254620239, source b7b513917e9da38e4574945348a4886ed91b773e.
It checks the archive SHA-256 and source revision and refuses to reuse that archive
if `core/` or `script/build_ios.sh` changed. This packaging-only change does not
alter the runtime. When that artifact expires or the core changes, produce and
verify a new full iOS run, then update the pin and archive hash explicitly.

The artifact contains the IPA, SHA256SUMS, build provenance, code-sign/platform
metadata, machine-readable static checks, and these instructions. The synthetic
`TROLLTROLL` signing identity is local metadata, not an Apple-issued developer team.
Only application/team identity and `packet-tunnel-provider` entitlements are used;
there is no unsandboxing, root helper, debugger, JIT, or memory-limit entitlement.

References:
- [TrollStore features and preserved entitlements](https://github.com/opa334/TrollStore#features)
- [TrollStore 2.1.1 signing implementation](https://github.com/opa334/TrollStore/blob/2.1.1/RootHelper/main.m)
- [Apple Network Extensions entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
