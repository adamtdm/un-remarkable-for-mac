import AppKit
import CoreText

/// Lays out a page's typed text, including line wrapping.
///
/// The parser and the renderer both use this layout. Ink written next to typed text is anchored to
/// characters, so the anchors must come from the same wrapped layout that is drawn. Otherwise a long
/// wrapped paragraph pushes the text down while the ink stays where it was, and they overlap.
public enum TypedTextLayout {
    public struct Line: @unchecked Sendable {
        public let line: CTLine
        public let baselineY: CGFloat
        /// UTF-16 offset of the line's first character within the paragraph text.
        public let start: Int
    }

    public struct Paragraph: @unchecked Sendable {
        public let style: ParagraphStyle
        /// Top of the paragraph's slot; ink anchored to the paragraph start sits relative to this.
        public let slotY: CGFloat
        public let x: CGFloat
        public let lines: [Line]
        public let pitch: CGFloat

        /// The y anchor for the character at a UTF-16 offset: the baseline of the line that holds it.
        ///
        /// rmscene and the web app anchor to the top of the paragraph slot instead, but strokes the tablet
        /// anchors to characters (a circle round a word) land a full line too high that way. Baselines
        /// put them on the text they were drawn around.
        public func anchorY(forOffset offset: Int) -> CGFloat {
            guard !lines.isEmpty else { return slotY + CGFloat(style.lineHeight) }
            let index = lines.lastIndex { $0.start <= offset } ?? 0
            return lines[index].baselineY
        }
    }

    public static func font(for style: ParagraphStyle) -> NSFont {
        switch style {
        case .heading: return .systemFont(ofSize: 42, weight: .semibold)
        case .bold: return .systemFont(ofSize: 28, weight: .semibold)
        default: return .systemFont(ofSize: 26, weight: .regular)
        }
    }

    public static func indent(for style: ParagraphStyle) -> CGFloat { style == .bullet2 ? 24 : 0 }

    /// Returns each paragraph's layout and the y just below the last paragraph.
    public static func layout(_ paragraphs: [TypedParagraph], posX: Float, posY: Float, width: Float) -> ([Paragraph], CGFloat) {
        var y = CGFloat(posY + RmParser.textTopY)
        let x = CGFloat(posX)
        let fullWidth = CGFloat(max(width, 400))
        var out: [Paragraph] = []
        out.reserveCapacity(paragraphs.count)

        for p in paragraphs {
            let slot = y
            let font = font(for: p.style)
            let pitch = ceil(font.ascender - font.descender + font.leading)
            y += CGFloat(p.style.lineHeight)

            var lines: [Line] = []
            if !p.text.trimmingCharacters(in: .whitespaces).isEmpty {
                let str = NSAttributedString(string: p.text, attributes: [
                    .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ])
                let typesetter = CTTypesetterCreateWithAttributedString(str)
                let total = str.length
                let avail = Double(fullWidth - indent(for: p.style))
                var start = 0
                var baseline = y
                while start < total {
                    var count = CTTypesetterSuggestLineBreak(typesetter, start, avail)
                    if count <= 0 { count = total - start }
                    let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                    lines.append(Line(line: line, baselineY: baseline, start: start))
                    start += count
                    if start < total { baseline += pitch }
                }
                y = baseline
            }
            out.append(Paragraph(style: p.style, slotY: slot, x: x + indent(for: p.style), lines: lines, pitch: pitch))
        }
        return (out, y)
    }
}
