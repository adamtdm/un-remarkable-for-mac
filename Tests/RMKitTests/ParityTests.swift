import Foundation
import Testing
@testable import RMKit

@Suite("parity features")
struct ParityTests {
    @Test func versionComparison() {
        #expect(AppVersion.isNewer("0.27", than: "0.26"))
        #expect(AppVersion.isNewer("0.3", than: "0.26"))
        #expect(!AppVersion.isNewer("0.26", than: "0.26"))
        #expect(!AppVersion.isNewer("0.30", than: "0.3"))
        #expect(AppVersion.isNewer("v1.0", than: "0.99"))
        #expect(AppVersion.isNewer("1.2.10", than: "1.2.9"))
    }

    @Test func pageMarkdownRoundTrip() {
        let md = "# Title\n## Section\nPlain line\n- bullet\n  - nested\n- [ ] todo\n- [x] done"
        let paragraphs = TypedNotebook.pages(fromMarkdown: md).flatMap { $0 }
        #expect(TypedNotebook.markdown(paragraphs) == md)
        let parsed = RmParser.parse(RmWriter.page(paragraphs: paragraphs))
        #expect(parsed.map(TypedNotebook.markdown(from:)) == md)
    }

    @Test func feedCatalogue() {
        #expect(FeedDirectory.popular.count >= 30)
        #expect(FeedDirectory.presets.first?.feeds == NewsFeeds.defaults)
        #expect(FeedDirectory.search("", category: "Science").allSatisfy { $0.category == "Science" })
        #expect(FeedDirectory.search("hacker").contains { $0.url.contains("ycombinator") })
        #expect(FeedDirectory.name(for: "https://feeds.bbci.co.uk/news/rss.xml") != nil)
        let rss = Data("<rss><channel><title>Kottke</title><description>Links</description><item><title>One</title></item></channel></rss>".utf8)
        let c = FeedDirectory.describe(rss, url: "https://kottke.org/feed", source: "x")
        #expect(c?.title == "Kottke" && c?.headlines == ["One"] && c?.articleCount == 1)
        #expect(FeedDirectory.describe(Data("<html><body>hi</body></html>".utf8), url: "u", source: "x") == nil)
    }

    @Test func ocrReplyCleaning() {
        #expect(HandwritingOCR.clean("```\nBuy milk\nCall Sam\n```") == "Buy milk\nCall Sam")
        #expect(HandwritingOCR.clean("No handwriting on this page.") == "")
        #expect(HandwritingOCR.clean("  Meeting at 3  ") == "Meeting at 3")
    }

    @Test func snapshotsAndVersions() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LibraryDatabase(url: dir.appending(path: "lib.sqlite"))
        db.recordSnapshot(rootHash: "r1", generation: 1, documents: [("a", "h1"), ("b", "h2")], changed: 2, at: Date(timeIntervalSince1970: 100))
        db.recordSnapshot(rootHash: "r2", generation: 2, documents: [("a", "h1"), ("b", "h3")], changed: 1, at: Date(timeIntervalSince1970: 200))
        #expect(db.snapshots().map(\.rootHash) == ["r2", "r1"])
        #expect(db.snapshots().first?.changed == 1)
        #expect(db.versions(of: "b").map(\.hash) == ["h3", "h2"])
        #expect(db.versions(of: "a").map(\.hash) == ["h1"]) // unchanged documents aren't stored again
        db.setOCRText("hello", for: "rm1")
        #expect(db.ocrText("rm1") == "hello" && db.ocrText("rm2") == nil && db.ocrPageCount() == 1)
    }

    @Test func handwritingConversionRequest() throws {
        let page = try #require(RmParser.parse(try fixture("Normal_A_stroke_2_layers")))
        #expect(HandwritingConversion.hasHandwriting(page))
        let body = try #require(try JSONSerialization.jsonObject(with: HandwritingConversion.requestBody(page, language: "en_GB")) as? [String: Any])
        #expect(body["xDPI"] as? Int == 226 && body["contentType"] as? String == "Text")
        #expect((body["configuration"] as? [String: Any])?["lang"] as? String == "en_GB")
        let strokes = try #require(((body["strokeGroups"] as? [[String: Any]])?.first?["strokes"]) as? [[String: [Double]]])
        #expect(!strokes.isEmpty && strokes.allSatisfy { $0["x"]?.count == $0["y"]?.count && ($0["x"]?.count ?? 0) > 1 })
        // v6 pages centre x on 0; the request uses page coordinates from the left edge.
        if page.centerOriginX { #expect(strokes.flatMap { $0["x"] ?? [] }.allSatisfy { $0 >= 0 }) }
        #expect(!HandwritingConversion.hasHandwriting(RmPage()))

        #expect(HandwritingConversion.text(fromJIIX: Data(#"{"type":"Text","label":"Buy milk\nCall Sam ","words":[]}"#.utf8)) == "Buy milk\nCall Sam")
        #expect(HandwritingConversion.text(fromJIIX: Data(#"{"type":"Raw Content","elements":[{"type":"Text","label":"One"},{"type":"Shape"},{"type":"Text","label":"Two"}]}"#.utf8)) == "One\nTwo")
        #expect(HandwritingConversion.languages.contains { $0.code == HandwritingConversion.defaultLanguage })
    }

    @Test func companionSearchResults() async throws {
        let json = #"[{"doc_id":"a","page_idx":0,"source":"typed_text","snippet":"...the <mark>meeting</mark> notes..."},{"doc_id":"b","source":"handwriting_ocr","snippet":"call <mark>Sam</mark>"},{"page_idx":1}]"#
        let hits = CompanionSearchProvider.parse(Data(json.utf8))
        #expect(hits.map(\.docID) == ["a", "b"])
        #expect(hits[0].snippet == "…the «meeting» notes…")
        #expect(hits[1].snippet.hasPrefix("✍︎"))
        if let base = ProcessInfo.processInfo.environment["RMKIT_COMPANION_URL"], let url = URL(string: base) {
            let live = try await CompanionSearchProvider(base: url).search("meeting")
            print("LIVE companion hits: \(live.count), first: \(live.first?.snippet ?? "-")")
            #expect(!live.isEmpty)
        }
    }
}
