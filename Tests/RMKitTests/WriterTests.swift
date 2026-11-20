import Foundation
import Testing
@testable import RMKit

@Suite("rm writer")
struct WriterTests {
    static let author = UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!

    func diff(_ a: Data, _ b: Data) -> String {
        let x = [UInt8](a), y = [UInt8](b)
        let i = (0..<min(x.count, y.count)).first { x[$0] != y[$0] } ?? min(x.count, y.count)
        func hex(_ v: [UInt8]) -> String { v[max(0, i - 8)..<min(v.count, i + 16)].map { String(format: "%02x", $0) }.joined(separator: " ") }
        return "sizes \(x.count)/\(y.count), first diff at \(i)\nours: \(hex(x))\nref:  \(hex(y))"
    }

    func reference(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "rm", subdirectory: "Fixtures/writer"))
        return try Data(contentsOf: url)
    }

    /// Byte-identical to rmscene's output (what the web app writes and the tablet accepts).
    @Test(arguments: [("plain", "Hello world\nSecond line"), ("empty", ""), ("unicode", "Café ✓ – naïve 日本")])
    func plainMatchesRmscene(name: String, text: String) throws {
        let ours = RmWriter.page(text: text, author: Self.author), ref = try reference(name)
        #expect(ours == ref, "\(diff(ours, ref))")
    }

    static let styled: [RmWriter.Paragraph] = [
        .init("Weekly review", style: .heading), .init("Tasks", style: .bold), .init("Send budget", style: .checkbox),
        .init("Book room", style: .checkboxChecked), .init("Point", style: .bullet), .init("Sub point", style: .bullet2),
        .init("Body text", style: .plain),
    ]

    @Test func styledMatchesRmscene() throws {
        #expect(RmWriter.page(paragraphs: Self.styled, author: Self.author) == (try reference("styled")))
    }

    @Test func roundTripsThroughParser() throws {
        let page = try #require(RmParser.parse(RmWriter.page(paragraphs: Self.styled)))
        #expect(page.paragraphs.map(\.text) == Self.styled.map(\.text))
        #expect(page.paragraphs.map(\.style) == Self.styled.map(\.style))
    }
}

@Suite("typed notebooks")
struct TypedNotebookTests {
    @Test func markdownToStyledPages() {
        let md = """
        # Plan
        Intro with **bold** and a [link](https://x.y).

        ## Tasks
        - [ ] Send budget
        - [x] Book room
        - Point
          - Sub point
        ---
        **Notes**
        1. First
        """
        let pages = TypedNotebook.pages(fromMarkdown: md)
        #expect(pages.count == 2)
        #expect(pages[0].map(\.style) == [.heading, .plain, .plain, .bold, .checkbox, .checkboxChecked, .bullet, .bullet2])
        #expect(pages[0][1].text == "Intro with bold and a link.")
        #expect(pages[0][4].text == "Send budget")
        #expect(pages[1].map(\.text) == ["Notes", "1. First"])
        #expect(pages[1][0].style == .bold)
    }

    @Test func pageOrderKeysSortAsText() {
        let keys = (0..<60).map(TypedNotebook.pageOrderKey)
        #expect(keys[0] == "baaa" && keys[1] == "baab" && keys[26] == "baba")
        #expect(keys == keys.sorted())
    }

    @Test func notebookFilesDescribeThePages() throws {
        let files = TypedNotebook.files(docID: "doc", title: "Plan", pages: [[.init("A")], [.init("B")]])
        #expect(files.filter { $0.name.hasSuffix(".rm") }.count == 2)
        let content = try #require(files.first { $0.name == "doc.content" })
        let meta = try #require(files.first { $0.name == "doc.metadata" })
        let parsed = DocumentMetadata.parse(metadata: meta.data, content: content.data)
        #expect(parsed.visibleName == "Plan")
        #expect(parsed.fileType == "notebook")
        #expect(parsed.pages.count == 2)
        // Page order in .content matches the .rm files.
        let firstRM = try #require(files.first { $0.name == "doc/\(parsed.pages[0].pageID).rm" })
        #expect(RmParser.parse(firstRM.data)?.paragraphs.first?.text == "A")
    }

    @Test func replacingTextKeepsHandwriting() throws {
        let original = try fixture("Normal_A_stroke_2_layers")
        let before = try #require(RmParser.parse(original))
        let updated = RmWriter.replacingText(in: original, paragraphs: [.init("Quick note", style: .bold), .init("More")])
        let after = try #require(RmParser.parse(updated))
        #expect(after.paragraphs.map(\.text) == ["Quick note", "More"])
        #expect(after.layers.map { $0.strokes.count } == before.layers.map { $0.strokes.count })
        #expect(after.layers.reduce(0) { $0 + $1.strokes.count } > 0)
    }
}

/// Safety check against a real root index before writing to the cloud: RMKIT_ROOT_INDEX=<blob path>.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RMKIT_ROOT_INDEX"] != nil))
func realRootIndexReformatsByteIdentically() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RMKIT_ROOT_INDEX"]!)
    let original = try Data(contentsOf: url)
    let (entries, schema) = try IndexParser.parse(original)
    let again = IndexParser.format(entries, schema: schema, owner: ".")
    #expect(again == original, "reformatted root differs (\(again.count) vs \(original.count) bytes)")
    #expect(sha256Hex(again) == url.lastPathComponent)
    print("ROOT CHECK entries=\(entries.count) schema=\(schema) identical=\(again == original)")
}

