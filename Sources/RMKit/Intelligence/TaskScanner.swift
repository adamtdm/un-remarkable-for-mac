import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finds tasks in the library, page by page. Each version of a page (identified by its `.rm` hash) is
/// scanned once, so after the first run only pages changed on the tablet are read again.
public actor TaskScanner {
    public let sync: SyncEngine
    private var db: LibraryDatabase { sync.db }

    public init(sync: SyncEngine) { self.sync = sync }

    public struct Result: Sendable {
        public var pagesScanned = 0
        public var handwritingPages = 0
        public var found = 0
    }

    /// - Parameters:
    ///   - handwriting: how to read handwritten `*` tasks: reMarkable's conversion or a vision model (nil to skip).
    ///   - skip: documents never to mine (the Tasks notebook itself).
    ///   - handwritingSince: only OCR documents modified after this (keeps the first run cheap).
    ///   - maxHandwritingPages: OCR budget for one scan.
    public func scan(handwriting: HandwritingOCR.Reader?, skip: Set<String>, handwritingSince: Date,
                     maxHandwritingPages: Int = 20, progress: @Sendable (String) -> Void = { _ in }) async -> Result {
        var result = Result()
        let docs = db.allDocuments().filter { !$0.isTrashed && !$0.isFolder && !skip.contains($0.id) && $0.kind != .epub }
        for doc in docs {
            for (index, page) in doc.pages.enumerated() {
                guard let rm = doc.rmFile(for: index) else { continue }
                _ = page
                let typedKey = "typed:\(rm.hash)"
                let visionKey = "vision:\(rm.hash)"
                let wantTyped = !db.wasScanned(typedKey)
                let wantVision = handwriting != nil && result.handwritingPages < maxHandwritingPages
                    && doc.lastModified >= handwritingSince && !db.wasScanned(visionKey)
                guard wantTyped || wantVision else { continue }
                guard let data = try? await sync.blob(rm.hash, filename: rm.name), let parsed = RmParser.parse(data) else {
                    db.markScanned([typedKey, visionKey])
                    continue
                }
                if wantTyped {
                    let found = TaskExtractor.extract(from: TaskExtractor.text(of: parsed), bulletAware: true)
                    replaceTyped(doc: doc, page: index, with: found)
                    result.found += found.count
                    result.pagesScanned += 1
                    db.markScanned([typedKey])
                }
                let hasInk = HandwritingConversion.hasHandwriting(parsed)
                if wantVision, let handwriting, hasInk {
                    progress("Reading handwriting in \(doc.name), page \(index + 1)…")
                    if let found = await handwrittenTasks(parsed, hash: rm.hash, reader: handwriting) {
                        db.mergeTasks(found.map { TaskItem(text: $0.text, source: .handwriting, docID: doc.id, docName: doc.name,
                                                           pageIndex: index, done: $0.done) })
                        result.found += found.count
                        db.markScanned([visionKey])
                    }
                    result.handwritingPages += 1
                } else if wantVision {
                    db.markScanned([visionKey])
                }
            }
        }
        return result
    }

    private func handwrittenTasks(_ page: RmPage, hash: String, reader: HandwritingOCR.Reader) async -> [TaskExtractor.Found]? {
        switch reader {
        case .remarkable(let language):
            let text: String
            if let cached = db.ocrText(hash) {
                text = cached
            } else {
                guard let converted = try? await sync.client.convertHandwriting(page, language: language) else { return nil }
                db.setOCRText(converted, for: hash)
                text = converted
            }
            // Conversion can't see strike-throughs: tasks are completed by ticking them in the Tasks notebook.
            return TaskExtractor.extract(from: text)
        case .vision(let vision):
            guard let png = Self.png(PageRenderer.renderNotebook(page, options: RenderOptions(dark: false, pixelWidth: 1100))),
                  let reply = try? await vision.complete(prompt: TaskExtractor.visionPrompt,
                                                         system: "You are an expert handwriting OCR reader. Always output raw JSON only.",
                                                         images: [png], timeout: 90) else { return nil }
            return TaskExtractor.parseVision(reply)
        }
    }

    /// Typed tasks mirror the page: new ones are added, ticked ones completed, deleted ones removed.
    private func replaceTyped(doc: DocumentItem, page: Int, with found: [TaskExtractor.Found]) {
        let items = found.map { TaskItem(text: $0.text, source: .typed, docID: doc.id, docName: doc.name, pageIndex: page, done: $0.done) }
        let keep = Set(items.map(\.fingerprint))
        for old in db.allTasks() where old.source == .typed && old.docID == doc.id && old.pageIndex == page && !keep.contains(old.fingerprint) {
            db.deleteTask(old.id)
        }
        db.mergeTasks(items)
    }

    static func png(_ image: CGImage?) -> Data? {
        guard let image else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
