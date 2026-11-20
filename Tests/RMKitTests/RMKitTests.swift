import CoreGraphics
import ImageIO
import PDFKit
import Foundation
import Testing
@testable import RMKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "rm", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("rm parser")
struct ParserTests {
    @Test func parsesEveryFixture() throws {
        let names = ["Normal_AB", "Normal_A_stroke_2_layers", "Normal_A_stroke_2_layers_v3.2.2", "Normal_A_stroke_2_layers_v3.3.2",
                     "Lines_v2", "Lines_v2_updated", "Bold_Heading_Bullet_Normal", "Color_and_tool_v3.14.4",
                     "More_color_highlight_shader_v3.15.4.2", "Wikipedia_highlighted_p1", "Wikipedia_highlighted_p2",
                     "With_SceneInfo_Block", "test-crdt-ordering"]
        for n in names {
            let page = try #require(RmParser.parse(try fixture(n)), "\(n) failed to parse")
            #expect(page.hasContent, "\(n) parsed empty")
        }
    }

    @Test func typedTextAndStyles() throws {
        let page = try #require(RmParser.parse(try fixture("Bold_Heading_Bullet_Normal")))
        let styles = Set(page.paragraphs.map(\.style.rawValue))
        #expect(styles.contains(ParagraphStyle.heading.rawValue))
        #expect(styles.contains(ParagraphStyle.bullet.rawValue))
        #expect(page.plainText.contains("# "))
    }

    @Test func normalABText() throws {
        let page = try #require(RmParser.parse(try fixture("Normal_AB")))
        let text = page.paragraphs.map(\.text).joined()
        #expect(text.contains("A"))
        #expect(text.contains("B"))
    }

    @Test func twoLayers() throws {
        let page = try #require(RmParser.parse(try fixture("Normal_A_stroke_2_layers")))
        #expect(page.layers.count == 2)
        #expect(page.layers.allSatisfy { !$0.strokes.isEmpty })
    }

    @Test func crdtOrderingProducesExpectedText() throws {
        let page = try #require(RmParser.parse(try fixture("test-crdt-ordering")))
        let text = page.paragraphs.map(\.text).joined(separator: "\n")
        #expect(!text.isEmpty)
    }

    @Test func highlightsAndColors() throws {
        let page = try #require(RmParser.parse(try fixture("Wikipedia_highlighted_p1")))
        #expect(!page.highlights.isEmpty)
        #expect(page.highlights.contains { !$0.text.isEmpty })
        let color = try #require(RmParser.parse(try fixture("Color_and_tool_v3.14.4")))
        let strokes = color.layers.flatMap(\.strokes)
        #expect(Set(strokes.map { "\($0.tool)" }) == ["shader", "ballpoint"])
        #expect(strokes.contains { $0.color == .cyan } && strokes.contains { $0.color == .green2 })
        let shader = try #require(RmParser.parse(try fixture("More_color_highlight_shader_v3.15.4.2")))
        let explicit = shader.layers.flatMap(\.strokes).compactMap(\.explicitColor)
        #expect(explicit.first == Rgba(255, 237, 117, 1))
    }

    @Test func sceneInfoPaperSize() throws {
        let page = try #require(RmParser.parse(try fixture("With_SceneInfo_Block")))
        #expect(page.width > 0 && page.height > 0)
    }

    @Test func rejectsGarbage() {
        #expect(RmParser.parse(Data("not a page".utf8)) == nil)
    }
}