import PDFKit

@Suite("export")
struct ExportTests {
    /// Fraction of non-white pixels in a rendered page.
    func inkCoverage(_ page: PDFPage) -> Double {
        let size = CGSize(width: 300, height: 400)
        let img = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var dark = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] < 200 { dark += 1 }
        return Double(dark) / Double(w * h)
    }

    @Test func notebookAndPDFPagesExportWithInk() async throws {
        // A blank one-page PDF to annotate.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let source = try #require(PDFDocument(data: data as Data))
        let ink = try #require(RmParser.parse(try fixture("Color_and_tool_v3.14.4")))

        let out = await AnnotatedPDF.make(pageCount: 3) { i in
            switch i {
            case 0: return .init(pdf: source.page(at: 0), ink: ink)
            case 1: return .init(pdf: nil, ink: ink)
            default: return .init(pdf: nil, ink: nil)
            }
        }
        let pdf = try #require(PDFDocument(data: out))
        #expect(pdf.pageCount == 3)
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842))
        #expect(pdf.page(at: 1)?.bounds(for: .mediaBox).width == CGFloat(ink.width) * 0.5)
        #expect(inkCoverage(try #require(pdf.page(at: 0))) > 0.005)
        #expect(inkCoverage(try #require(pdf.page(at: 1))) > 0.005)
        #expect(inkCoverage(try #require(pdf.page(at: 2))) == 0)
    }
}

@Suite("appending pages")
struct AppendPagesTests {
    @Test func newPagesSortAfterExistingAndOldOnesAreDeleted() throws {
        let content = """
        {"cPages":{"lastOpened":{"timestamp":"0:0","value":""},"pages":[
          {"id":"p1","idx":{"timestamp":"1:2","value":"ba"},"scrollTime":{"timestamp":"1:5","value":"x"}},
          {"id":"p2","idx":{"timestamp":"1:3","value":"bb"}}]},"pageCount":2}
        """
        let once = try TypedNotebook.appendingPages(to: Data(content.utf8), newPageIDs: ["n1", "n2"])
        var pages = DocumentMetadata.parsePages(jsonObject(once)!)
        #expect(pages.map(\.pageID) == ["p1", "p2", "n1", "n2"])
        #expect((jsonObject(once)?["pageCount"] as? Int) == 4)
        // Replacing: n1/n2 deleted, n3 added at the end.
        let twice = try TypedNotebook.appendingPages(to: once, newPageIDs: ["n3"], removing: ["n1", "n2"])
        pages = DocumentMetadata.parsePages(jsonObject(twice)!)
        #expect(pages.map(\.pageID) == ["p1", "p2", "n3"])
        #expect((jsonObject(twice)?["pageCount"] as? Int) == 3)
        // Timestamps are newer than anything already in the list.
        let n3 = ((jsonObject(twice)?["cPages"] as? [String: Any])?["pages"] as? [[String: Any]])?.first { $0["id"] as? String == "n3" }
        let ts = (n3?["idx"] as? [String: Any])?["timestamp"] as? String
        #expect(Int(ts?.split(separator: ":").last ?? "0")! > 5)
    }
}

@Suite("appending text")
struct AppendTextTests {
    @Test func appendsAfterExistingStyledText() throws {
        let original = RmWriter.page(paragraphs: [.init("Quick Notes", style: .heading), .init("First", style: .plain)])
        let out = try #require(RmWriter.appendingText(to: original, paragraphs: [.init("", style: .plain), .init("16 Nov", style: .bold), .init("Call Rhys", style: .checkbox)]))
        let page = try #require(RmParser.parse(out))
        #expect(page.paragraphs.map(\.text) == ["Quick Notes", "First", "", "16 Nov", "Call Rhys"])
        #expect(page.paragraphs.map(\.style) == [.heading, .plain, .plain, .bold, .checkbox])
        // And again on top.
        let twice = try #require(RmWriter.appendingText(to: out, paragraphs: [.init("Second", style: .bullet)]))
        #expect(try #require(RmParser.parse(twice)).paragraphs.map(\.text).suffix(2) == ["Call Rhys", "Second"])
    }

    @Test(arguments: ["Bold_Heading_Bullet_Normal", "Normal_A_stroke_2_layers", "test-crdt-ordering", "Normal_AB"])
    func tabletWrittenPagesKeepTextAndInk(name: String) throws {
        let data = try fixture(name)
        let before = try #require(RmParser.parse(data))
        guard let out = RmWriter.appendingText(to: data, paragraphs: [.init("Added", style: .plain)]) else {
            #expect(before.paragraphs.isEmpty, "\(name) has text but append failed")
            return
        }
        let after = try #require(RmParser.parse(out))
        #expect(Array(after.paragraphs.prefix(before.paragraphs.count)) == before.paragraphs)
        #expect(after.paragraphs.last?.text == "Added")
        // Strokes keep their positions (none are anchored after the end of the text in these pages).
        #expect(after.layers.map { $0.strokes.map { $0.points.first?.y } } == before.layers.map { $0.strokes.map { $0.points.first?.y } })
        if let dir = ProcessInfo.processInfo.environment["RMKIT_RENDER_DIR"] {
            try out.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-appended.rm"))
        }
    }
}
