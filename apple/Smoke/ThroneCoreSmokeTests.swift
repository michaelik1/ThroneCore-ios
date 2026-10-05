import Foundation
import ThroneCore
import XCTest

/// This hostless simulator suite checks the Swift/Go boundary and a non-TUN runtime.
/// It does not test NetworkExtension, packetFlow, a device VPN, or proxy traffic.
final class ThroneCoreSmokeTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThroneCoreSmoke-\(UUID().uuidString)", isDirectory: true)

        let options = MobileSetupOptions()
        options.basePath = temporaryRoot.appendingPathComponent("base").path
        options.workingPath = temporaryRoot.appendingPathComponent("working").path
        options.tempPath = temporaryRoot.appendingPathComponent("temp").path
        options.logMaxLines = 100

        // These are C functions, so their NSError arguments are not Swift throws.
        var error: NSError?
        guard MobileSetup(options, &error) else {
            throw error ?? smokeError("MobileSetup failed without an NSError")
        }
        XCTAssertNil(error)
        for path in [options.basePath, options.workingPath, options.tempPath] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    override func tearDownWithError() throws {
        if let root = temporaryRoot, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        temporaryRoot = nil
        try super.tearDownWithError()
    }

    func testVersionBindings() {
        let core = MobileVersion()
        let xray = MobileXrayVersion()
        let go = MobileGoVersion()
        print("ThroneCore: \(core); Xray: \(xray); Go: \(go)")
        XCTAssertFalse(core.isEmpty)
        XCTAssertFalse(xray.isEmpty)
        XCTAssertTrue(go.hasPrefix("go"), go)
        XCTAssertTrue(go.contains(", ios/"), "Expected an iOS Go runtime: \(go)")
    }

    func testEagerXrayConstructionReportsNSError() {
        let platform = SmokePlatform()
        let options = startOptions()
        options.xrayConfig = "{invalid JSON"

        var error: NSError?
        let instance = MobileNewInstance(platform, options, &error)
        defer { try? instance?.close() }
        XCTAssertNil(instance, "Invalid eager Xray configuration must fail during NewInstance")
        XCTAssertNotNil(error, "The Go error must cross the C/Swift NSError boundary")
        XCTAssertFalse(error?.localizedDescription.isEmpty ?? true)
        XCTAssertEqual(platform.snapshot.monitorStarts, 0)
        XCTAssertEqual(platform.snapshot.tunOpens, 0)
    }

    func testNonTUNStartCloseAndReconnect() throws {
        let platform = SmokePlatform()

        // Setup and the Xray protector are process-global. The shared scheme and
        // runner disable parallel testing; each old instance closes before the next.
        for cycle in 1...3 {
            var error: NSError?
            let instance = MobileNewInstance(platform, startOptions(), &error)
            if let error = error { throw error }
            let core = try XCTUnwrap(instance, "NewInstance returned neither an instance nor an error")
            defer { try? core.close() }

            // needXray=true and xrayLazyStart=false initialize and start embedded
            // Xray during NewInstance. This config needs no external assets/network.
            try core.start()
            XCTAssertNil(core.localDNSFailure())
            XCTAssertThrowsError(try core.start(), "Starting the same instance twice must fail")
            XCTAssertEqual(platform.snapshot.monitorStarts, cycle)
            XCTAssertTrue(platform.snapshot.hasMonitor)

            try core.close()
            try core.close() // Close is intentionally idempotent.
            XCTAssertThrowsError(try core.start(), "A closed instance must not restart")
            XCTAssertEqual(platform.snapshot.monitorCloses, cycle)
            XCTAssertFalse(platform.snapshot.hasMonitor)
            XCTAssertEqual(platform.snapshot.tunOpens, 0, "This is a non-VPN smoke test")
            XCTAssertGreaterThan(platform.snapshot.interfaceReads, 0)
        }
    }

    func testBundledDirectConfigurationStartsAndClosesWithoutTUN() throws {
        let options = MobileStartOptions()
        options.coreConfig = try encodedConfiguration(exampleCoreConfiguration("sing-box-direct"))
        options.needXray = false
        try assertExampleStartsAndCloses(options)
    }

    func testEmptyDirectDNSDetourFailsDuringStart() throws {
        var configuration = try exampleCoreConfiguration("sing-box-direct")
        var dns = try XCTUnwrap(configuration["dns"] as? [String: Any])
        var servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let index = try XCTUnwrap(servers.firstIndex { $0["tag"] as? String == "example-dns" })
        // Reintroduce the shipped defect into the actual sample. Construction
        // accepts it; HTTPS DNS initializes this invalid detour only during Start.
        servers[index]["detour"] = "direct"
        dns["servers"] = servers
        configuration["dns"] = dns
        let options = MobileStartOptions()
        options.coreConfig = try encodedConfiguration(configuration)
        options.needXray = false

        let platform = SmokePlatform()
        var error: NSError?
        let instance = MobileNewInstance(platform, options, &error)
        defer { try? instance?.close() }
        if let error = error { throw error }
        let core = try XCTUnwrap(instance, "The invalid detour should survive construction")
        XCTAssertThrowsError(try core.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("detour to an empty direct outbound makes no sense"),
                          "Unexpected startup error: \(error.localizedDescription)")
        }
        try core.close()
        XCTAssertEqual(platform.snapshot.tunOpens, 0)
        XCTAssertEqual(platform.snapshot.monitorStarts, platform.snapshot.monitorCloses)
        XCTAssertFalse(platform.snapshot.hasMonitor, "A failed Start must release the interface monitor")
    }

    func testBundledXrayConfigurationStartsAndClosesWithoutTUN() throws {
        let options = MobileStartOptions()
        options.coreConfig = try encodedConfiguration(exampleCoreConfiguration("sing-box-xray"))
        options.needXray = true
        options.xrayLazyStart = false
        options.xrayConfig = try String(contentsOf: exampleResource("xray-loopback"), encoding: .utf8)
        try assertExampleStartsAndCloses(options)
    }

    private func assertExampleStartsAndCloses(_ options: MobileStartOptions) throws {
        let platform = SmokePlatform()
        // Exercise reconnect with the same sample, including reclaiming the
        // bundled Xray listener when present. No DNS request or remote dial occurs.
        for cycle in 1...2 {
            var error: NSError?
            let instance = MobileNewInstance(platform, options, &error)
            defer { try? instance?.close() }
            if let error = error { throw error }
            let core = try XCTUnwrap(instance, "NewInstance returned neither an instance nor an error")
            try core.start()
            XCTAssertNil(core.localDNSFailure())
            XCTAssertEqual(platform.snapshot.monitorStarts, cycle)
            XCTAssertTrue(platform.snapshot.hasMonitor)
            XCTAssertEqual(platform.snapshot.tunOpens, 0, "Example smoke tests must never request TUN")
            try core.close()
            XCTAssertEqual(platform.snapshot.monitorCloses, cycle)
            XCTAssertFalse(platform.snapshot.hasMonitor)
        }
    }

    private func exampleResource(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: ThroneCoreSmokeTests.self).url(forResource: name, withExtension: "json"),
                      "Missing bundled Example/Configs resource: \(name).json")
    }

    private func exampleCoreConfiguration(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: exampleResource(name))
        var configuration = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inbounds = try XCTUnwrap(configuration["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.filter { $0["type"] as? String == "tun" }.count, 1,
                       "Expected one TUN inbound in the device example")
        // Keep all DNS, outbound, routing, and other settings exactly as bundled.
        // Only NetworkExtension/TUN requires a physical-device test instead.
        configuration["inbounds"] = inbounds.filter { $0["type"] as? String != "tun" }
        return configuration
    }

    private func encodedConfiguration(_ configuration: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func startOptions() -> MobileStartOptions {
        let options = MobileStartOptions()
        options.coreConfig = """
        {"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
        """
        options.needXray = true
        options.xrayLazyStart = false
        options.xrayConfig = """
        {"log":{"loglevel":"warning"},"outbounds":[{"protocol":"freedom","tag":"direct","settings":{}}]}
        """
        return options
    }
}

func smokeError(_ message: String) -> NSError {
    NSError(domain: "ThroneCoreSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
