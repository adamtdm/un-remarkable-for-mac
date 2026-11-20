import Foundation

public struct RootInfo: Sendable, Equatable {
    public var hash: String
    public var generation: Int64
    public var schemaVersion: String
}

/// HTTP client for the reMarkable sync15 cloud (`internal.cloud.remarkable.com`).
public final class CloudClient: Sendable {
    public static let syncHost = URL(string: "https://internal.cloud.remarkable.com")!
    public static let userAgent = "rmapi/0.0.32-unremarkable-macos"

    public let auth: AuthManager
    private let session: URLSession

    public init(auth: AuthManager, session: URLSession = CloudClient.makeSession()) {
        self.auth = auth
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }

    // MARK: Root

    public func root() async throws -> RootInfo {
        let data = try await send(path: "sync/v4/root")
        guard let obj = jsonObject(data), let hash = obj["hash"] as? String else {
            throw RMError.malformed("Unexpected root response")
        }
        let gen = (obj["generation"] as? NSNumber)?.int64Value ?? 0
        let schema = (obj["schemaVersion"] as? NSNumber)?.stringValue ?? (obj["schemaVersion"] as? String) ?? "4"
        return RootInfo(hash: hash, generation: gen, schemaVersion: schema)
    }

    /// Publishes a new root. Fails with 412 if `generation` is stale (someone else synced first).
    public func updateRoot(hash: String, generation: Int64, broadcast: Bool = true) async throws -> Int64 {
        let body = try JSONSerialization.data(withJSONObject: ["broadcast": broadcast, "hash": hash, "generation": generation])
        let data = try await send(path: "sync/v3/root", method: "PUT", body: body,
                                  headers: ["rm-filename": "roothash", "Content-Type": "application/json"])
        return (jsonObject(data)?["generation"] as? NSNumber)?.int64Value ?? generation + 1
    }

    // MARK: Blobs

    public func blob(_ hash: String, filename: String = "") async throws -> Data {
        do {
            return try await send(path: "sync/v3/files/\(hash)", headers: filename.isEmpty ? [:] : ["rm-filename": filename])
        } catch RMError.http(404, _) {
            throw RMError.blobNotFound(hash)
        }
    }

    public func putBlob(_ hash: String, data: Data, filename: String, contentType: String = "application/octet-stream") async throws {
        _ = try await send(path: "sync/v3/files/\(hash)", method: "PUT", body: data, headers: [
            "Content-Type": contentType,
            "rm-filename": filename,
            "x-goog-hash": "crc32c=\(CRC32C.base64(data))",
        ])
    }

    /// Simple upload endpoint used by the official web library for PDFs and EPUBs.
    /// Uploads a PDF or EPUB and returns the new document's ID when the server reports it.
    @discardableResult
    public func uploadDocument(_ data: Data, filename: String, parentID: String = "") async throws -> String? {
        let meta = try JSONSerialization.data(withJSONObject: ["file_name": filename, "parent": parentID])
        let isEpub = filename.lowercased().hasSuffix(".epub")
        let response = try await send(path: "doc/v2/files", method: "POST", body: data, headers: [
            "rm-source": "WebLibrary",
            "rm-meta": meta.base64EncodedString(),
            "Content-Type": isEpub ? "application/epub+zip" : "application/pdf",
        ])
        return jsonObject(response)?["docID"] as? String
    }

    // MARK: Transport

    /// Authenticated request with one token refresh on 401 and exponential backoff on 429/5xx.
    func send(path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        var refreshed = false
        var backoff: UInt64 = 1_000_000_000
        for attempt in 1...4 {
            var req = URLRequest(url: Self.syncHost.appending(path: path))
            req.httpMethod = method
            req.httpBody = body
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("Bearer \(try await auth.validUserToken())", forHTTPHeaderField: "Authorization")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if status == 401, !refreshed {
                refreshed = true
                try await auth.refreshUserToken()
                continue
            }
            if (status == 429 || (500...504).contains(status)), attempt < 4 {
                var wait = backoff
                if let ra = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), let s = Double(ra), s > 0 {
                    wait = UInt64(min(max(s, 1), 30) * 1_000_000_000)
                }
                try await Task.sleep(nanoseconds: wait)
                backoff = min(backoff * 2, 16_000_000_000)
                continue
            }
            throw RMError.http(status, String(decoding: data.prefix(400), as: UTF8.self))
        }
        throw RMError.http(0, "Retries exhausted")
    }
}

/// CRC-32C (Castagnoli), required by the blob PUT endpoint as `x-goog-hash`.
enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x82F6_3B78 : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// Big-endian bytes, base64 encoded (Google Cloud Storage convention).
    static func base64(_ data: Data) -> String {
        let c = checksum(data).bigEndian
        return withUnsafeBytes(of: c) { Data($0) }.base64EncodedString()
    }
}
