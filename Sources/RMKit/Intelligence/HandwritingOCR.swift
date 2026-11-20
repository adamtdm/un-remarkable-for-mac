import CoreGraphics
import Foundation

/// Transcribes handwritten notebook pages so they're searchable and Ask can read them: with reMarkable's own
/// handwriting conversion (default, no AI needed) or a vision model (the web app's OCR). Each page version
/// (its `.rm` hash) is read once; newest notebooks first.
public actor HandwritingOCR {
    public let sync: SyncEngine
    private var db: LibraryDatabase { sync.db }

    public init(sync: SyncEngine) { self.sync = sync }

    public static let prompt = """
    Transcribe all handwritten text on this reMarkable notebook page exactly as written, in reading order. \
    Keep line breaks between lines and paragraphs. Ignore typed text, page templates, ruled lines and drawings. \
    Output only the plain text, with no commentary or Markdown. If there is no handwriting, output nothing.
    """

    public struct Result: Sendable {
        public var pagesRead = 0
        public var documents: [String] = []
        public var remaining = 0
    }

    public enum Reader: Sendable {
        /// reMarkable's cloud conversion (MyScript), in a tablet language code such as "en_GB".
        case remarkable(language: String)
        case vision(AIProvider)
    }

    /// Reads up to `maxPages` untranscribed pages with ink. Returns the documents whose text changed.
    public func run(reader: Reader, skip: Set<String>, maxPages: Int = 20,
                    progress: @Sendable (String) -> Void = { _ in }) async -> Result {
        var result = Result()
        let docs = db.allDocuments()
            .filter { !$0.isTrashed && $0.kind == .notebook && !skip.contains($0.id) }
            .sorted { $0.lastModified > $1.lastModified }
        for doc in docs {
            var changed = false
            for i in 0..<doc.displayPageCount {
                guard let rm = doc.rmFile(for: i), db.ocrText(rm.hash) == nil else { continue }
                guard result.pagesRead < maxPages else { result.remaining += 1; continue }
                guard let data = try? await sync.blob(rm.hash, filename: rm.name), let page = RmParser.parse(data) else { continue }
                guard HandwritingConversion.hasHandwriting(page) else {
                    db.setOCRText("", for: rm.hash) // typed only: nothing to read
                    continue
                }
                progress("Reading handwriting in \(doc.name), page \(i + 1)…")
                guard let text = await read(page, with: reader) else { continue }
                db.setOCRText(text, for: rm.hash)
                result.pagesRead += 1
                changed = true
            }
            if changed { result.documents.append(doc.id) }
        }
        return result
    }

    private func read(_ page: RmPage, with reader: Reader) async -> String? {
        switch reader {
        case .remarkable(let language):
            return try? await sync.client.convertHandwriting(page, language: language)
        case .vision(let vision):
            guard let png = TaskScanner.png(PageRenderer.renderNotebook(page, options: RenderOptions(dark: false, pixelWidth: 1100))),
                  let reply = try? await vision.complete(prompt: Self.prompt, system: "You are an expert handwriting OCR reader.",
                                                         images: [png], timeout: 90) else { return nil }
            return Self.clean(reply)
        }
    }

    /// Strips code fences and "no handwriting" chatter some models add.
    static func clean(_ reply: String) -> String {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^\(?(no|there is no) handwrit"#, options: [.regularExpression, .caseInsensitive]) != nil, t.count < 80 { return "" }
        return t
    }
}
