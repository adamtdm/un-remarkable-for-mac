import Foundation

public struct Rgba: Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public var a: Double
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    /// Unpacks the ARGB uint32 used for explicit colours in v6 files.
    init(argb: UInt32) {
        self.init(UInt8((argb >> 16) & 0xFF), UInt8((argb >> 8) & 0xFF), UInt8(argb & 0xFF), Double((argb >> 24) & 0xFF) / 255)
    }
}

public enum PenColor: Int, Sendable, CaseIterable {
    case black = 0, gray, white, yellow, green, pink, blue, red, grayOverlap, highlight, green2, cyan, magenta, yellow2
    public init(raw: Int) { self = PenColor(rawValue: raw) ?? .black }
}

public enum ToolType: Sendable {
    case paintbrush, pencil, ballpoint, marker, fineliner, highlighter, eraser, mechanicalPencil, calligraphy, shader

    public init(raw: Int) {
        switch raw {
        case 0, 12: self = .paintbrush
        case 1, 14: self = .pencil
        case 2, 15: self = .ballpoint
        case 3, 16: self = .marker
        case 4, 17: self = .fineliner
        case 5, 18: self = .highlighter
        case 6, 8: self = .eraser
        case 7, 13: self = .mechanicalPencil
        case 21: self = .calligraphy
        case 23: self = .shader
        default: self = .ballpoint
        }
    }

    public var isPressureSensitive: Bool {
        switch self {
        case .ballpoint, .pencil, .paintbrush, .calligraphy: return true
        default: return false
        }
    }
}

public struct StrokePoint: Sendable, Equatable {
    public var x: Float, y: Float
    public var speed: Float
    public var direction: Float
    public var width: Float
    /// Normalised 0…1.
    public var pressure: Float
}

public struct Stroke: Sendable {
    public var tool: ToolType
    public var color: PenColor
    public var thicknessScale: Float
    public var points: [StrokePoint]
    public var explicitColor: Rgba?
}

public struct Layer: Sendable {
    public var name: String
    public var strokes: [Stroke]
}

public struct HighlightRect: Sendable {
    public var x: Float, y: Float, w: Float, h: Float
    public var color: PenColor
    public var explicitColor: Rgba?
    /// Highlighted text (PDF/EPUB smart highlights); empty on continuation rects.
    public var text: String = ""
}

public enum ParagraphStyle: Int, Sendable {
    case basic = 0, plain, heading, bold, bullet, bullet2, checkbox, checkboxChecked

    public init(code: Int) { self = ParagraphStyle(rawValue: code) ?? .plain }

    public var lineHeight: Float {
        switch self {
        case .heading: return 140
        case .bullet, .bullet2, .checkbox, .checkboxChecked: return 45
        default: return 70
        }
    }
}

public struct TypedParagraph: Sendable, Equatable {
    public var text: String
    public var style: ParagraphStyle
}

/// A parsed `.rm` page. Coordinates are in tablet pixels; v6 files put x=0 at the page centre.
public struct RmPage: Sendable {
    public static let rm2Size = (width: 1404, height: 1872)
    public static let paperProSize = (width: 1620, height: 2160)

    public var width = RmPage.rm2Size.width
    public var height = RmPage.rm2Size.height
    public var layers: [Layer] = []
    public var centerOriginX = false
    public var highlights: [HighlightRect] = []
    public var paragraphs: [TypedParagraph] = []
    public var textPosX: Float = -468
    public var textPosY: Float = 234
    public var textWidth: Float = 936

