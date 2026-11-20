import RMKit
import SwiftUI
import WebKit

struct EpubReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let doc: DocumentItem

    @State private var book: EpubBook?
    @State private var chapter = 0
    @State private var error: String?
    @State private var showTOC = true
    @AppStorage("epubFontScale") private var fontScale = 1.0

    var body: some View {
        HStack(spacing: 0) {
            if showTOC, let book {
                List(book.chapters, selection: Binding(get: { chapter }, set: { if let c = $0 { chapter = c } })) { c in
                    Text(c.title).lineLimit(2).tag(c.id)
                }
                .frame(width: 230)
                Divider()
            }
            Group {
                if let book {
                    EpubWebView(chapter: book.chapters[chapter], root: book.root, dark: scheme == .dark, fontScale: fontScale)
                        .id(book.chapters[chapter].id)
                } else if let error {
                    ContentUnavailableView("Could not open book", systemImage: "book.closed", description: Text(error))
                } else {
                    ProgressView("Downloading book…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Toggle(isOn: $showTOC) { Image(systemName: "sidebar.left") }.toggleStyle(.button).help("Contents")
                    .accessibilityLabel("Contents")
                Spacer(minLength: 12)
                Button { chapter = max(chapter - 1, 0) } label: { Image(systemName: "chevron.left") }
                    .disabled(chapter == 0).keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel("Previous chapter")
                Text(book.map { "chapter \(chapter + 1) of \($0.chapters.count)" } ?? "").font(.mono(12)).monospacedDigit().foregroundStyle(Paper.textMuted)
                Button { chapter = min(chapter + 1, (book?.chapters.count ?? 1) - 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(chapter >= (book?.chapters.count ?? 1) - 1).keyboardShortcut("]", modifiers: .command)
                    .accessibilityLabel("Next chapter")
                Button { fontScale = max(0.7, fontScale - 0.1) } label: { Image(systemName: "textformat.size.smaller") }
                    .keyboardShortcut("-", modifiers: .command)
                    .accessibilityLabel("Smaller text")
                Button { fontScale = min(2.0, fontScale + 0.1) } label: { Image(systemName: "textformat.size.larger") }
                    .keyboardShortcut("=", modifiers: .command)
                    .accessibilityLabel("Larger text")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, Columns.gutter)
            .frame(height: 36)
            .background(Paper.background)
            .overlay(alignment: .bottom) { Rectangle().fill(Paper.border).frame(height: 1) }
        }
        .task(id: doc.hash) {
            do {
                let b = try await EpubBook.load(doc, sync: model.sync, cacheDir: model.paths.epubs)
                // The newer of the Mac's chapter and the tablet's page (mapped by how far through the book).
                let localChapter = min(UserDefaults.standard.integer(forKey: "epub.\(doc.id).chapter"), b.chapters.count - 1)
                let localTime = UserDefaults.standard.double(forKey: "epub.\(doc.id).time")
                let tabletTime = doc.lastOpened?.timeIntervalSince1970 ?? 0
                if tabletTime > localTime + 60, doc.displayPageCount > 1, doc.lastOpenedPage > 0 {
                    chapter = b.chapter(atFraction: Double(doc.lastOpenedPage) / Double(doc.displayPageCount))
                } else {
                    chapter = localChapter
                }
                book = b
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onChange(of: chapter) {
            UserDefaults.standard.set(chapter, forKey: "epub.\(doc.id).chapter")
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "epub.\(doc.id).time")
            // Sync back to the tablet as the page the same distance through its paginated copy.
            if let book, doc.displayPageCount > 1 {
                model.readingPositionChanged(doc, page: Int(book.fraction(ofChapter: chapter) * Double(doc.displayPageCount)))
            }
        }
    }
}

/// Shows one chapter with a reading stylesheet that follows the app's light/dark theme.
struct EpubWebView: NSViewRepresentable {
    let chapter: EpubBook.Chapter
    let root: URL
    let dark: Bool
    let fontScale: Double

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.setValue(false, forKey: "drawsBackground")
        web.loadFileURL(chapter.url, allowingReadAccessTo: root)
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.css = css
        web.evaluateJavaScript(Coordinator.inject(css))
    }

    func makeCoordinator() -> Coordinator { Coordinator(css: css) }

    var css: String {
        let bg = dark ? "#18181b" : "#fbfaf7"
        let fg = dark ? "#e4e4e7" : "#1c1917"
        let link = dark ? "#93c5fd" : "#1d4ed8"
        return """
        html { background: \(bg) !important; }
        body { background: \(bg) !important; color: \(fg) !important; max-width: 40em; margin: 2.5em auto !important;
               padding: 0 1.5em !important; font: \(Int(18 * fontScale))px/1.6 "New York", Georgia, serif !important; }
        p, li, span, div, h1, h2, h3, h4, h5, h6, blockquote { color: \(fg) !important; background: transparent !important; }
        a { color: \(link) !important; }
        img, svg { max-width: 100% !important; height: auto !important; \(dark ? "filter: brightness(0.9);" : "") }
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var css: String
        init(css: String) { self.css = css }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            web.evaluateJavaScript(Self.inject(css))
        }

        static func inject(_ css: String) -> String {
            let escaped = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
            return """
            (function(){ var s = document.getElementById('unremarkable-style');
              if (!s) { s = document.createElement('style'); s.id = 'unremarkable-style'; (document.head || document.documentElement).appendChild(s); }
              s.textContent = `\(escaped)`; })();
            """
        }
    }
}
