import Foundation

/// Secret storage for cloud tokens and AI API keys.
///
/// Stored in an owner-only (0600) JSON file in Application Support, like rmapi's `~/.rmapi` and
/// the web app's data directory. The macOS Keychain ties items to the app's code signature;
/// ad-hoc signed builds get a new signature on every rebuild and would prompt for access each time.
/// Once the app is signed with a Developer ID this can move back to the Keychain.
public enum Secrets {
    nonisolated(unsafe) public static var fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Unremarkable/secrets.json")
    private static let lock = NSLock()

    public static func get(_ key: String) -> String? {
        lock.withLock { read()[key] }
    }

    public static func set(_ value: String?, for key: String) {
        lock.withLock {
            var all = read()
            all[key] = (value?.isEmpty ?? true) ? nil : value
            write(all)
        }
    }

    private static func read() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func write(_ dict: [String: String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(dict) else { return }
        // Create with 0600 before writing so the secrets are never world-readable, even briefly.
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: fileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public struct AuthTokens: Codable, Sendable, Equatable {
    public var deviceToken = ""
    public var userToken = ""
    public var deviceID = ""
    public init(deviceToken: String = "", userToken: String = "", deviceID: String = "") {
        self.deviceToken = deviceToken
        self.userToken = userToken
        self.deviceID = deviceID
    }
}

public protocol TokenStorage: Sendable {
    func load() -> AuthTokens
    func save(_ tokens: AuthTokens)
    func clear()
}

public struct SecretsTokenStorage: TokenStorage {
    private let key = "remarkable-cloud-tokens"
    public init() {}
    public func load() -> AuthTokens {
        guard let s = Secrets.get(key), let t = try? JSONDecoder().decode(AuthTokens.self, from: Data(s.utf8)) else {
            return AuthTokens()
        }
        return t
    }
    public func save(_ tokens: AuthTokens) {
        guard let d = try? JSONEncoder().encode(tokens) else { return }
        Secrets.set(String(decoding: d, as: UTF8.self), for: key)
    }
    public func clear() { Secrets.set(nil, for: key) }
}

public final class InMemoryTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens
    public init(_ tokens: AuthTokens = AuthTokens()) { self.tokens = tokens }
    public func load() -> AuthTokens { lock.withLock { tokens } }
    public func save(_ t: AuthTokens) { lock.withLock { tokens = t } }
    public func clear() { lock.withLock { tokens = AuthTokens() } }
}
