import AppKit
import CoreText
import SwiftUI

/// The "Column Rules" palette: stark white or near-black, hairline rules, one pink accent.
/// (Named Paper for history; see DESIGN.md.)
enum Paper {
    static let background = dynamic(light: 0xFFFFFF, dark: 0x0B0B0C)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x0B0B0C)
    static let raised = dynamic(light: 0xF3F3F2, dark: 0x19191B)
    /// Column rules and quiet dividers.
    static let border = dynamic(light: 0xE3E3E3, dark: 0x26272A)
    static let borderStrong = dynamic(light: 0xBDBDBD, dark: 0x4A4B4F)
    /// Ruled-list lines: full ink, like a printed index.
    static let rule = dynamic(light: 0x0A0A0A, dark: 0xD9D9D6)
    static let text = dynamic(light: 0x0A0A0A, dark: 0xF1F1EE)
    static let textSecondary = dynamic(light: 0x4A4A4A, dark: 0xB5B6B9)
    static let textMuted = dynamic(light: 0x6E6E6E, dark: 0x8C8E93)
    /// The one loud colour: only on the primary action and reading progress.
    static let accent = dynamic(light: 0xE0006B, dark: 0xFF4D94)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B0B0C)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Bundled typefaces (SIL Open Font License, in Resources/Fonts).
enum AppFonts {
    static let displayFamily = "Funnel Display"
    static let monoFamily = "Geist Mono"

    /// Registers the bundled fonts for this process. Falls back to the system fonts if they're missing.
    static func register() {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "Fonts"),
            // Development runs of the bare binary: the repo's Resources/Fonts.
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/Fonts"),
        ].compactMap { $0 }
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// Grotesk display type for titles and headings (Funnel Display).
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(AppFonts.displayFamily, size: size).weight(weight)
    }

    /// Small mono labels, lists and facts (Geist Mono).
    static func mono(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font {
        .custom(AppFonts.monoFamily, size: size).weight(weight)
    }
}

/// Small lowercase mono label above a list or column.
struct SectionHeading: View {
    let text: String
    var body: some View {
        Text(text.lowercased())
            .font(.mono(12))
            .foregroundStyle(Paper.textMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Text tab used as a filter: lowercase mono, the selected one in full ink and underlined.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.lowercased())
                .lineLimit(1)
                .fixedSize()
                .font(.mono(12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Paper.text : Paper.textMuted)
                .padding(.vertical, 3)
                .overlay(alignment: .bottom) { if selected { Rectangle().fill(Paper.text).frame(height: 1) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The primary action: a flat pink block. Use once per screen.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mono(12.5, weight: .medium))
            .foregroundStyle(Paper.onAccent)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Paper.accent.opacity(configuration.isPressed ? 0.8 : 1))
    }
}

/// A quiet text action in a column header: mono, muted until hovered.
struct MonoButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { MonoLabel(configuration: configuration, prominent: prominent) }

    private struct MonoLabel: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .lineLimit(1)
                .fixedSize()
                .font(.mono(12.5, weight: prominent ? .medium : .regular))
                .foregroundStyle(!enabled ? Paper.textMuted.opacity(0.5) : (hover || prominent) ? Paper.text : Paper.textMuted)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// A plain text field sitting on a single ink rule, like the mock's search line.
struct RuledField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt.lowercased()).foregroundStyle(Paper.textMuted))
            .textFieldStyle(.plain)
            .font(.mono(12.5))
            .padding(.bottom, 3)
            .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
            .accessibilityLabel(prompt)
    }
}

/// Thin progress line; the filled part is the accent.
struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Paper.raised)
                Rectangle().fill(Paper.accent).frame(width: g.size.width * min(max(value, 0.02), 1))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

extension ReaderTheme {
    var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}

extension View {
    /// Applies the app-wide appearance preference (Settings › Reader › Appearance, or the reader's switch).
    func appAppearance() -> some View { modifier(AppAppearance()) }
}

struct AppAppearance: ViewModifier {
    @AppStorage("readerTheme") private var theme: ReaderTheme = .system
    func body(content: Content) -> some View { content.preferredColorScheme(theme.colorScheme) }
}
