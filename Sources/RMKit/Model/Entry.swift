import CryptoKit
import Foundation

/// One line of a sync15 `.docSchema` index: `hash:type:id:subfiles:size`.
public struct Entry: Hashable, Sendable {
    public static let schemaV3 = "3"
    public static let schemaV4 = "4"
    public static let docType = "80000000"
    public static let fileType = "0"

    public var hash: String
    public var type: String
    public var id: String
    public var subfiles: Int
    public var size: Int64

    public init(hash: String, type: String, id: String, subfiles: Int, size: Int64) {
        self.hash = hash
        self.type = type
        self.id = id
        self.subfiles = subfiles
        self.size = size
    }

    public var isDocument: Bool { type == Entry.docType || subfiles > 0 }

    public var line: String { "\(hash):\(type):\(id):\(subfiles):\(size)" }

    public static func parse(line: String) throws -> Entry {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, let sub = Int(parts[3]), let size = Int64(parts[4]) else {
            throw RMError.malformed("Invalid index entry line: '\(line)'")
        }
        return Entry(hash: String(parts[0]), type: String(parts[1]), id: String(parts[2]), subfiles: sub, size: size)
    }
}

public enum IndexParser {
    /// Parses a root or document `.docSchema` blob. Returns the entries and schema version.
    public static func parse(_ data: Data) throws -> (entries: [Entry], schema: String) {
        guard let text = String(data: data, encoding: .utf8) else { throw RMError.malformed("Index is not UTF-8") }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let schema = lines.first else { throw RMError.malformed("Empty index") }
        let start: Int
        switch schema {
        case Entry.schemaV4: start = 2 // line 1 is the "0:<owner>:<count>:<size>" summary
        case Entry.schemaV3: start = 1
        default: throw RMError.malformed("Unsupported index schema \(schema)")
        }
        let entries = try lines.dropFirst(start).map { try Entry.parse(line: $0) }
        return (entries, schema)
    }

    /// Serialises an index. In schema 4 the summary line names its owner: "." for the root, the doc UUID otherwise.
    public static func format(_ entries: [Entry], schema: String = Entry.schemaV4, owner: String = ".") -> Data {
        let sorted = entries.sorted { $0.id < $1.id }
        var out = schema + "\n"
        if schema == Entry.schemaV4 {
            out += "0:\(owner):\(sorted.count):\(sorted.reduce(0) { $0 + $1.size })\n"
        }
        for e in sorted { out += e.line + "\n" }
        return Data(out.utf8)
    }

    /// Builds a document `.docSchema` and the hash it must be stored under.
    /// Schema 4: sha256 of the bytes. Schema 3: sha256 over the concatenated raw subfile hashes.
    public static func buildDocSchema(_ entries: [Entry], schema: String, docID: String) -> (data: Data, hash: String) {
        let data = format(entries, schema: schema, owner: docID)
        if schema == Entry.schemaV4 { return (data, sha256Hex(data)) }
        return (data, hashOfHashes(entries))
    }

    public static func hashOfHashes(_ entries: [Entry]) -> String {
        var hasher = SHA256()
        for e in entries.sorted(by: { $0.id < $1.id }) {
            hasher.update(data: Data(hexString: e.hash) ?? Data())
        }
        return hasher.finalize().hexString
    }
}

public func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).hexString }

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self.init(bytes)
    }
}

public enum RMError: LocalizedError, Sendable {
    case malformed(String)
    case notPaired
    case auth(String)
    case http(Int, String)
    case blobNotFound(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let m): return m
        case .notPaired: return "This Mac is not paired with a reMarkable account yet."
        case .auth(let m): return m
        case .http(let code, let m): return "Cloud request failed (\(code)): \(m)"
        case .blobNotFound(let h): return "File \(h.prefix(12))… is missing from the cloud."
        case .notFound(let m): return m
        }
    }
}
