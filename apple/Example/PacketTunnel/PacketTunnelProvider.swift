import Foundation
import NetworkExtension
import ThroneCore

/// Developer lifecycle example. All Go calls and owned references stay on coreQueue.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum Phase: String { case idle, starting, running, stopping }
    private let coreQueue = DispatchQueue(label: "org.thronecore.example.core")
    private var phase: Phase = .idle
    private var instance: MobileInstance?
    private var applePlatform: ThroneApplePlatform?
    private var goPlatform: MobilePlatformInterfaceProtocol?
    private var stopCompletions: [() -> Void] = []
    private var lastError: [String: Any]?
    private var cleanupErrors: [[String: Any]] = []

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        coreQueue.async {
            guard self.phase == .idle else {
                completionHandler(self.failure("A tunnel operation is already in progress"))
                return
            }
            self.phase = .starting
            var stage = "Read provider configuration"
            do {
                guard let configuration = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                      let coreConfig = configuration["coreConfig"] as? String,
                      !coreConfig.isEmpty else {
                    throw self.failure("Missing example configuration")
                }
                let needsXray = configuration["needXray"] as? Bool ?? false
                let xrayConfig = configuration["xrayConfig"] as? String ?? ""
                guard !needsXray || !xrayConfig.isEmpty else {
                    throw self.failure("Missing Xray configuration")
                }

                stage = "Set up extension directories"
                let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
                    .appendingPathComponent("ThroneCore", isDirectory: true)
                let setup = MobileSetupOptions()
                setup.basePath = root.appendingPathComponent("assets", isDirectory: true).path
                setup.workingPath = root.appendingPathComponent("working", isDirectory: true).path
                setup.tempPath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ThroneCore", isDirectory: true).path
                setup.logMaxLines = 100
                setup.debug = false // Debug mode prints configs, which can contain credentials.
                var setupError: NSError?
                guard MobileSetup(setup, &setupError) else {
                    throw setupError ?? self.failure("Setup failed")
                }

                stage = "Create Apple platform"
                let applePlatform = ThroneApplePlatform(provider: self)
                self.applePlatform = applePlatform
                guard let goPlatform = MobileNewApplePlatform(applePlatform) else {
                    throw self.failure("Missing Go platform")
                }
                self.goPlatform = goPlatform

                let start = MobileStartOptions()
                start.coreConfig = coreConfig
                start.needXray = needsXray
                start.xrayConfig = xrayConfig
                start.xrayLazyStart = false
                stage = "Create core instance"
                var instanceError: NSError?
                guard let instance = MobileNewInstance(goPlatform, start, &instanceError) else {
                    throw instanceError ?? self.failure("Core creation failed")
                }
                self.instance = instance
                if let instanceError = instanceError { throw instanceError }
                stage = "Start core instance"
                try instance.start()
                self.phase = .running
                self.lastError = nil
                self.cleanupErrors.removeAll()
                completionHandler(nil)
            } catch {
                // Do not include Go errors/configuration strings in system error logs.
                // A failure may have installed settings or opened monitors already.
                self.lastError = self.diagnostic(error, stage: stage)
                let safeError = self.failure("\(stage) failed")
                self.closeCoreAndClearSettings {
                    completionHandler(safeError)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        coreQueue.async {
            if self.phase == .stopping {
                self.stopCompletions.append(completionHandler)
            } else if self.phase == .idle {
                completionHandler()
            } else {
                self.closeCoreAndClearSettings(completion: completionHandler)
            }
        }
    }

    /// Close Go before clearing NE settings: Go borrows the system TUN descriptor.
    /// Swift must never dup/close that descriptor. The adapter weakly owns the provider.
    private func closeCoreAndClearSettings(completion: @escaping () -> Void) {
        phase = .stopping
        stopCompletions.append(completion)
        cleanupErrors.removeAll()
        do {
            try instance?.close()
        } catch {
            cleanupErrors.append(diagnostic(error, stage: "Close core instance"))
        }
        instance = nil
        applePlatform?.reset()
        goPlatform = nil
        applePlatform = nil
        setTunnelNetworkSettings(nil) { error in
            self.coreQueue.async {
                if let error = error {
                    self.cleanupErrors.append(self.diagnostic(error, stage: "Clear tunnel settings"))
                }
                self.phase = .idle
                let completions = self.stopCompletions
                self.stopCompletions.removeAll()
                completions.forEach { $0() }
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        coreQueue.async {
            self.instance?.pause()
            completionHandler()
        }
    }

    override func wake() {
        coreQueue.async { self.instance?.wake() }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        coreQueue.async {
            guard String(data: messageData, encoding: .utf8) == "status" else {
                completionHandler?(nil)
                return
            }
            var response: [String: Any] = [
                "state": self.phase.rawValue,
                "coreVersion": MobileVersion(),
                "xrayVersion": MobileXrayVersion(),
                "goVersion": MobileGoVersion()
            ]
            // Diagnostics are exposed only on explicit status requests, never logged.
            // They are in-memory and disappear if iOS terminates the extension.
            if let error = self.lastError { response["lastError"] = error }
            if !self.cleanupErrors.isEmpty { response["cleanupErrors"] = self.cleanupErrors }
            if let status = self.instance?.status() {
                response["trafficAvailable"] = status.trafficAvailable
                response["uplinkBytes"] = status.uplinkTotal
                response["downlinkBytes"] = status.downlinkTotal
                response["uplinkSinceLastRead"] = status.uplink
                response["downlinkSinceLastRead"] = status.downlink
                response["connectionsIn"] = status.connectionsIn
                response["connectionsOut"] = status.connectionsOut
                response["memoryBytes"] = status.memory
                response["goroutines"] = status.goroutines
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: response,
                                                           options: [.prettyPrinted, .sortedKeys]))
        }
    }

    private func diagnostic(_ error: Error, stage: String) -> [String: Any] {
        let error = error as NSError
        return ["stage": stage, "domain": error.domain, "code": error.code,
                "description": error.localizedDescription]
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ThroneCoreExample.PacketTunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
