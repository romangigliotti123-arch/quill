import Foundation

/// A stable name for "this Mac" on the Devices list on the Account screen —
/// not a hardware identifier, just enough to tell two Macs apart once the
/// same account is signed into both.
enum DeviceIdentity {

    static let fileURL: URL = QuillData.directory.appendingPathComponent("device.json")

    private struct Stored: Codable { let id: String }

    /// A Firestore field-path-safe key. The REST API's unquoted field path
    /// syntax must start with a letter or underscore, and a bare UUID (which
    /// can start with a digit) would need backtick-quoting every place
    /// `SyncEngine` reads or writes it — the "d" prefix sidesteps that
    /// everywhere, for free.
    static let id: String = {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            return stored.id
        }
        let fresh = "d" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if let data = try? JSONEncoder().encode(Stored(id: fresh)) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        return fresh
    }()

    /// Hostnames end in ".local" on every Mac on a home network — trimmed
    /// because nobody reading a device list needs to be told that.
    static var name: String {
        var host = ProcessInfo.processInfo.hostName
        if host.hasSuffix(".local") { host.removeLast(6) }
        return host.isEmpty ? "This Mac" : host
    }
}
