import Foundation
import Network
import NetworkExtension
import ThroneCore

/// NetworkExtension callbacks for the existing ThroneCore mobile runtime.
/// Call the core's blocking lifecycle methods from a dedicated queue, not the main queue.
final class ThroneApplePlatform: NSObject, MobileApplePlatformInterfaceProtocol {
    private weak var provider: NEPacketTunnelProvider?
    private let pathQueue = DispatchQueue(label: "org.thronecore.network-path")
    private let lock = NSLock()
    private var monitors: [ListenerKey: PathMonitor] = [:]
    private var latestPath: NWPath?

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    deinit { reset() }

    func underNetworkExtension() -> Bool { true }

    func networkExtensionIncludeAllNetworks() -> Bool {
        (provider?.protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks ?? false
    }

    func openTun(_ options: MobileTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options = options, let result = ret0_, let provider = provider else {
            throw applePlatformError("Missing tunnel options, result pointer, or provider")
        }
        let settings = try ThroneNetworkSettings.make(options)
        let completed = DispatchSemaphore(value: 0)
        var settingsError: Error?
        provider.setTunnelNetworkSettings(settings) { error in
            settingsError = error
            completed.signal()
        }
        guard completed.wait(timeout: .now() + 15) == .success else {
            throw applePlatformError("Timed out applying NetworkExtension settings")
        }
        if let settingsError = settingsError { throw settingsError }

        // This is the descriptor-discovery compatibility pattern used by upstream
        // Apple clients. NEPacketTunnelFlow has no supported public FD API. The
        // original belongs to NetworkExtension; Go duplicates it and owns only that copy.
        let descriptor = MobileGetTunnelFileDescriptor()
        guard descriptor >= 0 else {
            throw applePlatformError("NetworkExtension did not expose a usable utun descriptor")
        }
        result.pointee = descriptor
    }

    func startDefaultInterfaceMonitor(_ listener: MobileInterfaceUpdateListenerProtocol?) throws {
        guard let listener = listener else { throw applePlatformError("Missing interface listener") }
        let key = ListenerKey(listener)
        let entry = PathMonitor(listener: listener)
        lock.lock()
        guard monitors[key] == nil else {
            lock.unlock()
            throw applePlatformError("Interface listener is already registered")
        }
        monitors[key] = entry
        lock.unlock()

        entry.monitor.pathUpdateHandler = { [weak self, weak entry] path in
            guard let self = self, let entry = entry else { return }
            self.update(path, key: key, entry: entry)
        }
        entry.monitor.start(queue: pathQueue)
        guard entry.initialUpdate.wait(timeout: .now() + 10) == .success else {
            removeMonitor(key, matching: entry)
            throw applePlatformError("Timed out waiting for the initial network path")
        }
        lock.lock()
        let initialized = monitors[key] === entry && entry.initialized
        lock.unlock()
        guard initialized else { throw applePlatformError("Interface monitor was cancelled during startup") }
    }

    func closeDefaultInterfaceMonitor(_ listener: MobileInterfaceUpdateListenerProtocol?) throws {
        guard let listener = listener else { return }
        removeMonitor(ListenerKey(listener))
    }

    func getInterfaces() throws -> MobileNetworkInterfaceIteratorProtocol {
        lock.lock()
        let path = latestPath
        lock.unlock()
        let interfaces = (path?.availableInterfaces ?? []).map { interface -> MobileNetworkInterface in
            let result = MobileNetworkInterface()
            result.name = interface.name
            result.index = Int32(interface.index)
            switch interface.type {
            case .wifi: result.type = MobileInterfaceTypeWIFI
            case .cellular: result.type = MobileInterfaceTypeCellular
            case .wiredEthernet: result.type = MobileInterfaceTypeEthernet
            default: result.type = MobileInterfaceTypeOther
            }
            // On Darwin the core fills addresses, flags and MTU from its interface
            // finder. NWPath supplies type and the default path's cost/constrained state.
            return result
        }
        return AppleNetworkInterfaceIterator(interfaces)
    }

    /// Also safe after failed construction, when the core may not own a monitor yet.
    func reset() {
        lock.lock()
        let entries = Array(monitors.values)
        monitors.removeAll()
        latestPath = nil
        lock.unlock()
        for entry in entries {
            entry.monitor.cancel()
            entry.initialUpdate.signal()
        }
    }

    private func update(_ path: NWPath, key: ListenerKey, entry: PathMonitor) {
        lock.lock()
        guard monitors[key] === entry else {
            lock.unlock()
            return
        }
        latestPath = path
        entry.path = path
        let firstUpdate = !entry.initialized
        entry.initialized = true
        lock.unlock()

        // The listener synchronously calls back into getInterfaces through Go.
        // Holding our lock (or queue.sync-ing back here) would deadlock startup.
        if path.status == .satisfied, let interface = path.availableInterfaces.first {
            entry.listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index),
                                                  isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        } else {
            entry.listener.updateDefaultInterface("", interfaceIndex: -1,
                                                  isExpensive: false, isConstrained: false)
        }
        if firstUpdate { entry.initialUpdate.signal() }
    }

