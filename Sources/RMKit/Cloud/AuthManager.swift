import Foundation

/// Pairs this Mac with a reMarkable account and keeps a fresh user token.
///
/// Flow: one-time code from my.remarkable.com/device/desktop/connect → permanent device token →
/// short-lived user token (JWT) refreshed on demand.
public actor AuthManager {
    public static let authHost = URL(string: "https://webapp-prod.cloud.remarkable.engineering")!
    public static let deviceDesc = "desktop-macos"
    public static let pairingURL = URL(string: "https://my.remarkable.com/device/desktop/connect")!

    private let storage: TokenStorage
    private let session: URLSession
    private var tokens: AuthTokens
    private var refreshTask: Task<String, Error>?

    public init(storage: TokenStorage = SecretsTokenStorage(), session: URLSession = .shared) {
        self.storage = storage
        self.session = session
        var t = storage.load()
        if t.deviceID.isEmpty {
            t.deviceID = UUID().uuidString.lowercased()
            storage.save(t)
        }
        self.tokens = t
    }

    public var isPaired: Bool { !tokens.deviceToken.isEmpty }

    public func unpair() {
        storage.clear()
        tokens = AuthTokens(deviceID: UUID().uuidString.lowercased())
        storage.save(tokens)
    }

    /// Registers this Mac using the 8-character code shown on my.remarkable.com.
    public func pair(code rawCode: String) async throws {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code.count == 8 else { throw RMError.auth("The one-time code must be 8 characters.") }

        var req = URLRequest(url: Self.authHost.appending(path: "token/json/2/device/new"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(CloudClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "deviceDesc": Self.deviceDesc, "deviceID": tokens.deviceID,
        ])
        let (data, resp) = try await session.data(for: req)
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !body.isEmpty else {
            throw RMError.auth("Pairing failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)): \(body.isEmpty ? "check the code and try again" : body)")
        }
        tokens.deviceToken = body
        tokens.userToken = ""
        storage.save(tokens)
        _ = try await refreshUserToken()
    }

    /// Returns a user token that is valid for at least two more minutes.
    public func validUserToken() async throws -> String {
        if !tokens.userToken.isEmpty, !Self.isExpired(tokens.userToken) { return tokens.userToken }
        return try await refreshUserToken()
    }

    @discardableResult
    public func refreshUserToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        guard !tokens.deviceToken.isEmpty else { throw RMError.notPaired }
        let deviceToken = tokens.deviceToken
        let session = self.session
        let task = Task<String, Error> {
            var req = URLRequest(url: Self.authHost.appending(path: "token/json/2/user/new"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
            req.setValue(CloudClient.userAgent, forHTTPHeaderField: "User-Agent")
            req.httpBody = Data()
            let (data, resp) = try await session.data(for: req)
            let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, !body.isEmpty else {
                throw RMError.auth("Session refresh failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)): \(body)")
            }
            return body
        }
        refreshTask = task
        defer { refreshTask = nil }
        let token = try await task.value
        tokens.userToken = token
        storage.save(tokens)
        return token
    }

    /// True when the JWT `exp` claim is within two minutes. Non-JWT tokens are treated as valid.
    static func isExpired(_ jwt: String, now: Date = .now) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let obj = jsonObject(data),
              let exp = (obj["exp"] as? Double) ?? (obj["exp"] as? Int).map(Double.init) else { return false }
        return now.timeIntervalSince1970 >= exp - 120
    }
}
