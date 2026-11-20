import Foundation
import PDFKit
import Testing
@testable import RMKit

@Suite("delivery")
struct DeliveryTests {
    @Test func sudokuHasOneSolution() {
        for clues in [40, 32, 26] {
            let (puzzle, solution) = Sudoku.generate(seed: 20261117, clues: clues)
            #expect(puzzle.joined().filter { $0 != 0 }.count == clues)
            #expect(Sudoku.countSolutions(puzzle, limit: 2) == 1)
            for r in 0..<9 { #expect(Set(solution[r]).count == 9) }
            for c in 0..<9 where true { #expect(Set((0..<9).map { solution[$0][c] }).count == 9) }
        }
        // Same date, same puzzle.
        #expect(Sudoku.generate(seed: 1, clues: 32).0 == Sudoku.generate(seed: 1, clues: 32).0)
    }

    @Test func sudokuPDF() throws {
        let (data, name) = DailyPuzzles.sudoku(difficulty: "medium", date: Date(timeIntervalSince1970: 1_795_000_000), device: .rm2)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 1404, height: 1872))
        #expect(name.hasPrefix("Daily_Sudoku_20"))
    }

    @Test func feedParsingRSSAndAtom() {
        let rss = """
        <?xml version="1.0"?><rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Ars Technica</title>
        <item><title>First &amp;amp; best</title><link>https://example.com/a</link><description>&lt;p&gt;Summary&lt;/p&gt;</description>
        <content:encoded><![CDATA[<p>Body</p>]]></content:encoded></item>
        <item><title>Second</title><link>https://example.com/b</link></item>
        <item><title>Third</title><link>https://example.com/c</link></item></channel></rss>
        """
        let items = NewsFeeds.parseFeed(Data(rss.utf8), feedURL: "https://feeds.arstechnica.com/x", limit: 2)
        #expect(items.map(\.title) == ["First & best", "Second"])
        #expect(items[0].section == "Technology & Computing")
        #expect(items[0].summary == "Summary")
        #expect(items[0].contentEncoded == "<p>Body</p>")
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Nature</title><entry><title>Cells</title><link href="https://n.com/1"/></entry></feed>
        """
        let a = NewsFeeds.parseFeed(Data(atom.utf8), feedURL: "https://www.nature.com/nature.rss", limit: 5)
        #expect(a.first?.link == "https://n.com/1")
        #expect(a.first?.section == "Science & Space Exploration")
    }

    @Test func articleExtractionSkipsBoilerplate() {
        let para = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6)
        let html = """
        <html><body><nav><p>\(para)</p></nav><article><h2>A proper sub-heading here</h2><p>\(para)</p>
        <p>Subscribe to our newsletter for more stories like this one</p><div class="sidebar"><p>\(para)</p></div>
        <p><img src="/i.jpg">\(para)</p></article></body></html>
        """
        let (blocks, images) = NewsFeeds.extract(html: html)
        #expect(blocks.map(\.kind) == [.heading, .paragraph, .paragraph], "\(blocks.map(\.text))")
        #expect(images == ["/i.jpg"])
    }

    @Test func newspaperLinksAndPageNumbers() throws {
        let para = String(repeating: "Words fill the column of this newspaper story. ", count: 60)
        let articles = (0..<10).map { i in
            NewsArticle(title: "Story number \(i)", source: "Source", section: i < 5 ? "Technology & Computing" : "World & National News",
                        url: "https://e.com/\(i)", blocks: Array(repeating: .init(kind: .paragraph, text: para), count: 6))
        }
        let edition = Newspaper.Edition(date: .now, weather: "London: 9°C, Cloudy", lead: .init(title: "Lead", extract: para), articles: articles)
        let pdf = try #require(PDFDocument(data: Newspaper.render(edition, device: .paperPro)))
        #expect(pdf.pageCount > 12) // 2 index pages + multi-page articles
        let index = try #require(pdf.page(at: 0))
        let links = index.annotations.filter { $0.type == "Link" }
        #expect(links.count == 8)
        // Every index link lands on a page whose header is that story's title.
        // Sections come in the web app's order: World (stories 5–9) before Technology (0–4).
        let order = [5, 6, 7, 8, 9, 0, 1, 2]
        for (i, link) in links.sorted(by: { ($0.bounds.minX, -$0.bounds.minY) < ($1.bounds.minX, -$1.bounds.minY) }).enumerated() {
            let target = try #require(link.destination?.page ?? (link.action as? PDFActionGoTo)?.destination.page)
            #expect(target.string?.contains("Story number \(order[i])") == true)
        }
        let story = try #require(pdf.page(at: 2))
        #expect(story.string?.contains("BACK TO INDEX") == true)
        #expect(story.annotations.contains { $0.type == "Link" })
        #expect(pdf.page(at: pdf.pageCount - 1)?.string?.contains("Page \(pdf.pageCount) of \(pdf.pageCount)") == true)
    }

    /// Live: `RMKIT_DELIVERY_DIR=<dir> scripts/test.sh --filter liveDelivery` fetches and writes today's PDFs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RMKIT_DELIVERY_DIR"] != nil))
    func liveDelivery() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RMKIT_DELIVERY_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var options = Newspaper.Options()
        options.weatherLocation = "London"
        options.includeImages = true
        let paper = await Newspaper.generate(options)
        try paper.pdf.write(to: dir.appending(path: paper.filename))
        print("newspaper: \(paper.articles) articles, \(PDFDocument(data: paper.pdf)?.pageCount ?? 0) pages, \(paper.pdf.count) bytes")
        #expect(paper.articles > 0)
        for type in ["quick", "cryptic"] {
            let (data, name) = try await DailyPuzzles.guardianCrossword(type)
            try data.write(to: dir.appending(path: name))
        }
        let (sudoku, name) = DailyPuzzles.sudoku(difficulty: "hard")
        try sudoku.write(to: dir.appending(path: name))
    }
}
