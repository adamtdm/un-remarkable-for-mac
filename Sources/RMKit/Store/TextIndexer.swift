import Foundation
import PDFKit

/// Fills the FTS5 body column. Notebooks are indexed from their typed text (small `.rm` downloads);
/// PDFs only once their payload is already cached, so indexing never pulls gigabytes of books.
public actor TextIndexer {
    let sync: SyncEngine
    let db: LibraryDatabase
    let blobs: BlobStore

    public init(sync: SyncEngine) {
        self.sync = sync
        self.db = sync.db
        self.blobs = sync.blobs
    }

    /// Indexes every document whose text is stale. Returns the number indexed.
    @discardableResult
    public func indexAll(progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> Int {
        let stale = db.allDocuments().filter { !$0.isFolder && !$0.isTrashed && db.indexedHash($0.id) != $0.hash }
        var count = 0
        for (i, doc) in stale.enumerated() {
            if Task.isCancelled { break }
            if await index(doc) { count += 1 }
            progress(i + 1, stale.count)
        }
        return count
    }

    @discardableResult
    public func index(_ doc: DocumentItem) async -> Bool {
        var parts: [String] = []
        switch doc.kind {
        case .notebook:
            for i in 0..<doc.displayPageCount {
                guard let rm = doc.rmFile(for: i),
                      let data = try? await sync.blob(rm.hash, filename: rm.name),
                      let page = RmParser.parse(data) else { continue }
                let t = page.plainText
                if !t.isEmpty { parts.append(t) }
                if let handwriting = db.ocrText(rm.hash), !handwriting.isEmpty { parts.append(handwriting) }
            }
        case .pdf:
            guard let h = doc.payloadHash, blobs.has(h), let pdf = PDFDocument(url: blobs.url(for: h)) else { return false }
            parts.append(String((pdf.string ?? "").prefix(400_000)))
        case .epub, .folder:
            return false
        }
        db.setBody(parts.joined(separator: "\n"), for: doc)
        return true
    }
}