@Suite("sync15 model")
struct ModelTests {
    @Test func indexRoundTripV4() throws {
        let entries = [
            Entry(hash: String(repeating: "a", count: 64), type: Entry.docType, id: "b-doc", subfiles: 3, size: 120),
            Entry(hash: String(repeating: "b", count: 64), type: Entry.docType, id: "a-doc", subfiles: 1, size: 30),
        ]
        let data = IndexParser.format(entries)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("4\n0:.:2:150\n"))
        let (parsed, schema) = try IndexParser.parse(data)
        #expect(schema == "4")
        #expect(parsed.map(\.id) == ["a-doc", "b-doc"])
        let (docData, hash) = IndexParser.buildDocSchema(entries, schema: "4", docID: "X")
        #expect(hash == sha256Hex(docData))
        #expect(String(decoding: docData, as: UTF8.self).contains("0:X:2:150"))
    }

    @Test func indexV3() throws {
        let raw = "3\n\(String(repeating: "c", count: 64)):0:doc.metadata:0:42\n"
        let (e, s) = try IndexParser.parse(Data(raw.utf8))
        #expect(s == "3" && e.count == 1 && e[0].size == 42 && !e[0].isDocument)
    }

    @Test func metadataAndCPages() throws {
        let meta = #"{"visibleName":"Meeting","type":"DocumentType","parent":"f1","lastModified":"1700000000000","pinned":true}"#
        let content = #"""
        {"fileType":"pdf","tags":[{"name":"work"}],
         "cPages":{"lastOpened":{"value":"p2"},"pages":[
           {"id":"p2","idx":{"value":"bb"},"redir":{"value":1}},
           {"id":"gone","idx":{"value":"ab"},"deleted":{"value":1}},
           {"id":"p1","idx":{"value":"ba"},"redir":{"value":0}}]}}
        """#
        let m = DocumentMetadata.parse(metadata: Data(meta.utf8), content: Data(content.utf8))
        #expect(m.visibleName == "Meeting" && m.parent == "f1" && m.pinned)
        #expect(m.pages.map(\.pageID) == ["p1", "p2"])
        #expect(m.pages.map(\.redir) == [0, 1])
        #expect(m.lastOpenedPage == 1)
        #expect(m.tags == ["work"])
        #expect(m.fileType == "pdf")
        #expect(m.lastModified == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func pageResolution() {
        let doc = DocumentItem(id: "D", name: "n", kind: .pdf,
                               subfiles: ["D/p1.rm": "h1", "D.pdf": "pdfhash"],
                               pages: [PageRef(pageID: "p1", redir: 0), PageRef(pageID: "p2", redir: -1)])
        #expect(doc.rmFile(for: 0)?.hash == "h1")
        #expect(doc.rmFile(for: 1) == nil)
        #expect(doc.pdfPageIndex(for: 1) == -1)
        #expect(doc.payloadHash == "pdfhash")
    }

    @Test func crc32c() {
        #expect(CRC32C.checksum(Data("123456789".utf8)) == 0xE306_9283)
    }

    @Test func jwtExpiry() {
        func jwt(_ exp: Int) -> String {
            let payload = Data(#"{"exp":\#(exp)}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
            return "h.\(payload).s"
        }
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AuthManager.isExpired(jwt(1_000_060), now: now))
        #expect(!AuthManager.isExpired(jwt(1_003_600), now: now))
        #expect(!AuthManager.isExpired("opaque-token", now: now))
    }
}

@Suite("library database")
struct DatabaseTests {
    @Test func upsertSearchRemove() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "rmkit-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try LibraryDatabase(url: url)
        let a = DocumentItem(id: "a", name: "Quarterly planning", kind: .notebook, tags: ["work"], hash: "1")
        let b = DocumentItem(id: "b", name: "Dune", kind: .epub, hash: "2")
        db.upsert([a, b])
        #expect(db.allDocuments().count == 2)
        #expect(db.search("quart").map(\.docID) == ["a"])
        #expect(db.search("work").map(\.docID) == ["a"])
        db.setBody("Action item: email Priya about the roadmap", for: b)
        #expect(db.search("roadmap").map(\.docID) == ["b"])
        // A metadata-only upsert keeps the extracted body.
        db.upsert([b])
        #expect(db.search("roadmap").map(\.docID) == ["b"])
        db.remove(ids: ["a"])
        #expect(db.document("a") == nil)
        #expect(db.search("quart").isEmpty)
        db.setValue("root", for: "rootHash")
        #expect(db.value("rootHash") == "root")
    }
}

@Suite("renderer")
struct RenderTests {
    @Test func rendersNotebookLightAndDark() throws {
        let page = try #require(RmParser.parse(try fixture("Color_and_tool_v3.14.4")))
        let light = try #require(PageRenderer.renderNotebook(page, options: RenderOptions(dark: false, pixelWidth: 600)))
        let dark = try #require(PageRenderer.renderNotebook(page, options: RenderOptions(dark: true, pixelWidth: 600)))
        #expect(light.width == 600 && dark.width == 600)
        #expect(pixel(light, 2, 2).0 > 240)
        #expect(pixel(dark, 2, 2).0 < 40)
    }

    @Test func pdfDarkModeAndOverlay() throws {
        // A one-page text PDF built in memory.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 700, width: 300, height: 14))
        ctx.endPDFPage()
        ctx.closePDF()
        let pdf = try #require(PDFDocument(data: data as Data))
        let page = try #require(pdf.page(at: 0))
        let overlay = try #require(RmParser.parse(try fixture("Wikipedia_highlighted_p1")))

        let auto = try #require(PageRenderer.renderPDF(page, overlay: overlay, options: RenderOptions(dark: true, pixelWidth: 595)))
        #expect(auto.inverted)
        #expect(pixel(auto.image, 5, 5).0 < 40)          // paper became the dark canvas
        let original = try #require(PageRenderer.renderPDF(page, overlay: nil, options: RenderOptions(dark: true, invertPDF: false, pixelWidth: 595)))
        #expect(!original.inverted)
        #expect(pixel(original.image, 5, 5).0 > 240)
        #expect(original.image.height == 842)
    }

    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (px[0], px[1], px[2])
    }
}


/// Writes rendered fixtures as PNGs for visual review: `RMKIT_RENDER_DIR=/tmp/out scripts/test.sh --filter renderFixtures`.
@Test func renderFixturesForReview() throws {
    guard let dir = ProcessInfo.processInfo.environment["RMKIT_RENDER_DIR"] else { return }
    // RMKIT_RENDER_INPUT=<dir of .rm files> renders those instead of the bundled fixtures.
    let input = ProcessInfo.processInfo.environment["RMKIT_RENDER_INPUT"].map { URL(fileURLWithPath: $0) }
    let names = try input.map { try FileManager.default.contentsOfDirectory(atPath: $0.path).filter { $0.hasSuffix(".rm") }.map { String($0.dropLast(3)) } }
        ?? ["Color_and_tool_v3.14.4", "More_color_highlight_shader_v3.15.4.2", "Bold_Heading_Bullet_Normal", "Normal_A_stroke_2_layers", "Wikipedia_highlighted_p1"]
    for name in names {
        let data = try input.map { try Data(contentsOf: $0.appending(path: "\(name).rm")) } ?? fixture(name)
        let page = try #require(RmParser.parse(data), "\(name) failed to parse")
        print("RENDER \(name): page \(page.width)x\(page.height) centred=\(page.centerOriginX) ink=\(page.inkBounds.map { "\($0)" } ?? "none")")
        for dark in [false, true] {
            let img = try #require(PageRenderer.renderNotebook(page, options: RenderOptions(dark: dark, pixelWidth: 700)))
            let url = URL(fileURLWithPath: dir).appending(path: "\(name)-\(dark ? "dark" : "light").png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

@Test func wrappedTypedTextPushesLaterParagraphsAndAnchors() {
    let long = String(repeating: "Wrapped agenda item text that runs past the text width. ", count: 6)
    let paras = [TypedParagraph(text: long, style: .bullet), TypedParagraph(text: "Notes", style: .bold)]
    let (laid, bottom) = TypedTextLayout.layout(paras, posX: -576, posY: 234, width: 1152)
    #expect(laid[0].lines.count > 1)
    // The next paragraph starts below the last wrapped line, not one fixed line height down.
    #expect(laid[1].slotY == laid[0].lines.last!.baselineY)
    #expect(laid[1].lines[0].baselineY == laid[1].slotY + 70)
    // Characters on a wrapped line anchor to that line's baseline.
    let secondLine = laid[0].lines[1]
    #expect(laid[0].anchorY(forOffset: secondLine.start + 1) == secondLine.baselineY)
    #expect(laid[0].anchorY(forOffset: 0) == laid[0].lines[0].baselineY)
    #expect(bottom == laid[1].lines[0].baselineY)
}
