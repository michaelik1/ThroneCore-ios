import Foundation
import Combine
import NetworkExtension

@MainActor
final class VPNController: ObservableObject {
    @Published var mode: ExampleMode = .direct
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var coreStatus = "Connect on a signed physical device to read core status."

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var diagnosticGeneration = UUID()
    private var stopRequested = false
    private var owner: String { Bundle.main.bundleIdentifier! }
    private var providerIdentifier: String { "\(owner).PacketTunnel" }

    var isActive: Bool { [.connecting, .connected, .reasserting, .disconnecting].contains(status) }
    var statusLabel: String {
        switch status {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        @unknown default: return "Unknown"
        }
    }

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshConnectionStatus() }
        }
        busy = true
        loadOwnManager { [weak self] error in
            guard let self = self else { return }
            self.busy = false
            if let configuration = self.manager?.protocolConfiguration as? NETunnelProviderProtocol,
               let value = configuration.providerConfiguration?["mode"] as? String,
               let mode = ExampleMode(rawValue: value) {
                self.mode = mode
            }
            if let error = error { self.message = error.localizedDescription }
        }
    }

    deinit {
        if let observer = statusObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard !busy, !isActive else { return }
        busy = true
        message = ""
        diagnosticGeneration = UUID()
        stopRequested = false
        coreStatus = "Starting \(mode.title). Counters are available after the tunnel connects."
        // Reload first; only a provider ID + owner marker match can be modified.
        loadOwnManager { [weak self] error in
            guard let self = self else { return }
            if let error = error { self.finish(error); return }
            guard !self.isActive else { self.finish(nil); return }
            let manager = self.manager ?? NETunnelProviderManager()
            do {
                let tunnelProtocol = NETunnelProviderProtocol()
                tunnelProtocol.providerBundleIdentifier = self.providerIdentifier
                tunnelProtocol.serverAddress = "ThroneCore developer example"
                tunnelProtocol.providerConfiguration = try self.mode.providerConfiguration(owner: self.owner)
                tunnelProtocol.includeAllNetworks = false
                tunnelProtocol.disconnectOnSleep = false
                manager.protocolConfiguration = tunnelProtocol
                manager.localizedDescription = "ThroneCore Example"
                manager.isOnDemandEnabled = false
                manager.isEnabled = true
                self.manager = manager
                manager.saveToPreferences { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        if let error = error { self.finish(error); return }
                        // NE requires loading the saved configuration before starting it.
                        manager.loadFromPreferences { [weak self] error in
                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                if let error = error { self.finish(error); return }
                                guard self.isOwnManager(manager) else {
                                    self.finish(self.exampleError("Saved VPN no longer matches this app")); return
                                }
                                do {
                                    try manager.connection.startVPNTunnel()
                                    self.finish(nil)
                                } catch { self.finish(error) }
                            }
                        }
                    }
                }
            } catch { self.finish(error) }
        }
    }

    func stop() {
        guard !busy, let manager = manager, isOwnManager(manager) else { return }
        stopRequested = true
        diagnosticGeneration = UUID() // Ignore any error callback from an older attempt.
        manager.connection.stopVPNTunnel()
        refreshConnectionStatus()
    }

    func readStatus() {
        guard let manager = manager, isOwnManager(manager),
              let session = manager.connection as? NETunnelProviderSession,
              session.status == .connected else {
            coreStatus = "The packet tunnel must be connected before reading its status."
            return
        }
        let generation = diagnosticGeneration
        do {
            try session.sendProviderMessage(Data("status".utf8)) { [weak self] response in
                Task { @MainActor [weak self] in
                    guard let self = self, self.diagnosticGeneration == generation,
                          self.manager?.connection === session, session.status == .connected else { return }
                    self.coreStatus = response.flatMap { String(data: $0, encoding: .utf8) }
                        ?? "The provider returned no status."
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func loadOwnManager(completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let error = error { completion(error); return }
                let matches = (managers ?? []).filter { self.isOwnManager($0) }
                guard matches.count <= 1 else {
                    completion(self.exampleError("Multiple example VPN profiles exist. Remove the duplicate in iOS Settings."))
                    return
                }
                self.manager = matches.first
                self.refreshConnectionStatus()
                completion(nil)
            }
        }
    }

    private func isOwnManager(_ manager: NETunnelProviderManager) -> Bool {
        guard let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return configuration.providerBundleIdentifier == providerIdentifier
            && configuration.providerConfiguration?["exampleOwner"] as? String == owner
    }

    private func refreshConnectionStatus() {
        let previous = status
        status = manager?.connection.status ?? .invalid
        guard status != previous else { return }
        if status == .connecting {
            stopRequested = false
            diagnosticGeneration = UUID()
            coreStatus = "Starting \(mode.title). Counters are available after the tunnel connects."
        } else if status == .connected {
            stopRequested = false
            diagnosticGeneration = UUID()
            message = ""
            coreStatus = "Connected. Tap Read status and counters, generate traffic, then read again."
        } else if status == .disconnected {
            coreStatus = "Disconnected. Live core counters are unavailable until the tunnel connects."
            if !stopRequested, [.connecting, .connected, .reasserting, .disconnecting].contains(previous) {
                readDisconnectError()
            }
        }
    }

    /// startVPNTunnel() starts an asynchronous operation. A later provider failure
    /// arrives as a status change, not as a thrown error from that original call.
    func readDisconnectError() {
        guard let manager = manager, isOwnManager(manager), !isActive else { return }
        guard #available(iOS 16.0, *) else {
            message = "System disconnect details require iOS 16 or newer. Check the device's NetworkExtension/crash diagnostics."
            return
        }
        let generation = diagnosticGeneration
        let connection = manager.connection
        connection.fetchLastDisconnectError { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self, self.diagnosticGeneration == generation,
                      !self.isActive, self.manager?.connection === connection else { return }
                if let error = error as NSError? {
                    self.message = "\(error.domain) (\(error.code)): \(error.localizedDescription)"
                } else if self.message.isEmpty {
                    self.message = "iOS did not provide a disconnect error. This does not confirm a successful tunnel start."
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        busy = false
        refreshConnectionStatus()
        if let error = error { message = error.localizedDescription }
    }

    private func exampleError(_ message: String) -> NSError {
        NSError(domain: "ThroneCoreExample", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
