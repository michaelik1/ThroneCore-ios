import Foundation
import ThroneCore

/// Deliberately offline, non-TUN mock. This is not an iOS VPN platform adapter.
/// Go interfaces have a Protocol suffix in Swift because gomobile also exports
/// an Objective-C wrapper class with the same name.
final class SmokePlatform: NSObject, MobilePlatformInterfaceProtocol {
    struct Snapshot {
        let monitorStarts: Int
        let monitorCloses: Int
        let interfaceReads: Int
        let tunOpens: Int
        let hasMonitor: Bool
    }

    private let lock = NSLock()
    private var monitor: MobileInterfaceUpdateListenerProtocol?
    private var monitorStarts = 0
    private var monitorCloses = 0
    private var interfaceReads = 0
    private var tunOpens = 0

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(monitorStarts: monitorStarts, monitorCloses: monitorCloses,
                        interfaceReads: interfaceReads, tunOpens: tunOpens,
                        hasMonitor: monitor != nil)
    }

    func localDNSTransport() -> MobileLocalDNSTransportProtocol? { nil }
    func usePlatformAutoDetectControl() -> Bool { false }
    func useProcFS() -> Bool { false }

    func autoDetectControl(_ fd: Int32) throws {
        throw smokeError("Socket protection is not implemented by this offline mock")
    }

    func openTun(_ options: MobileTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        lock.lock()
        tunOpens += 1
        lock.unlock()
        throw smokeError("TUN access is forbidden in the simulator smoke test")
    }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                             destinationAddress: String?, destinationPort: Int32) throws -> MobileConnectionOwner {
        throw smokeError("Connection ownership is not implemented by this mock")
    }

    func packageNames(byUid uid: Int32) throws -> MobileStringIteratorProtocol {
        EmptyStringIterator()
    }

    func startDefaultInterfaceMonitor(_ listener: MobileInterfaceUpdateListenerProtocol?) throws {
        guard let listener = listener else { throw smokeError("Missing interface listener") }
        lock.lock()
        guard monitor == nil else {
            lock.unlock()
            throw smokeError("An interface monitor is already active")
        }
        monitor = listener
        monitorStarts += 1
        lock.unlock()

        // The callback re-enters getInterfaces through Go. Never hold our lock
        // across it. Index -1 explicitly reports no default network and avoids
        // inventing a simulator interface or exercising a VPN routing path.
        listener.updateDefaultInterface("", interfaceIndex: -1,
                                        isExpensive: false, isConstrained: false)
    }

    func closeDefaultInterfaceMonitor(_ listener: MobileInterfaceUpdateListenerProtocol?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let active = monitor, let listener = listener,
              sameListener(active, listener) else {
            throw smokeError("Closing an unknown interface monitor")
        }
        monitor = nil
        monitorCloses += 1
    }

    func getInterfaces() throws -> MobileNetworkInterfaceIteratorProtocol {
        lock.lock()
        interfaceReads += 1
        lock.unlock()
        return EmptyNetworkInterfaceIterator()
    }

    func readWIFIState() -> MobileWIFIState? { nil }
    func clearDNSCache() {}

    func send(_ notification: MobileNotification?) throws {
        throw smokeError("Notifications are not implemented by this mock")
    }

    func cancelNotification(_ identifier: String?, typeID: Int32) throws {
        throw smokeError("Notifications are not implemented by this mock")
    }

    private func sameListener(_ lhs: MobileInterfaceUpdateListenerProtocol,
                              _ rhs: MobileInterfaceUpdateListenerProtocol) -> Bool {
        // gomobile creates fresh Objective-C proxies for the same Go object on
        // successive callbacks. Compare the stable Go reference, not proxy identity.
        if let left = lhs as? MobileInterfaceUpdateListener,
           let right = rhs as? MobileInterfaceUpdateListener,
           let leftRef = left._ref as? GoSeqRef,
           let rightRef = right._ref as? GoSeqRef {
            return leftRef.refnum == rightRef.refnum
        }
        return lhs === rhs
    }
}

private final class EmptyNetworkInterfaceIterator: NSObject, MobileNetworkInterfaceIteratorProtocol {
    func hasNext() -> Bool { false }
    func next() -> MobileNetworkInterface? { nil }
}

private final class EmptyStringIterator: NSObject, MobileStringIteratorProtocol {
    func hasNext() -> Bool { false }
    func len() -> Int32 { 0 }
    func next() -> String { "" }
}
