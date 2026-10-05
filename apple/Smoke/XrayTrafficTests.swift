import Darwin
import Foundation
import ThroneCore
import XCTest

/// Real TCP bytes cross sing-box and embedded Xray, entirely on loopback.
/// This does not exercise TUN, NetworkExtension, packetFlow, or a device VPN.
final class XrayTrafficTests: XCTestCase {
    func testLoopbackTrafficThroughSingBoxAndEagerXrayAfterReconnect() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThroneCoreTraffic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let setup = MobileSetupOptions()
        setup.basePath = root.appendingPathComponent("base").path
        setup.workingPath = root.appendingPathComponent("working").path
        setup.tempPath = root.appendingPathComponent("temp").path
        setup.logMaxLines = 100
        var setupError: NSError?
        guard MobileSetup(setup, &setupError) else {
            throw setupError ?? smokeError("Traffic test MobileSetup failed without an NSError")
        }
        if let error = setupError { throw error }

        let echo = try TrafficSocket.listener()
        defer { echo.close() }
        let echoPort = try echo.boundPort()

        // Let the kernel choose distinct available ports. Keep both reservations
        // open until selected, then release them for the actual core listeners.
        // A rare bind race fails with the port/configuration context, not retries.
        let singReservation = try TrafficSocket.listener()
        let xrayReservation = try TrafficSocket.listener()
        let singPort = try singReservation.boundPort()
        let xrayPort = try xrayReservation.boundPort()
        singReservation.close()
        xrayReservation.close()

        let platform = SmokePlatform()
        for cycle in 1...2 {
            let options = MobileStartOptions()
            options.coreConfig = """
            {
              "log": {"disabled": true},
              "inbounds": [{"type": "socks", "tag": "client", "listen": "127.0.0.1", "listen_port": \(singPort)}],
              "outbounds": [{"type": "socks", "tag": "xray", "server": "127.0.0.1", "server_port": \(xrayPort), "version": "5"}],
              "route": {"final": "xray", "auto_detect_interface": false}
            }
            """
            options.needXray = true
            options.xrayLazyStart = false
            options.xrayConfig = """
            {
              "log": {"loglevel": "warning"},
              "inbounds": [{"tag": "bridge", "listen": "127.0.0.1", "port": \(xrayPort), "protocol": "socks", "settings": {"auth": "noauth", "udp": false}}],
              "outbounds": [{"tag": "echo", "protocol": "freedom", "settings": {}}]
            }
            """

            var error: NSError?
            let instance = MobileNewInstance(platform, options, &error)
            // Close even if an unexpected binding result contains both values.
            defer { try? instance?.close() }
            if let error = error {
                throw smokeError("Cycle \(cycle): eager Xray on 127.0.0.1:\(xrayPort), NewInstance: \(error)")
            }
            let core = try XCTUnwrap(instance, "NewInstance returned neither an instance nor an error")
            do {
                try core.start()
            } catch {
                throw smokeError("Cycle \(cycle): sing-box on 127.0.0.1:\(singPort), start: \(error)")
            }

            try roundTrip(echo: echo, echoPort: echoPort, singPort: singPort, cycle: cycle)
            XCTAssertEqual(platform.snapshot.tunOpens, 0, "Loopback traffic must never request TUN")
            try core.close()
            XCTAssertEqual(platform.snapshot.monitorStarts, cycle)
            XCTAssertEqual(platform.snapshot.monitorCloses, cycle)
            XCTAssertFalse(platform.snapshot.hasMonitor)
            try assertListenerClosed(port: singPort)
            try assertListenerClosed(port: xrayPort)
            // The next instance must reclaim these same ports and carry new bytes.
        }
    }

    private func roundTrip(echo: TrafficSocket, echoPort: UInt16, singPort: UInt16, cycle: Int) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        let client = try TrafficSocket.connect(port: singPort, deadline: deadline)
        defer { client.close() }
        try client.writeAll([5, 1, 0], deadline: deadline) // SOCKS5, no authentication.
        let method = try client.readExactly(2, deadline: deadline)
        guard method == [5, 0] else { throw smokeError("Unexpected SOCKS method reply: \(method)") }
        try client.writeAll([5, 1, 0, 1, 127, 0, 0, 1, UInt8(echoPort >> 8), UInt8(echoPort & 0xff)],
                            deadline: deadline)
        let reply = try client.readExactly(4, deadline: deadline)
        guard reply[0] == 5, reply[1] == 0, reply[2] == 0 else {
            throw smokeError("SOCKS CONNECT through sing-box/Xray failed: \(reply)")
        }
        switch reply[3] {
        case 1: _ = try client.readExactly(6, deadline: deadline)
        case 4: _ = try client.readExactly(18, deadline: deadline)
        case 3:
            let length = try client.readExactly(1, deadline: deadline)[0]
            _ = try client.readExactly(Int(length) + 2, deadline: deadline)
        default: throw smokeError("Unexpected SOCKS address type: \(reply[3])")
        }

        let payload = Array("ThroneCore sing-box -> Xray -> echo, cycle \(cycle)".utf8) + [0, 255, 128, 1]
        try client.writeAll(payload, deadline: deadline)
        // TCP's listening backlog allows CONNECT to finish before accept. Serving
        // this tiny echo synchronously avoids unjoined background work on failure.
        let accepted = try echo.accept(deadline: deadline)
        defer { accepted.close() }
        let received = try accepted.readExactly(payload.count, deadline: deadline)
        XCTAssertEqual(received, payload, "Cycle \(cycle): echo server received different bytes")
        try accepted.writeAll(received, deadline: deadline)
        let returned = try client.readExactly(payload.count, deadline: deadline)
        XCTAssertEqual(returned, payload, "Cycle \(cycle): proxy round trip changed bytes")
    }

    private func assertListenerClosed(port: UInt16) throws {
        do {
            let unexpected = try TrafficSocket.connect(port: port, deadline: ProcessInfo.processInfo.systemUptime + 2)
            unexpected.close()
            XCTFail("Core close left a listener on 127.0.0.1:\(port)")
        } catch let error as NSError {
            // A timeout is a test failure, not evidence that the listener closed.
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain, error.localizedDescription)
            XCTAssertEqual(error.code, Int(ECONNREFUSED), error.localizedDescription)
        }
    }
}

