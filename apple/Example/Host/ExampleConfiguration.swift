import Foundation

enum ExampleMode: String, CaseIterable, Identifiable {
    case direct
    case xray
    var id: String { rawValue }
    var title: String { self == .direct ? "sing-box direct" : "sing-box through Xray" }

    func providerConfiguration(owner: String) throws -> [String: Any] {
        var configuration: [String: Any] = [
            "exampleOwner": owner,
            "schemaVersion": 1,
            "mode": rawValue,
            "coreConfig": try read(self == .direct ? "sing-box-direct" : "sing-box-xray"),
            "needXray": self == .xray
        ]
        if self == .xray { configuration["xrayConfig"] = try read("xray-loopback") }
        return configuration
    }

    private func read(_ name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw NSError(domain: "ThroneCoreExample", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing sample configuration: \(name)"])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
