import Foundation
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answers questions from your notes: finds relevant pages, then asks the AI to answer only from them,
/// citing which ones it used.
public actor NotesQA {
    public struct Passage: Sendable, Equatable, Identifiable {
        public var id: String { "\(docID)#\(page)" }
        public let docID: String
        public let docName: String
        public let page: Int
        public let text: String
    }

    public struct Answer: Sendable, Equatable {
        public let text: String
        /// The passages the answer drew on (cited), most relevant first.
        public let sources: [Passage]
        /// Everything that was considered, for "show all sources".
        public let considered: [Passage]
    }

    let sync: SyncEngine
    public init(sync: SyncEngine) { self.sync = sync }

    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "what", "who", "how", "why", "when", "where", "which", "does", "did",
        "can", "could", "would", "should", "about", "with", "from", "that", "this", "there", "their", "have", "has",
        "had", "you", "your", "our", "into", "any", "all", "tell", "explain", "give", "list", "show", "find", "notes",
        "note", "is", "a", "an", "of", "to", "in", "on", "do", "i", "me", "my", "we", "it", "be", "as", "at", "or",
    ]

    public static func keywords(_ question: String) -> [String] {
        var seen = Set<String>()
        return question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    // MARK: Retrieval

    /// The best passages for a question, within roughly `budget` characters.
    public func retrieve(_ question: String, documents: [DocumentItem], excluded: Set<String>, budget: Int) async -> [Passage] {
        let words = Self.keywords(question)
        guard !words.isEmpty else { return [] }
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var candidates = sync.db.searchAny(words, limit: 12).compactMap { byID[$0] }
        // Title matches first: a "Business Model Workbook" answers "what is a business model?"
        let titled = documents.filter { d in
            !d.isFolder && words.contains { d.name.lowercased().contains($0) }
        }.sorted { a, b in Self.hits(a.name, words) > Self.hits(b.name, words) }
        candidates = Array((titled.prefix(4) + candidates).reduce(into: [DocumentItem]()) { acc, d in
            if !acc.contains(where: { $0.id == d.id }) { acc.append(d) }
        }.filter { !$0.isTrashed && !excluded.contains($0.id) && $0.kind != .epub && !$0.isFolder }.prefix(6))

        var passages: [(Passage, Int)] = []
        for doc in candidates {
            for (page, text) in await pageTexts(doc) {
                let score = Self.hits(text, words)
                guard score > 0 else { continue }
                passages.append((Passage(docID: doc.id, docName: doc.name, page: page, text: Self.excerpt(text, words, length: 900)),
                                 score + (titled.contains { $0.id == doc.id } ? 2 : 0)))
            }
        }
        passages.sort { $0.1 > $1.1 }
        var out: [Passage] = []
        var used = 0
        var seenText = Set<String>()
        for (p, _) in passages where out.count < 8 {
            if used + p.text.count > budget { continue }
            // Duplicate copies of a document give identical passages; keep one.
            guard seenText.insert("\(p.page)|\(p.text.prefix(200))").inserted else { continue }
            out.append(p)
            used += p.text.count
        }
        return out
    }

    static func hits(_ text: String, _ words: [String]) -> Int {
        let lower = text.lowercased()
        return words.reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }
    }

    /// The part of a page around its densest cluster of keywords.
    static func excerpt(_ text: String, _ words: [String], length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        guard flat.count > length else { return flat }
        let lower = flat.lowercased()
        var best = lower.startIndex, bestScore = -1
        var idx = lower.startIndex
        let step = max(length / 4, 50)
        while idx < lower.endIndex {
            let end = lower.index(idx, offsetBy: length, limitedBy: lower.endIndex) ?? lower.endIndex
            let score = hits(String(lower[idx..<end]), words)
            if score > bestScore { bestScore = score; best = idx }
            idx = lower.index(idx, offsetBy: step, limitedBy: lower.endIndex) ?? lower.endIndex
        }
        let start = best
        let end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start == flat.startIndex ? "" : "…") + String(flat[start..<end]) + (end == flat.endIndex ? "" : "…")
    }

    /// Text of one page: typed text for notebooks, extracted text for PDFs.
    public func text(of doc: DocumentItem, page: Int) async -> String {
        await pageTexts(doc).first { $0.0 == page }?.1 ?? ""
    }

    /// Typed text of a notebook's pages, or the text of a PDF's pages.
    func pageTexts(_ doc: DocumentItem) async -> [(Int, String)] {
        switch doc.kind {
        case .notebook:
            var out: [(Int, String)] = []
            for i in 0..<doc.displayPageCount {
                guard let rm = doc.rmFile(for: i), let data = try? await sync.blob(rm.hash, filename: rm.name),
                      let page = RmParser.parse(data) else { continue }
                // Typed text plus any handwriting already transcribed by the OCR pass.
                let handwriting = sync.db.ocrText(rm.hash) ?? ""
                let text = (page.plainText + (handwriting.isEmpty ? "" : "\n" + handwriting)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append((i, text)) }
            }
            return out
        case .pdf:
            // Already downloaded, or short enough to fetch now (not whole comics or books just to answer a question).
            guard let hash = doc.payloadHash, sync.blobs.has(hash) || doc.displayPageCount <= 150,
                  let data = try? await sync.blob(hash, filename: "\(doc.id).pdf"), let pdf = PDFDocument(data: data) else { return [] }
            var out: [(Int, String)] = []
            for i in 0..<min(pdf.pageCount, 400) {
                if let s = pdf.page(at: i)?.string, !s.isEmpty { out.append((i, s)) }
            }
            return out
        default:
            return []
        }
    }

    // MARK: Answering

    static let system = """
    You answer questions using only the numbered sources from the user's own notes and documents. \
    Be concise and clear. If the sources don't contain the answer, say so plainly. Never invent facts. \
    Write in British English.
    """

    static func prompt(_ question: String, _ passages: [Passage]) -> String {
        var p = "Question: \(question)\n\nSources:\n"
        for (i, s) in passages.enumerated() {
            p += "\n[\(i + 1)] \(s.docName), page \(s.page + 1):\n\(s.text)\n"
        }
        return p
    }

    public func answer(_ question: String, documents: [DocumentItem], excluded: Set<String>, provider: AIProvider) async throws -> Answer {
        let budget = max(provider.settings.provider.promptBudget - 1_500, 2_000)
        let passages = await retrieve(question, documents: documents, excluded: excluded, budget: min(budget, 24_000))
        guard !passages.isEmpty else {
            return Answer(text: "I couldn't find anything about that in your notes. Typed text, PDFs and search-indexed documents are searched; handwriting isn't yet.",
                          sources: [], considered: [])
        }
        var text = ""
        var cited: [Int] = []
        #if canImport(FoundationModels)
        if provider.settings.provider == .apple, #available(macOS 26.0, *) {
            (text, cited) = try await appleAnswer(question, passages)
        }
        #endif
        if text.isEmpty {
            let reply = try await provider.complete(prompt: Self.prompt(question, passages) + """

                Answer the question from the sources. Reply as JSON only: {"answer": "…", "sources": [numbers of the sources you used]}
                """, system: Self.system, images: [], timeout: 120)
            (text, cited) = Self.parseJSON(reply)
        }
        let sources = cited.compactMap { passages.indices.contains($0 - 1) ? passages[$0 - 1] : nil }
        return Answer(text: text, sources: sources.isEmpty ? Array(passages.prefix(3)) : sources, considered: passages)
    }

    static func parseJSON(_ reply: String) -> (String, [Int]) {
        let json = reply.replacing(/^```(?:json)?\s*|\s*```$/, with: "")
        if let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"),
           let obj = try? JSONSerialization.jsonObject(with: Data(json[start...end].utf8)) as? [String: Any],
           let answer = obj["answer"] as? String {
            let nums = (obj["sources"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
            return (answer.trimmingCharacters(in: .whitespacesAndNewlines), nums)
        }
        return (reply.trimmingCharacters(in: .whitespacesAndNewlines), [])
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    func appleAnswer(_ question: String, _ passages: [Passage]) async throws -> (String, [Int]) {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw RMError.auth("Apple Intelligence isn't available: turn it on in System Settings › Apple Intelligence & Siri.")
        }
        let root = DynamicGenerationSchema(name: "Answer", properties: [
            .init(name: "answer", description: "The answer, from the sources only, in a few sentences", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "sources", description: "Numbers of the sources the answer used", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Int.self))),
        ])
        let session = LanguageModelSession(model: model, instructions: Self.system)
        let content = try await session.respond(to: Self.prompt(question, passages), schema: try GenerationSchema(root: root, dependencies: []),
                                                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 600)).content
        return ((try? content.value(String.self, forProperty: "answer")) ?? "", (try? content.value([Int].self, forProperty: "sources")) ?? [])
    }
    #endif
}
