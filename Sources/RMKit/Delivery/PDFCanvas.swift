import CoreGraphics
import CoreText
import Foundation

/// Draws PDF pages using top-left coordinates in pixels-as-points, like the web app's PyMuPDF code.
final class PDFCanvas {
    enum Face: String {
        case serif = "TimesNewRomanPSMT"
        case serifBold = "TimesNewRomanPS-BoldMT"
        case serifItalic = "TimesNewRomanPS-ItalicMT"
        case sans = "Helvetica"
        case sansBold = "Helvetica-Bold"
    }

    let width: CGFloat
    let height: CGFloat
    private let data = NSMutableData()
    private let ctx: CGContext
    /// Measuring pass: drawing is skipped but pages are counted and text still flows.
    let measuring: Bool
    private(set) var pageCount = 0

    init(width: Int, height: Int, measuring: Bool = false) {
        self.width = CGFloat(width)
        self.height = CGFloat(height)
        self.measuring = measuring
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    }

    func beginPage() {
        pageCount += 1
        if measuring { return }
        if pageCount > 1 { ctx.endPDFPage() }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    func finish() -> Data {
        if pageCount > 0, !measuring { ctx.endPDFPage() }
        ctx.closePDF()
        return data as Data
    }

    /// Marks the top of the current page as a named link target.
    func destination(_ name: String) {
        if !measuring { ctx.addDestination(name as CFString, at: CGPoint(x: 0, y: height)) }
    }

    /// Makes a top-left rect on the current page a link to a named destination.
    func link(_ rect: CGRect, to name: String) {
        if !measuring { ctx.setDestination(name as CFString, for: pdfRect(rect)) }
    }

    func stroke(_ rect: CGRect, width w: CGFloat = 1, gray: CGFloat = 0) {
        if measuring { return }
        ctx.setStrokeColor(CGColor(gray: gray, alpha: 1))
        ctx.setLineWidth(w)
        ctx.stroke(pdfRect(rect))
    }

    /// Converts a top-left rect to PDF space.
    func pdfRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }

    func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, width w: CGFloat = 1, gray: CGFloat = 0) {
        if measuring { return }
        ctx.setStrokeColor(CGColor(gray: gray, alpha: 1))
        ctx.setLineWidth(w)
        ctx.move(to: CGPoint(x: x0, y: height - y0))
        ctx.addLine(to: CGPoint(x: x1, y: height - y1))
        ctx.strokePath()
    }

    static func attributes(_ face: Face, _ size: CGFloat, gray: CGFloat = 0, lineHeight: CGFloat? = nil, paragraphSpacing: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(face.rawValue as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        if lineHeight != nil || paragraphSpacing > 0 {
            var settings: [CTParagraphStyleSetting] = []
            var multiple = lineHeight ?? 1
            var spacing = paragraphSpacing
            withUnsafePointer(to: &multiple) { m in
                withUnsafePointer(to: &spacing) { s in
                    settings.append(CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: m))
                    settings.append(CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: s))
                    attrs[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        return attrs
    }

    /// One line of text with its baseline at `y`.
    func text(_ s: String, x: CGFloat, y: CGFloat, face: Face = .sans, size: CGFloat, gray: CGFloat = 0) {
        if measuring { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Self.attributes(face, size, gray: gray)))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: height - y)
        CTLineDraw(line, ctx)
    }

    static func textWidth(_ s: String, face: Face, size: CGFloat) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes(face, size))), nil, nil, nil))
    }

    /// Wrapped text in a box; text that doesn't fit is clipped at a line boundary. Returns the characters drawn.
    @discardableResult
    func textBox(_ s: NSAttributedString, in rect: CGRect, from start: Int = 0) -> Int {
        let setter = CTFramesetterCreateWithAttributedString(s)
        return draw(setter, range: CFRange(location: start, length: 0), in: rect)
    }

    @discardableResult
    func draw(_ setter: CTFramesetter, range: CFRange, in rect: CGRect) -> Int {
        let frame = CTFramesetterCreateFrame(setter, range, CGPath(rect: pdfRect(rect), transform: nil), nil)
        if !measuring {
            ctx.textMatrix = .identity
            CTFrameDraw(frame, ctx)
        }
        return CTFrameGetVisibleStringRange(frame).length
    }

    /// Draws a JPEG (kept as a JPEG stream in the PDF) fitted inside a rect, centred.
    func jpeg(_ data: Data, in rect: CGRect) {
        guard !measuring, let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: pdfRect(CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)))
    }
}
