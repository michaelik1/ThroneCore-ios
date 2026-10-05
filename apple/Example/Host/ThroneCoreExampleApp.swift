import SwiftUI

@main
struct ThroneCoreExampleApp: App {
    @StateObject private var vpn = VPNController()

    var body: some Scene {
        WindowGroup {
            NavigationView {
                Form {
                    Section(header: Text("Developer example")) {
                        Picker("Route", selection: $vpn.mode) {
                            ForEach(ExampleMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .disabled(vpn.busy || vpn.isActive)
                        Text(vpn.statusLabel)
                        Button("Start VPN") { vpn.start() }
                            .disabled(vpn.busy || vpn.isActive)
                        Button("Stop VPN") { vpn.stop() }
                            .disabled(vpn.busy || !vpn.isActive)
                    }
                    Section(header: Text("Core status")) {
                        Button("Read status and counters") { vpn.readStatus() }
                            .disabled(vpn.busy || vpn.status != .connected)
                        Text(vpn.coreStatus)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Section(header: Text("Disconnect diagnostics")) {
                        Button("Read last disconnect error") { vpn.readDisconnectError() }
                            .disabled(vpn.busy || vpn.isActive)
                    }
                    if !vpn.message.isEmpty {
                        Section(header: Text("Last error")) { Text(vpn.message) }
                    }
                    Section {
                        Text("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")
                        Text("Requires a physical iPhone or iPad, installed with developer signing or an existing supported TrollStore. Simulator tests do not establish device VPN behavior.")
                        Text("Both routes use your existing internet connection. Xray runs locally with a freedom outbound; it is not a remote privacy proxy.")
                        Text("The examples send DNS queries to Cloudflare over HTTPS.")
                        Text("includeAllNetworks is off. This example does not provide a kill switch or a fail-closed guarantee.")
                    }
                    .font(.footnote)
                }
                .navigationTitle("ThroneCore Example")
            }
            .navigationViewStyle(.stack)
        }
    }
}
