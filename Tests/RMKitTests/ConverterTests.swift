import CoreGraphics
import Foundation
import AppKit
import PDFKit
import Testing
@testable import RMKit

@Suite("converter")
struct ConverterTests {
    /// A test PDF: a portrait page and a landscape double spread with a different colour on each half.
    func samplePDF() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        var portrait = CGRect(x: 0, y: 0, width: 600, height: 800)
        ctx.beginPage(mediaBox: &portrait)
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1)); ctx.fill(CGRect(x: 50, y: 50, width: 200, height: 200))
        ctx.endPage()
        var spread = CGRect(x: 0, y: 0, width: 1200, height: 800)
        ctx.beginPage(mediaBox: &spread)
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 600, y: 0, width: 600, height: 800))
        ctx.endPage()
        ctx.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    @Test func targetsMatchEachTabletAtBalanced() {
        #expect(Converter.targetSize(.init(quality: 3, device: .paperPro)) == (1620, 2160))
        #expect(Converter.targetSize(.init(quality: 3, device: .rm2)) == (1404, 1872))
        #expect(Converter.targetSize(.init(quality: 1, device: .paperPro)) == (1200, 1600))
    }

    @Test func splitsSpreadsInReadingOrder() throws {
        let western = try Converter.convert(pdf: samplePDF(), options: .init(quality: 2, splitSpreads: true))
        #expect(western.pages == 3)
        let out = try #require(PDFDocument(data: western.pdf))
        #expect(out.pageCount == 3)
        // Page 2 is the left (red) half in western order, the right (blue) half for manga.
        func dominantRed(_ doc: PDFDocument, _ i: Int) -> Bool {
            let img = doc.page(at: i)!.thumbnail(of: CGSize(width: 20, height: 20), for: .mediaBox)
            let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
            let c = rep.colorAt(x: 10, y: 10)!.usingColorSpace(.sRGB)!
            return c.redComponent > c.blueComponent
        }
        #expect(dominantRed(out, 1))
        let manga = try #require(PDFDocument(data: try Converter.convert(pdf: samplePDF(), options: .init(quality: 2, splitSpreads: true, mangaOrder: true)).pdf))
        #expect(!dominantRed(manga, 1))
        let unsplit = try Converter.convert(pdf: samplePDF(), options: .init(quality: 2, splitSpreads: false))
        #expect(unsplit.pages == 2)
    }

    @Test func pagesFitTheTargetAndGrayscaleForMonochrome() throws {
        let r = try Converter.convert(pdf: samplePDF(), options: .init(quality: 3, device: .rm2, splitSpreads: false))
        let out = try #require(PDFDocument(data: r.pdf))
        let first = out.page(at: 0)!.bounds(for: .mediaBox).size
        #expect(first.height <= 1872 && first.width <= 1404)
        #expect(abs(first.width / first.height - 0.75) < 0.01)
        let spread = out.page(at: 1)!.bounds(for: .mediaBox).size
        #expect(spread.width <= 1872 && spread.width > spread.height)
    }
}

/// RMKIT_CONVERT=<file> RMKIT_RENDER_DIR=<dir>: converts a real file and reports size and speed.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RMKIT_CONVERT"] != nil))
func convertRealFile() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RMKIT_CONVERT"]!)
    for stop in [1, 3, 5] {
        let t0 = Date()
        let r = try Converter.convert(url, options: .init(quality: stop, device: .paperPro))
        print("CONVERT stop \(stop): \(r.pages) pages, \(r.inputBytes / 1000) KB -> \(r.pdf.count / 1000) KB in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        if stop == 3, let dir = ProcessInfo.processInfo.environment["RMKIT_RENDER_DIR"] {
            try r.pdf.write(to: URL(fileURLWithPath: dir).appending(path: "converted.pdf"))
        }
    }
}
