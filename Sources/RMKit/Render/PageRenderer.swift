import AppKit
import CoreImage
import PDFKit

public struct RenderOptions: Sendable, Hashable {
    public var dark: Bool
    /// Invert PDF paper in dark mode. `nil` = automatic (skip pages that look like artwork).
    public var invertPDF: Bool?
    /// Output width in pixels.
    public var pixelWidth: Int

    public init(dark: Bool, invertPDF: Bool? = nil, pixelWidth: Int = 1600) {
        self.dark = dark
        self.invertPDF = invertPDF
        self.pixelWidth = pixelWidth
    }
}

/// Draws reMarkable pages (ink, highlights, typed text) and PDF backgrounds into bitmaps.
public enum PageRenderer {
    // MARK: Public entry points

    /// A notebook page: paper colour plus everything drawn on it.
    public static func renderNotebook(_ page: RmPage?, options: RenderOptions) -> CGImage? {
        let pw = page?.width ?? RmPage.rm2Size.width, ph = page?.height ?? RmPage.rm2Size.height
        let scale = CGFloat(options.pixelWidth) / CGFloat(pw)
        return draw(width: options.pixelWidth, height: Int(CGFloat(ph) * scale), dark: options.dark) { ctx in
            fillPaper(ctx, CGRect(x: 0, y: 0, width: CGFloat(pw) * scale, height: CGFloat(ph) * scale), dark: options.dark)
            ctx.scaleBy(x: scale, y: scale)
            if let page, page.hasContent {
                drawOverlay(page, in: ctx, dark: options.dark)
            } else {
                drawBlankRules(ctx, width: CGFloat(pw), height: CGFloat(ph), dark: options.dark)
            }
        }
    }

    /// A PDF page with optional ink overlay, mapped the way the tablet stores it (see `inkScale`).
    public static func renderPDF(_ pdfPage: PDFPage, overlay: RmPage?, options: RenderOptions) -> (image: CGImage, inverted: Bool)? {
        let box = pdfPage.bounds(for: .cropBox)
        let rotated = pdfPage.rotation % 180 != 0
        let pdfW = rotated ? box.height : box.width, pdfH = rotated ? box.width : box.height
        guard pdfW > 0, pdfH > 0 else { return nil }
        let scale = CGFloat(options.pixelWidth) / pdfW
        let w = options.pixelWidth, h = max(1, Int(pdfH * scale))

        guard let base = draw(width: w, height: h, dark: false, flipped: false, body: { ctx in
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            pdfPage.draw(with: .cropBox, to: ctx)
        }) else { return nil }

        let invert = options.dark && (options.invertPDF ?? !looksLikeArtwork(base))
        let background = invert ? (darkenPDF(base) ?? base) : base

        guard let overlay, overlay.hasContent else { return (background, invert) }
        let rmW = CGFloat(overlay.width), rmH = CGFloat(overlay.height)
        let fit = PageRenderer.inkScale(pdfW: pdfW, pdfH: pdfH, rmW: rmW, rmH: rmH) // tablet px per PDF point
        let composed = draw(width: w, height: h, dark: invert) { ctx in
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
            // tablet px → output px
            ctx.scaleBy(x: scale / fit, y: scale / fit)
            if !overlay.centerOriginX { ctx.translateBy(x: -(rmW - pdfW * fit) / 2, y: 0) }
            drawOverlay(overlay, in: ctx, dark: invert, originOffsetX: overlay.centerOriginX ? pdfW * fit / 2 : nil)
        }
        return composed.map { ($0, invert) }
    }

    /// Tablet pixels per PDF point for ink on a PDF page.
    ///
    /// The tablet stores PDF annotations at the screen's pixel density regardless of the PDF's size:
    /// 229 dpi on the Paper Pro (1620 px wide pages), 226 dpi on the reMarkable 1 and 2. The PDF is
    /// top-aligned and centred on x = 0. (Verified against a Paper Pro sudoku and a Letter-size deck:
    /// fitting the PDF into the page frame instead put the ink up to 2x off.)
    static func inkScale(pdfW: CGFloat, pdfH: CGFloat, rmW: CGFloat, rmH: CGFloat) -> CGFloat {
        (rmW >= CGFloat(RmPage.paperProSize.width) ? 229 : 226) / 72
    }