    public var hasContent: Bool {
        layers.contains { !$0.strokes.isEmpty } || !highlights.isEmpty || paragraphs.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Typed text as Markdown-ish plain text, for search and AI context.
    public var plainText: String {
        paragraphs.map { p in
            switch p.style {
            case .heading: return "# " + p.text
            case .bullet, .bullet2: return "- " + p.text
            case .checkbox: return "- [ ] " + p.text
            case .checkboxChecked: return "- [x] " + p.text
            default: return p.text
            }
        }.joined(separator: "\n")
    }

    /// Bounding box of all ink in page coordinates (origin top-left).
    public var inkBounds: CGRect? {
        var minX = Float.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
        let dx: Float = centerOriginX ? Float(width) / 2 : 0
        for l in layers { for s in l.strokes where s.tool != .eraser { for p in s.points {
            minX = min(minX, p.x + dx); maxX = max(maxX, p.x + dx); minY = min(minY, p.y); maxY = max(maxY, p.y)
        } } }
        guard minX <= maxX else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }
}

public struct StrokeStyle: Sendable {
    public var width: Float
    public var opacity: Float
    public enum Cap: Sendable { case round, square, butt }
    public var cap: Cap = .round
    public var multiply = false
}

public enum WritingTools {
    /// Approximates each reMarkable brush with width and opacity driven by pressure.
    public static func style(_ tool: ToolType, thickness: Float, pressure: Float) -> StrokeStyle {
        let p = min(max(pressure > 1 ? pressure / 255 : pressure, 0), 1)
        let w = max(thickness, 0.5)
        switch tool {
        case .fineliner: return StrokeStyle(width: max(w * 1.8, 0.5), opacity: 1)
        case .ballpoint: return StrokeStyle(width: max(w * 1.5 * (0.6 + 0.8 * p), 0.5), opacity: min(max(0.7 + 0.3 * p, 0.6), 1))
        case .marker: return StrokeStyle(width: max(w * 3.2, 1), opacity: 1)
        case .highlighter: return StrokeStyle(width: 28, opacity: 0.4, cap: .square, multiply: true)
        case .shader: return StrokeStyle(width: max(w * 6, 8), opacity: 0.35, multiply: true)
        case .pencil: return StrokeStyle(width: max(w * 1.6 * (0.7 + 0.6 * p), 0.6), opacity: min(max(0.4 + 0.5 * p, 0.25), 0.95))
        case .mechanicalPencil: return StrokeStyle(width: max(w * 1.2, 0.5), opacity: 0.85)
        case .calligraphy: return StrokeStyle(width: max(w * 3.5 * (0.4 + 0.6 * p), 1), opacity: 1, cap: .butt)
        case .eraser: return StrokeStyle(width: w * 4, opacity: 0)
        case .paintbrush: return StrokeStyle(width: max(w * 4 * (0.3 + 1.4 * p), 1), opacity: 0.9)
        }
    }
}

/// Pen palettes shared with the web and Android apps. Dark mode inverts lightness, keeps hue.
public enum RmPalette {
    static let light: [PenColor: Rgba] = [
        .black: Rgba(24, 24, 27), .gray: Rgba(140, 140, 145), .white: Rgba(255, 255, 255),
        .yellow: Rgba(234, 179, 8), .green: Rgba(34, 197, 94), .pink: Rgba(244, 114, 182),
        .blue: Rgba(37, 99, 235), .red: Rgba(220, 38, 38), .grayOverlap: Rgba(115, 115, 120),
        .highlight: Rgba(250, 204, 21), .green2: Rgba(132, 204, 22), .cyan: Rgba(6, 182, 212),
        .magenta: Rgba(168, 85, 247), .yellow2: Rgba(250, 204, 21),
    ]
    static let dark: [PenColor: Rgba] = [
        .black: Rgba(244, 244, 245), .gray: Rgba(161, 161, 170), .white: Rgba(39, 39, 42),
        .yellow: Rgba(253, 224, 71), .green: Rgba(74, 222, 128), .pink: Rgba(244, 114, 182),
        .blue: Rgba(96, 165, 250), .red: Rgba(248, 113, 113), .grayOverlap: Rgba(161, 161, 170),
        .highlight: Rgba(253, 224, 71), .green2: Rgba(163, 230, 53), .cyan: Rgba(56, 189, 248),
        .magenta: Rgba(192, 132, 252), .yellow2: Rgba(254, 240, 138),
    ]

    public static let paperLight = Rgba(255, 255, 255)
    public static let paperDark = Rgba(24, 24, 27)

    public static func color(_ pen: PenColor, dark isDark: Bool, explicit: Rgba? = nil) -> Rgba {
        if let e = explicit {
            guard isDark else { return e }
            let lum = 0.2126 * Double(e.r) + 0.7152 * Double(e.g) + 0.0722 * Double(e.b)
            if lum < 50 { return Rgba(244, 244, 245, e.a) }
            if lum > 200 { return Rgba(39, 39, 42, e.a) }
            return e
        }
        return (isDark ? dark : light)[pen] ?? (isDark ? dark : light)[.black]!
    }
}