/// Single-threaded, nonblocking sockets with a shared monotonic I/O deadline.
private final class TrafficSocket {
    private var fd: Int32

    private init(_ descriptor: Int32) throws {
        fd = descriptor
        do {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw Self.posixError("fcntl(O_NONBLOCK)")
            }
            var enabled: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Self.posixError("setsockopt(SO_NOSIGPIPE)")
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if fd >= 0 {
            _ = Darwin.close(fd)
            fd = -1
        }
    }

    private static func make() throws -> TrafficSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        return try TrafficSocket(fd)
    }

    static func listener() throws -> TrafficSocket {
        let socket = try make()
        var address = loopbackAddress(port: 0)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw posixError("bind(127.0.0.1:0)") }
        guard Darwin.listen(socket.fd, 1) == 0 else { throw posixError("listen") }
        return socket
    }

    func boundPort() throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw Self.posixError("getsockname") }
        return UInt16(bigEndian: address.sin_port)
    }

    static func connect(port: UInt16, deadline: TimeInterval) throws -> TrafficSocket {
        let socket = try make()
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw posixError("connect(127.0.0.1:\(port))") }
            try socket.wait(for: Int16(POLLOUT), deadline: deadline)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket.fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                throw posixError("getsockopt(SO_ERROR)")
            }
            guard socketError == 0 else {
                throw posixError("connect(127.0.0.1:\(port))", code: socketError)
            }
        }
        return socket
    }

    func accept(deadline: TimeInterval) throws -> TrafficSocket {
        while true {
            try wait(for: Int16(POLLIN), deadline: deadline)
            let accepted = Darwin.accept(fd, nil, nil)
            if accepted >= 0 { return try TrafficSocket(accepted) }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw Self.posixError("accept echo connection")
        }
    }

    func writeAll(_ bytes: [UInt8], deadline: TimeInterval) throws {
        var offset = 0
        while offset < bytes.count {
            try wait(for: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count > 0 { offset += count; continue }
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            if count == 0 { throw smokeError("send made no progress") }
            throw Self.posixError("send")
        }
    }

    func readExactly(_ count: Int, deadline: TimeInterval) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try wait(for: Int16(POLLIN), deadline: deadline)
            let received = bytes.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received > 0 { offset += received; continue }
            if received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            if received == 0 { throw smokeError("Unexpected EOF after \(offset)/\(count) bytes") }
            throw Self.posixError("recv")
        }
        return bytes
    }

    private func wait(for events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw smokeError("Loopback socket I/O exceeded its deadline") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(ceil(remaining * 1_000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw Self.posixError("poll") }
            if result == 0 { throw smokeError("Loopback socket I/O timed out") }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                throw smokeError("poll reported an invalid socket")
            }
            // HUP/ERR are consumed by recv/send or SO_ERROR with better diagnostics.
            return
        }
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        return address
    }

    private static func posixError(_ operation: String, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code))) (errno \(code))"])
    }
}
