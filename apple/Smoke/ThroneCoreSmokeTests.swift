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
