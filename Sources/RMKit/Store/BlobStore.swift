import Foundation

/// Immutable content-addressed store: `blobs/<first two hex>/<sha256>`.
public final class BlobStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func url(for hash: String) -> URL {
        root.appending(path: String(hash.prefix(2)), directoryHint: .isDirectory).appending(path: hash)
    }

    public func has(_ hash: String) -> Bool { FileManager.default.fileExists(atPath: url(for: hash).path) }

    public func get(_ hash: String) -> Data? { try? Data(contentsOf: url(for: hash), options: .mappedIfSafe) }

    public func put(_ hash: String, data: Data) throws {
        let dest = url(for: hash)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
    }

    /// Total bytes on disk, for the storage panel in Settings.
    public func diskUsage() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
