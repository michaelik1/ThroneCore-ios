# Initial iOS physical-device validation

Date: 2026-10-05 (UTC)

## Scope and evidence

These are **tester-reported observations on a physical arm64 iPhone running
iOS 16.4.1 with an existing TrollStore 2.1.1 installation**. They were collected
while following the example's install/start/status/browser/stop instructions.
They are not automated device-lab results, packet captures, performance
measurements, or a full protocol-compatibility certification.

The example embeds public sample configurations. Both routes exit through the
phone's existing internet connection. In Xray mode, sing-box forwards to the
in-process SOCKS5 listener and Xray's `freedom` outbound. No remote proxy server,
subscription, or private proxy credentials were involved.

## Build 1: installation and local Xray route

[IPA build run](https://github.com/michaelik1/ThroneCore-ios/actions/runs/37306603792)

IPA SHA-256:
`784ee43889fcecda4e55b284a45b1ddf591cc37e09e943acb04b374d8b9afc9a`

| Check | Reported result |
| --- | --- |
| TrollStore installation and host launch | Passed |
| Add the app's VPN configuration with iOS consent | Passed |
| Xray mode reaches Connected | Passed |
| Load a fresh Safari page while connected; read counters again | Page loaded; counters increased |
| Stop, reconnect, load another page, read counters | Passed; counters continued increasing |
| Screen lock/unlock and dismissing the host from the app switcher | Tunnel continued working |
| Switch between Wi-Fi and cellular | Connection remained active; counters continued increasing |
| Direct mode startup | Failed: Connecting immediately returned to Disconnected |

The direct failure was traced to a concrete configuration defect: the modern
HTTPS DNS transport was explicitly detoured to a bare direct outbound, which the
pinned core rejects during Start. This was not evidence of a generic TrollStore
entitlement failure or a measured memory-limit failure.

## Build 2: corrected direct route

[Fix PR](https://github.com/michaelik1/ThroneCore-ios/pull/5) ·
[IPA build run](https://github.com/michaelik1/ThroneCore-ios/actions/runs/37308931084)

IPA SHA-256:
`02c191829b8669b1082575508d75d8ee56e8dd20816c2a043787570b79b0f594`

Build 2 removes the unnecessary direct DNS detour, retains the Xray configuration
and full runtime, and adds asynchronous disconnect-error visibility to the host.

| Check | Reported result |
| --- | --- |
| Update the existing TrollStore app to Build 2 | Passed |
| Direct mode reaches Connected and loads a Safari page | Passed |
| Read direct-mode counters before/after traffic | Counters increased |
| Stop/start direct mode and load a fresh page | Passed |

The earlier Xray observations belong to Build 1. They are not relabeled as a full
repeat of those device tests on Build 2 merely because its core is unchanged.

## Separate automated evidence

The Build 2 packaging job passed 11 simulator tests, including:

- Start/Close twice with the actual bundled direct configuration, removing only
  its TUN inbound so the test does not require a real VPN
- Equivalent Start/Close tests for the actual bundled Xray configuration
- Reintroducing the original direct DNS detour: construction succeeds, then Start
  rejects it with the expected error and releases the interface monitor
- Existing settings translation, NSError propagation, lifecycle, and real
  loopback TCP traffic through sing-box and Xray after reconnect

Both delivered IPAs separately passed bundle/architecture/deployment checks,
strict macOS signature verification, and independent code/resource-hash checks.
The device binaries target iOS 15 or newer. These checks establish packaging and
specified runtime behavior; they do not substitute for the physical observations
above.

## Remaining acceptance work

The following have not been established by this initial session:

1. Explicit UDP, IPv6-only/dual-stack, and DNS-routing/leak tests
2. Interoperability with real remote proxies and individual protocol combinations
3. Long-duration operation, repeated handovers/offline recovery, and failure modes
4. Peak/sustained extension memory, jetsam behavior, battery use, and throughput
5. Fail-closed or kill-switch behavior; this example keeps includeAllNetworks off
6. A repeatable automated physical-device test harness and broader device/OS matrix

Do not infer these outcomes from Connected, a loaded page, or increasing counters.
See [the installation/test guide](IOS_TROLLSTORE.md) for reproducing the basic
checks and [the iOS integration guide](IOS.md) for platform limitations.

## Practical next test plan

Run these as separate, bounded checks after agreeing on the required tools and
endpoints. They are a plan, not completed tests; no new telemetry or test harness
is included in this change.

### 1. Prove a UDP data path

Prerequisites: a UDP-capable probe on the phone and a controlled UDP echo/test
server whose received datagrams can be observed. The current host does not
include such a probe. Choose a server without real account credentials or private
payloads for the initial test.

- With the VPN off, send a small uniquely labeled test datagram and verify its
  echoed reply and the server-side receive record
- Repeat in direct mode, then Xray mode; record replies, packet loss, and core
  counter deltas, and correlate the test with packet/per-flow evidence at the
  tunnel or proxy boundary using agreed diagnostic tooling
- Include stop/reconnect once after the baseline succeeds

A loaded browser page, HTTP/3 negotiation claim, or increasing aggregate counters
alone is not sufficient proof of this UDP test. A server receiving the echo alone
also does not prove it traversed the TUN rather than a bypass path. DNS uses HTTPS in these samples,
so successful DNS resolution does not establish an arbitrary UDP outbound path.

### 2. Separate IPv6 from IPv4 behavior

Prerequisites: a network with working IPv6 connectivity and a known IPv6-capable
server. First demonstrate reachability with the VPN off. An IPv6 address on the
example's TUN interface does not establish upstream IPv6 connectivity.

- Use a controlled HTTPS hostname with an AAAA-only endpoint and a valid
  certificate; confirm the intended IPv6 connection using server-side evidence
- Repeat the same endpoint in each route, then use an IPv4-only endpoint as a
  comparison; record page/probe success and counter deltas separately
- Treat an IPv4-only network without usable IPv6 as a missing prerequisite for
  this check, not automatically as a core regression
- Test an IPv6-only network or DNS64/NAT64 environment separately if available;
  document the network type instead of treating all IPv6-capable networks as equal

### 3. Measure extension memory and stability

Start with a short, bounded window per route: baseline just after connection,
several representative transfers, a short idle period, and a few reconnects.
Record elapsed time and the example's `memoryBytes` status field. Obtain the
extension's system memory/termination diagnostics if a stop or crash occurs.

`memoryBytes` normally reports the extension process's Darwin physical footprint,
not the IPA/executable size or Go heap alone. If the native query fails, the
current implementation falls back to a Go-runtime memory value, so corroborate
it with system diagnostics before drawing process-budget conclusions. Manual
samples can miss startup/burst peaks and cannot establish a safe peak budget.
Correlate jetsam/termination reports with the same test window before attributing
a failure to memory. No numeric memory ceiling has been established.

If the device is jailbroken or has configuration changes, record whether they
change extension limits. Survival under changed limits is not proof of readiness under stock iOS
NetworkExtension limits. A stock-device acceptance pass remains separate.

### 4. Exercise DNS and failure behavior deliberately

Use identifiable, non-sensitive test queries and a controlled resolver/capture
setup when claiming DNS routing or leak behavior. Test online startup, a brief
offline interval, reconnect, and restored browsing in each route. Record whether
traffic falls back outside the tunnel; this example does not promise fail-closed
behavior. Stop the test VPN if it disrupts ordinary connectivity.

Any new probe, capture setup, or automated peak-memory instrumentation should be
proposed and scoped before implementation rather than silently added to this
minimal example.
