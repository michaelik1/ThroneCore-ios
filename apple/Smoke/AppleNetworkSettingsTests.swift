import Foundation
import NetworkExtension
import ThroneCore
import XCTest

/// Exercises real Go TunOptions and the Swift settings translator, then deliberately
/// fails OpenTun before descriptor discovery. No device tunnel is opened by this suite.
final class AppleNetworkSettingsTests: XCTestCase {
    func testDualStackRoutesDNSAndMTU() throws {
        let settings = try capture([
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "mtu": 1500,
            "auto_route": true,
            "dns_mode": "hijack",
            "dns_address": ["172.19.0.2", "fdfe:dcba:9876::2"]
        ])
        XCTAssertEqual(settings.mtu?.intValue, 1500)
        XCTAssertEqual(settings.ipv4Settings?.addresses, ["172.19.0.1"])
        XCTAssertEqual(settings.ipv4Settings?.subnetMasks, ["255.255.255.252"])
        XCTAssertEqual(settings.ipv6Settings?.addresses, ["fdfe:dcba:9876::1"])
        XCTAssertEqual(settings.ipv6Settings?.networkPrefixLengths.map { $0.intValue }, [126])
        XCTAssertTrue(settings.ipv4Settings?.includedRoutes?.contains {
            $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
        } ?? false)
        XCTAssertTrue(settings.ipv6Settings?.includedRoutes?.contains {
            $0.destinationAddress == "::" && $0.destinationNetworkPrefixLength.intValue == 0
        } ?? false)
        XCTAssertEqual(settings.dnsSettings?.servers, ["172.19.0.2", "fdfe:dcba:9876::2"])
        XCTAssertEqual(settings.dnsSettings?.matchDomains, [""])
        XCTAssertEqual(settings.dnsSettings?.matchDomainsNoSearch, true)
    }

    func testExplicitRoutesAndExclusions() throws {
        let settings = try capture([
            "address": ["172.19.0.1/30"],
            "mtu": 1500,
            "auto_route": true,
            "dns_mode": "disabled",
            "route_address": ["10.0.0.0/8"],
            "route_exclude_address": ["10.1.0.0/16"]
        ])
        let routes = try XCTUnwrap(settings.ipv4Settings?.includedRoutes)
        XCTAssertFalse(routes.isEmpty)
        XCTAssertFalse(routes.contains { $0.destinationSubnetMask == "0.0.0.0" })
        let excluded = try XCTUnwrap(settings.ipv4Settings?.excludedRoutes)
        XCTAssertEqual(excluded.count, 1)
        XCTAssertEqual(excluded.first?.destinationAddress, "10.1.0.0")
        XCTAssertEqual(excluded.first?.destinationSubnetMask, "255.255.0.0")
        XCTAssertNil(settings.dnsSettings)
    }

    func testIPv6OnlyAndNetworkExtensionDefaultMTU() throws {
        let settings = try capture([
            "address": ["fdfe:dcba:9876::1/126"],
            "auto_route": true,
            "dns_mode": "disabled"
        ])
        XCTAssertNil(settings.ipv4Settings)
        XCTAssertNotNil(settings.ipv6Settings)
        XCTAssertEqual(settings.mtu?.intValue, 4064)
        XCTAssertNil(settings.dnsSettings)
    }

    func testExcludedEverythingDoesNotRestoreDefaultRoutes() throws {
        let settings = try capture([
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "auto_route": true,
            "dns_mode": "disabled",
            "route_exclude_address": ["0.0.0.0/0", "::/0"]
        ])
        XCTAssertEqual(settings.ipv4Settings?.includedRoutes?.count, 0)
        XCTAssertEqual(settings.ipv6Settings?.includedRoutes?.count, 0)
    }

    private func capture(_ tunOptions: [String: Any]) throws -> NEPacketTunnelNetworkSettings {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = MobileSetupOptions()
        setup.basePath = root.appendingPathComponent("base").path
        setup.workingPath = root.appendingPathComponent("work").path
        setup.tempPath = root.appendingPathComponent("temp").path
        var error: NSError?
        guard MobileSetup(setup, &error) else { throw error ?? smokeError("Setup failed") }

        var inbound = tunOptions
        inbound["type"] = "tun"
        inbound["tag"] = "tun"
        let config: [String: Any] = [
            "log": ["disabled": true],
            "inbounds": [inbound],
            "outbounds": [["type": "direct", "tag": "direct"]],
            "route": ["final": "direct"]
        ]
        let options = MobileStartOptions()
        options.coreConfig = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let capture = SettingsCapturePlatform()
        let platform = try XCTUnwrap(MobileNewApplePlatform(capture))
        error = nil
        let created = MobileNewInstance(platform, options, &error)
        if let error = error { throw error }
        let instance = try XCTUnwrap(created)
        defer { try? instance.close() }
        XCTAssertThrowsError(try instance.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("settings captured; no TUN opened"),
                          error.localizedDescription)
        }
        XCTAssertEqual(capture.network.snapshot.monitorCloses, 1)
        return try XCTUnwrap(capture.settings)
    }
}

private final class SettingsCapturePlatform: NSObject, MobileApplePlatformInterfaceProtocol {
    let network = SmokePlatform()
    var settings: NEPacketTunnelNetworkSettings?

    func underNetworkExtension() -> Bool { true }
    func networkExtensionIncludeAllNetworks() -> Bool { false }
    func openTun(_ options: MobileTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        settings = try ThroneNetworkSettings.make(XCTUnwrap(options))
        throw smokeError("settings captured; no TUN opened")
    }
    func startDefaultInterfaceMonitor(_ listener: MobileInterfaceUpdateListenerProtocol?) throws {
        try network.startDefaultInterfaceMonitor(listener)
    }
    func closeDefaultInterfaceMonitor(_ listener: MobileInterfaceUpdateListenerProtocol?) throws {
        try network.closeDefaultInterfaceMonitor(listener)
    }
    func getInterfaces() throws -> MobileNetworkInterfaceIteratorProtocol {
        try network.getInterfaces()
    }
}