    // MARK: Overlay

    /// Draws highlights, typed text and strokes in tablet coordinates. Context must be flipped (y down).
    public static func drawOverlay(_ page: RmPage, in ctx: CGContext, dark: Bool, originOffsetX: CGFloat? = nil) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if page.centerOriginX || originOffsetX != nil {
            ctx.translateBy(x: originOffsetX ?? CGFloat(page.width) / 2, y: 0)
        }
        ctx.setLineJoin(.round)

        for hl in page.highlights {
            let c = RmPalette.color(hl.color, dark: dark, explicit: hl.explicitColor)
            ctx.saveGState()
            ctx.setBlendMode(dark ? .screen : .multiply)
            ctx.setFillColor(cg(c, alpha: dark ? 0.45 : 0.38))
            ctx.fill(CGRect(x: CGFloat(hl.x), y: CGFloat(hl.y), width: CGFloat(hl.w), height: CGFloat(hl.h)))
            ctx.restoreGState()
        }

        if !page.paragraphs.isEmpty { drawText(page, in: ctx, dark: dark) }

        for layer in page.layers {
            for stroke in layer.strokes { drawStroke(stroke, in: ctx, dark: dark) }
        }
    }

    static func drawStroke(_ s: Stroke, in ctx: CGContext, dark: Bool) {
        guard let first = s.points.first, s.tool != .eraser else { return }
        // Highlighter/shader colours are translucent tints: keep their hue in dark mode (the black/white
        // swap is only meant for ink), and let a shader's own alpha set its strength.
        let isTint = s.tool == .highlighter || s.tool == .shader
        let keepTint = isTint && (s.explicitColor.map { 0.2126 * Double($0.r) + 0.7152 * Double($0.g) + 0.0722 * Double($0.b) >= 50 } ?? false)
        let color = keepTint ? s.explicitColor! : RmPalette.color(s.color, dark: dark, explicit: s.explicitColor)
        let tintAlphaOverride: Double? = (s.tool == .shader && s.explicitColor != nil) ? 1 : nil
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let base = WritingTools.style(s.tool, thickness: s.thicknessScale, pressure: first.pressure)
        if base.multiply { ctx.setBlendMode(dark ? .screen : .multiply) }
        switch base.cap {
        case .round: ctx.setLineCap(.round)
        case .square: ctx.setLineCap(.square)
        case .butt: ctx.setLineCap(.butt)
        }

        if s.points.count == 1 {
            guard base.opacity > 0.01 else { return }
            let r = CGFloat(max(base.width / 2, 1))
            ctx.setFillColor(cg(color, alpha: Double(base.opacity)))
            ctx.fillEllipse(in: CGRect(x: CGFloat(first.x) - r, y: CGFloat(first.y) - r, width: r * 2, height: r * 2))
            return
        }

        // Pressure tools vary width along the stroke; draw short overlapping runs. Constant tools draw one path
        // so translucent strokes (highlighter) don't darken where segments overlap.
        let run = s.tool.isPressureSensitive ? 3 : Int.max
        var i = 0
        while i < s.points.count - 1 {
            let end = min(i + (run == Int.max ? s.points.count : run), s.points.count - 1)
            let p0 = s.points[i]
            let st = WritingTools.style(s.tool, thickness: s.thicknessScale, pressure: p0.pressure)
            if st.opacity > 0.01 {
                let alpha = tintAlphaOverride ?? (dark && s.tool == .highlighter ? 0.52 : Double(st.opacity))
                ctx.setStrokeColor(cg(color, alpha: alpha))
                ctx.setLineWidth(CGFloat(st.width))
                ctx.beginPath()
                ctx.move(to: CGPoint(x: CGFloat(p0.x), y: CGFloat(p0.y)))
                for j in (i + 1)...end { ctx.addLine(to: CGPoint(x: CGFloat(s.points[j].x), y: CGFloat(s.points[j].y))) }
                ctx.strokePath()
            }
            i = end
        }
    }

    static func drawText(_ page: RmPage, in ctx: CGContext, dark: Bool) {
        let ink = dark ? CGColor(srgbRed: 0.957, green: 0.957, blue: 0.961, alpha: 1) : CGColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 1)
        let (laid, _) = TypedTextLayout.layout(page.paragraphs, posX: page.textPosX, posY: page.textPosY, width: page.textWidth)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
        // The page context is flipped (y down); CoreText draws glyphs y-up, so flip the text matrix.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for p in laid {
            guard let first = p.lines.first else { continue }
            let y = first.baselineY
            switch p.style {
            case .bullet, .bullet2:
                ctx.fillEllipse(in: CGRect(x: p.x - 24.5, y: y - 13.5, width: 9, height: 9))
            case .checkbox, .checkboxChecked:
                ctx.setLineWidth(2.5)
                ctx.stroke(CGRect(x: p.x - 32, y: y - 22, width: 20, height: 20))
                if p.style == .checkboxChecked {
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: p.x - 28, y: y - 12))
                    ctx.addLine(to: CGPoint(x: p.x - 23, y: y - 6))
                    ctx.addLine(to: CGPoint(x: p.x - 15, y: y - 18))
                    ctx.strokePath()
                }
            default: break
            }
            for line in p.lines {
                let colored = line.line
                ctx.textPosition = CGPoint(x: p.x, y: line.baselineY)
                CTLineDraw(colored, ctx)
                if p.style == .checkboxChecked {
                    let w = CTLineGetTypographicBounds(colored, nil, nil, nil)
                    ctx.setLineWidth(2)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: p.x, y: line.baselineY - 9))
                    ctx.addLine(to: CGPoint(x: p.x + w, y: line.baselineY - 9))
                    ctx.strokePath()
                }
            }
        }
    }

    // MARK: Paper and PDF treatment

    static func fillPaper(_ ctx: CGContext, _ rect: CGRect, dark: Bool) {
        ctx.setFillColor(cg(dark ? RmPalette.paperDark : RmPalette.paperLight, alpha: 1))
        ctx.fill(rect)
    }

    static func drawBlankRules(_ ctx: CGContext, width: CGFloat, height: CGFloat, dark: Bool) {
        ctx.setStrokeColor(dark ? CGColor(srgbRed: 0.153, green: 0.153, blue: 0.165, alpha: 1) : CGColor(srgbRed: 0.925, green: 0.925, blue: 0.937, alpha: 1))
        ctx.setLineWidth(1.5)
        let spacing = height / 26
        for i in 3...23 {
            let y = CGFloat(i) * spacing
            ctx.move(to: CGPoint(x: width * 0.06, y: y))
            ctx.addLine(to: CGPoint(x: width * 0.94, y: y))
        }
        ctx.strokePath()
    }

    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// Maps white paper to the dark canvas (#18181B) and black ink to near-white, same curve as the Android reader.
    static func darkenPDF(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIColorMatrix") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: -0.85, y: 0, z: 0, w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: 0, y: -0.85, z: 0, w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: 0, y: 0, z: -0.85, w: 0), forKey: "inputBVector")
        f.setValue(CIVector(x: 232 / 255.0, y: 232 / 255.0, z: 235 / 255.0, w: 0), forKey: "inputBiasVector")
        guard let out = f.outputImage else { return nil }
        return ciContext.createCGImage(out, from: ci.extent)
    }

    /// Comic/artwork heuristic: lots of saturated or mid-tone pixels means the page is art, not text on paper.
    static func looksLikeArtwork(_ image: CGImage) -> Bool {
        let w = 64, h = max(1, 64 * image.height / max(image.width, 1))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var busy = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let mx = max(r, g, b), mn = min(r, g, b)
            if mx - mn > 40 || (mx > 50 && mx < 205) { busy += 1 }
        }
        return Double(busy) / Double(w * h) > 0.35
    }

    // MARK: Bitmap helpers

    static func draw(width: Int, height: Int, dark: Bool, flipped: Bool = true, body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        if flipped {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
        }
        body(ctx)
        return ctx.makeImage()
    }

    static func cg(_ c: Rgba, alpha: Double) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(alpha * c.a))
    }
}