    private func removeMonitor(_ key: ListenerKey, matching expected: PathMonitor? = nil) {
        lock.lock()
        guard let entry = monitors[key], expected == nil || entry === expected else {
            lock.unlock()
            return
        }
        monitors.removeValue(forKey: key)
        latestPath = monitors.values.compactMap { $0.path }.first
        lock.unlock()
        entry.monitor.cancel()
        entry.initialUpdate.signal()
    }
}

private final class PathMonitor {
    let monitor = NWPathMonitor()
    let listener: MobileInterfaceUpdateListenerProtocol
    let initialUpdate = DispatchSemaphore(value: 0)
    var initialized = false // Protected by ThroneApplePlatform.lock.
    var path: NWPath?

    init(listener: MobileInterfaceUpdateListenerProtocol) { self.listener = listener }
}

private enum ListenerKey: Hashable {
    case go(Int32)
    case object(ObjectIdentifier)

    init(_ listener: MobileInterfaceUpdateListenerProtocol) {
        // Successive gomobile calls can wrap one Go listener in different ObjC proxies.
        if let proxy = listener as? MobileInterfaceUpdateListener,
           let reference = proxy._ref as? GoSeqRef {
            self = .go(reference.refnum)
        } else {
            self = .object(ObjectIdentifier(listener))
        }
    }
}

private final class AppleNetworkInterfaceIterator: NSObject, MobileNetworkInterfaceIteratorProtocol {
    private let interfaces: [MobileNetworkInterface]
    private var index = 0

    init(_ interfaces: [MobileNetworkInterface]) { self.interfaces = interfaces }
    func hasNext() -> Bool { index < interfaces.count }
    func next() -> MobileNetworkInterface? {
        guard hasNext() else { return nil }
        defer { index += 1 }
        return interfaces[index]
    }
}

/// Translate the core's final TUN options rather than inventing a separate Apple config.
enum ThroneNetworkSettings {
    static func make(_ options: MobileTunOptionsProtocol) throws -> NEPacketTunnelNetworkSettings {
        guard options.getMTU() > 0 else { throw applePlatformError("TUN MTU must be positive") }
        guard values(options.getIncludePackage()).isEmpty,
              values(options.getExcludePackage()).isEmpty else {
            throw applePlatformError("Android package routing is not supported on iOS")
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        let addresses4 = try prefixes(options.getInet4Address())
        if !addresses4.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: addresses4.map { $0.address() },
                                     subnetMasks: addresses4.map { $0.mask() })
            // The Go ranges already incorporate auto_route and route exclusions,
            // including an intentionally empty range. Never turn empty into 0/0.
            ipv4.includedRoutes = try prefixes(options.getInet4RouteRange()).map {
                NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask())
            }
            ipv4.excludedRoutes = try prefixes(options.getInet4RouteExcludeAddress()).map {
                NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask())
            }
            settings.ipv4Settings = ipv4
        }
        let addresses6 = try prefixes(options.getInet6Address())
        if !addresses6.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: addresses6.map { $0.address() },
                                     networkPrefixLengths: addresses6.map { NSNumber(value: $0.prefix()) })
            ipv6.includedRoutes = try prefixes(options.getInet6RouteRange()).map {
                NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix()))
            }
            ipv6.excludedRoutes = try prefixes(options.getInet6RouteExcludeAddress()).map {
                NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix()))
            }
            settings.ipv6Settings = ipv6
        }
        guard settings.ipv4Settings != nil || settings.ipv6Settings != nil else {
            throw applePlatformError("At least one IPv4 or IPv6 TUN address is required")
        }

        if options.getDNSMode()?.value != MobileDNSModeDisabled {
            let servers = values(try options.getDNSServerAddress())
            if !servers.isEmpty {
                let dns = NEDNSSettings(servers: servers)
                dns.matchDomains = [""]
                dns.matchDomainsNoSearch = true
                settings.dnsSettings = dns
            }
        }
        if options.isHTTPProxyEnabled() {
            let port = Int(options.getHTTPProxyServerPort())
            guard (1...65535).contains(port) else { throw applePlatformError("Invalid HTTP proxy port") }
            let server = NEProxyServer(address: options.getHTTPProxyServer(), port: port)
            let proxy = NEProxySettings()
            proxy.httpEnabled = true
            proxy.httpServer = server
            proxy.httpsEnabled = true
            proxy.httpsServer = server
            proxy.exceptionList = values(options.getHTTPProxyBypassDomain())
            let domains = values(options.getHTTPProxyMatchDomain())
            proxy.matchDomains = domains.isEmpty ? [""] : domains
            settings.proxySettings = proxy
        }
        return settings
    }

    private static func prefixes(_ iterator: MobileRoutePrefixIteratorProtocol?) throws -> [MobileRoutePrefix] {
        var result: [MobileRoutePrefix] = []
        while let iterator = iterator, iterator.hasNext() {
            guard let value = iterator.next() else { throw applePlatformError("Invalid route prefix iterator") }
            result.append(value)
        }
        return result
    }

    private static func values(_ iterator: MobileStringIteratorProtocol?) -> [String] {
        var result: [String] = []
        while let iterator = iterator, iterator.hasNext() { result.append(iterator.next()) }
        return result
    }
}

private func applePlatformError(_ description: String) -> NSError {
    NSError(domain: "ThroneCore.ApplePlatform", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
}
