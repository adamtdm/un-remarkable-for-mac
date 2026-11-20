import AppKit
import CoreText

/// Lays out a meeting as a PDF for the tablet: the notes first, then the transcript on new pages.
public enum MeetingPDF {
    /// 3:4 like the reMarkable screen; the tablet scales it to fit.
    static let pageSize = CGSize(width: 702, height: 936)
    static let margins = NSEdgeInsets(top: 58, left: 64, bottom: 64, right: 52)

    static let ink = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
    static let muted = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1)

    public static func render(_ meeting: Meeting) -> Data {
        var sections: [NSAttributedString] = []
        let header = NSMutableAttributedString()
        header.append(para(meeting.displayTitle, font: .systemFont(ofSize: 26, weight: .bold), after: 6))
        var meta = meeting.startedAt.formatted(date: .complete, time: .shortened)
        if meeting.duration > 0 { meta += "  ·  " + durationText(meeting.duration) }
        header.append(para(meta, font: .systemFont(ofSize: 12), color: muted, after: 18))

        let body = meeting.aiNotes.isEmpty ? meeting.myNotes : meeting.aiNotes
        if meeting.aiNotes.isEmpty, !body.isEmpty {
            header.append(para("My notes", font: .systemFont(ofSize: 19, weight: .semibold), before: 6, after: 8))
        }
        header.append(markdown(body))
        // Space to write by hand below the notes.
        header.append(para("Handwritten notes", font: .systemFont(ofSize: 19, weight: .semibold), before: 22, after: 4))
        header.append(para("Write here during or after the meeting.", font: .systemFont(ofSize: 11), color: muted, after: 0))
        sections.append(header)

        if !meeting.transcript.isEmpty {
            sections.append(transcript(meeting))
        }
        return draw(sections, footer: meeting.displayTitle)
    }

    static func durationText(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }

    // MARK: Markdown subset: headings, bullets (nested), checkboxes, numbered lists, paragraphs, inline bold/italic.

    static func markdown(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 14)
        for raw in text.components(separatedBy: .newlines) {
            let indentSpaces = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                let size: CGFloat = level <= 1 ? 22 : level == 2 ? 19 : 15.5
                out.append(para(title, font: .systemFont(ofSize: size, weight: .semibold), before: level <= 2 ? 16 : 10, after: 6, inline: true))
                continue
            }
            let level = CGFloat(indentSpaces / 2)
            if let m = line.firstMatch(of: /^[-*+]\s+\[( |x|X)\]\s+(.*)$/) {
                let done = m.1 != " "
                out.append(listItem(String(m.2), marker: done ? "☑" : "☐", level: level, font: bodyFont, strike: done))
            } else if let m = line.firstMatch(of: /^[-*+•]\s+(.*)$/) {
                out.append(listItem(String(m.1), marker: level > 0 ? "◦" : "•", level: level, font: bodyFont))
            } else if let m = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                out.append(listItem(String(m.2), marker: "\(m.1).", level: level, font: bodyFont))
            } else {
                out.append(para(line, font: bodyFont, after: 7, inline: true))
            }
        }
        return out
    }

    static func listItem(_ text: String, marker: String, level: CGFloat, font: NSFont, strike: Bool = false) -> NSAttributedString {
        let indent = 18 + level * 18
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent - 16
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.paragraphSpacing = 4
        style.lineHeightMultiple = 1.1
        let s = NSMutableAttributedString(string: "\(marker)\t", attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style])
        let body = inline(text, font: font, color: ink)
        if strike { body.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: body.length)) }
        body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
        s.append(body)
        s.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        return s
    }

    static func para(_ text: String, font: NSFont, color: NSColor = ink, before: CGFloat = 0, after: CGFloat = 0, inline parse: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = 1.1
        let s = parse ? inline(text, font: font, color: color) : NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        s.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Inline Markdown (bold, italic, code) with the given base font.
    static func inline(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: opts) else {
            return NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let str = String(parsed[run.range].characters)
            var f = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) { f = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular) }
            out.append(NSAttributedString(string: str, attributes: [.font: f, .foregroundColor: color]))
        }
        return out
    }

    static func transcript(_ meeting: Meeting) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(para("Transcript", font: .systemFont(ofSize: 22, weight: .semibold), after: 12))
        let font = NSFont.systemFont(ofSize: 11.5)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 7
        style.lineHeightMultiple = 1.1
        for line in meeting.transcriptText.components(separatedBy: "\n") {
            guard let m = line.firstMatch(of: /^\[([^\]]+)\] (Me|Them): (.*)$/) else { continue }
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "\(m.1)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: muted]))
            s.append(NSAttributedString(string: "\(m.2)  ", attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: ink]))
            s.append(NSAttributedString(string: "\(m.3)\n", attributes: [.font: font, .foregroundColor: ink]))
            s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
            out.append(s)
        }
        return out
    }

    // MARK: Pagination

    static func draw(_ sections: [NSAttributedString], footer: String) -> Data {
        let frameRect = CGRect(x: margins.left, y: margins.bottom, width: pageSize.width - margins.left - margins.right,
                               height: pageSize.height - margins.top - margins.bottom)
        // First pass: split each section into page ranges.
        var pages: [(CTFramesetter, CFRange)] = []
        for section in sections where section.length > 0 {
            let setter = CTFramesetterCreateWithAttributedString(section)
            var start = 0
            while start < section.length {
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: frameRect, transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length == 0 { break }
                pages.append((setter, CFRange(location: start, length: visible.length)))
                start += visible.length
            }
        }
        if pages.isEmpty {
            let empty = CTFramesetterCreateWithAttributedString(NSAttributedString(string: " "))
            pages.append((empty, CFRange(location: 0, length: 1)))
        }

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let footerAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: muted]
        for (i, (setter, range)) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            let frame = CTFramesetterCreateFrame(setter, range, CGPath(rect: frameRect, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            let foot = CTLineCreateWithAttributedString(NSAttributedString(string: "\(footer)  ·  \(i + 1) of \(pages.count)", attributes: footerAttrs))
            ctx.textPosition = CGPoint(x: margins.left, y: 30)
            CTLineDraw(foot, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
