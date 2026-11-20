import Foundation
import Testing
@testable import RMKit

@Suite("ask")
struct AskTests {
    @Test func keywordsDropQuestionWords() {
        #expect(NotesQA.keywords("What is a business model?") == ["business", "model"])
        #expect(NotesQA.keywords("Who owns the PD-13850 ticket and when?") == ["owns", "13850", "ticket"])
    }

    @Test func excerptCentresOnKeywords() {
        let text = String(repeating: "filler words here. ", count: 100) + "A business model describes how a company creates value. " + String(repeating: "more filler. ", count: 100)
        let ex = NotesQA.excerpt(text, ["business", "model"], length: 200)
        #expect(ex.contains("business model"))
        #expect(ex.count <= 204)
    }

    @Test func parsesJSONReplies() {
        let (a, s) = NotesQA.parseJSON("```json\n{\"answer\": \"It's how you make money.\", \"sources\": [2, \"3\"]}\n```")
        #expect(a == "It's how you make money." && s == [2, 3])
        #expect(NotesQA.parseJSON("plain text").0 == "plain text")
    }

    /// Against the real library with Apple Intelligence: RMKIT_LIVE_ASK="question".
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RMKIT_LIVE_ASK"] != nil))
    func liveAsk() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Unremarkable")
        let db = try LibraryDatabase(url: support.appending(path: "library.sqlite"))
        let engine = SyncEngine(client: CloudClient(auth: AuthManager()), blobs: BlobStore(root: support.appending(path: "blobs")), db: db)
        var settings = AISettings()
        settings.provider = .apple
        let q = ProcessInfo.processInfo.environment["RMKIT_LIVE_ASK"]!
        let t0 = Date()
        let answer = try await NotesQA(sync: engine).answer(q, documents: db.allDocuments(), excluded: [], provider: AIProvider(settings: settings, apiKey: ""))
        print("ASK \(q) (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)\nANSWER: \(answer.text)")
        for s in answer.sources { print("SOURCE: \(s.docName) p\(s.page + 1)") }
        print("CONSIDERED: \(answer.considered.map { "\($0.docName) p\($0.page + 1)" })")
        #expect(!answer.text.isEmpty)
    }
}
