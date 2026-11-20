import Foundation
import Testing
@testable import RMKit

/// Reads (never writes) one handwritten page from the real library and converts it with reMarkable's service.
/// Off unless RMKIT_LIVE_CONVERT=1. Uses a copy of the app's library index and its blob cache.
@Suite("live handwriting conversion", .enabled(if: ProcessInfo.processInfo.environment["RMKIT_LIVE_CONVERT"] == "1"))
struct LiveConversionTests {
    @Test func convertsARealPage() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Unremarkable")
        let tmp = FileManager.default.temporaryDirectory.appending(path: "conv-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for f in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
            try? FileManager.default.copyItem(at: support.appending(path: f), to: tmp.appending(path: f))
        }
        let engine = SyncEngine(client: CloudClient(auth: AuthManager()), blobs: BlobStore(root: support.appending(path: "blobs")),
                                db: try LibraryDatabase(url: tmp.appending(path: "library.sqlite")))
        let notebooks = engine.db.allDocuments().filter { $0.kind == .notebook && !$0.isTrashed }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        var tried = 0
        for nb in notebooks.prefix(40) {
            for i in 0..<min(nb.pageCount, 3) {
                guard let f = nb.rmFile(for: i), let page = RmParser.parse(try await engine.blob(f.hash, filename: f.name)) else { continue }
                let n = HandwritingConversion.strokes(page).count
                guard n > 40 else { continue }
                let started = Date()
                let text = try await engine.client.convertHandwriting(page, language: ProcessInfo.processInfo.environment["RMKIT_LANG"] ?? "en_GB")
                print("LIVE \(nb.name) p\(i + 1): \(n) strokes, \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n---\n\(text)\n---")
                #expect(!text.isEmpty)
                tried += 1
                if tried >= 2 { return }
            }
        }
        #expect(tried > 0, "no handwritten page found")
    }
}
