import CoreGraphics
import Foundation
import PDFKit

/// Exports a document as a vector PDF: the original PDF pages (when there are any) with the tablet ink,
/// highlights and typed text drawn on top as vectors, using the same mapping as the reader.
public enum AnnotatedPDF {
    public struct Page {
        public var pdf: PDFPage?
        public var ink: RmPage?
        public init(pdf: PDFPage?, ink: RmPage?) {
            self.pdf = pdf
            self.ink = ink
        }
    }

    /// Notebook pages are written at half the tablet's pixel size in points (1404 px → 702 pt), a 3:4 page.
    static let notebookScale: CGFloat = 0.5

    public static func make(pageCount: Int, page: (Int) async -> Page) async -> Data {
        var pages: [Page] = []
        for i in 0..<pageCount { pages.append(await page(i)) }
        return make(pages)
    }

    public static func make(_ pages: [Page]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return Data() }
        for p in pages {
            if let pdfPage = p.pdf {
                drawPDFPage(pdfPage, ink: p.ink, in: ctx)
            } else {
                drawNotebookPage(p.ink, in: ctx)
            }
        }
        ctx.closePDF()
        return data as Data
    }

    static func drawNotebookPage(_ ink: RmPage?, in ctx: CGContext) {
        let w = CGFloat(ink?.width ?? RmPage.rm2Size.width), h = CGFloat(ink?.height ?? RmPage.rm2Size.height)
        var box = CGRect(x: 0, y: 0, width: w * notebookScale, height: h * notebookScale)
        ctx.beginPage(mediaBox: &box)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(box)
        if let ink, ink.hasContent {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: notebookScale, y: -notebookScale)
            PageRenderer.drawOverlay(ink, in: ctx, dark: false)
            ctx.restoreGState()
        }
        ctx.endPage()
    }

    static func drawPDFPage(_ pdfPage: PDFPage, ink: RmPage?, in ctx: CGContext) {
        let crop = pdfPage.bounds(for: .cropBox)
        let rotated = pdfPage.rotation % 180 != 0
        let pdfW = rotated ? crop.height : crop.width, pdfH = rotated ? crop.width : crop.height
        var box = CGRect(x: 0, y: 0, width: pdfW, height: pdfH)
        ctx.beginPage(mediaBox: &box)
        ctx.saveGState()
        pdfPage.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        if let ink, ink.hasContent, pdfW > 0, pdfH > 0 {
            let rmW = CGFloat(ink.width), rmH = CGFloat(ink.height)
            let fit = PageRenderer.inkScale(pdfW: pdfW, pdfH: pdfH, rmW: rmW, rmH: rmH) // tablet px per PDF point
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pdfH)
            ctx.scaleBy(x: 1 / fit, y: -1 / fit)
            if !ink.centerOriginX { ctx.translateBy(x: -(rmW - pdfW * fit) / 2, y: 0) }
            PageRenderer.drawOverlay(ink, in: ctx, dark: false, originOffsetX: ink.centerOriginX ? pdfW * fit / 2 : nil)
            ctx.restoreGState()
        }
        ctx.endPage()
    }
}
