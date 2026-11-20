import RMKit
import SwiftUI

struct ReaderWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("readerTheme") private var theme: ReaderTheme = .system
    let docID: String

    var body: some View {
        Group {
            if let doc = model.byID[docID] {
                if doc.kind == .epub {
                    EpubReaderView(doc: doc)
                } else {
                    PageReaderView(doc: doc)
                }
            } else {
                ContentUnavailableView("Document unavailable", systemImage: "doc.questionmark",
                                       description: Text("It may have been deleted on your tablet."))
            }
        }
        .appAppearance()
        .navigationTitle(model.byID[docID]?.name ?? "Reader")
    }
}

enum ReaderPanel: String, CaseIterable, Identifiable {
    case pages, contents, bookmarks, highlights
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum FitMode: String { case page, width }

/// Per-document reader preferences, remembered like the web app's reader.
struct ReaderPrefs: Codable, Equatable {
    var spread = false
    var rtl = false
    var fit = "page"
    var invert: Bool? = nil
    /// Bookmarked page indexes (optional so prefs saved before bookmarks still decode).
    var bookmarks: [Int]? = nil

    static func load(_ id: String) -> ReaderPrefs {
        guard let d = UserDefaults.standard.data(forKey: "reader.\(id)"),
              let p = try? JSONDecoder().decode(ReaderPrefs.self, from: d) else { return ReaderPrefs() }
        return p
    }

    func save(_ id: String) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "reader.\(id)") }
    }
}

struct PageReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @AppStorage("invertPDFs") private var invertPDFsDefault = true
    @AppStorage("spreadCoverAlone") private var coverAlone = true
    @AppStorage("readerPageTurn") private var pageTurn = "both"
    let doc: DocumentItem
    @State private var hudVisible = true
    @State private var hudTimer = 0
    @State private var editingText = false
    @State private var convertingHandwriting = false

    @State private var page = 0
    @State private var count = 1
    @State private var prefs = ReaderPrefs()
    @State private var images: [Int: ImageBox] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var panel: ReaderPanel?
    @State private var showJump = false
    @State private var jumpText = ""
    @State private var outline: [OutlineItem] = []
    @State private var highlights: [HighlightItem]?
    @State private var viewWidth: CGFloat = 900
    @FocusState private var focused: Bool

    private var dark: Bool { scheme == .dark }
    /// First page of the spread containing `p`. With "cover alone", page 0 is its own spread.
    private func spreadStart(_ p: Int) -> Int {
        guard prefs.spread, count > 1 else { return p }
        if coverAlone { return p == 0 ? 0 : p - ((p - 1) % 2) }
        return p - p % 2
    }

    private var visible: [Int] {
        let start = spreadStart(page)
        guard prefs.spread, count > 1, !(coverAlone && start == 0) else { return [start] }
        let pair = [start, start + 1].filter { $0 < count }
        return prefs.rtl ? pair.reversed() : pair
    }

    private var options: RenderOptions {
        let invert: Bool? = prefs.invert ?? (invertPDFsDefault ? nil : false)
        let perPage = prefs.spread ? viewWidth / 2 : viewWidth
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let px = min(2600, max(600, Int((perPage * scale / 200).rounded(.up)) * 200))
        return RenderOptions(dark: dark, invertPDF: invert, pixelWidth: px)
    }

    var body: some View {
        VStack(spacing: 0) {
            readerBar
            HStack(spacing: 0) {
            if let panel {
                ReaderSidebar(doc: doc, panel: panel, count: count, current: page, outline: outline,
                              highlights: highlights, bookmarks: prefs.bookmarks ?? [], dark: dark, go: go)
                    .frame(width: 230)
                Rectangle().fill(Paper.border).frame(width: 1)
            }
            pageArea
            }
            .background(dark ? Color(red: 0.07, green: 0.07, blue: 0.07) : Paper.raised)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space, .pageUp, .pageDown, .home, .end, .upArrow, .downArrow]) { press in
            switch press.key {
            case .rightArrow: flip(prefs.rtl ? -1 : 1)
            case .leftArrow: flip(prefs.rtl ? 1 : -1)
            case .space, .pageDown, .downArrow: flip(press.modifiers.contains(.shift) ? -1 : 1)
            case .pageUp, .upArrow: flip(-1)
            case .home: go(0)
            case .end: go(count - 1)
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress("g") { showJump = true; return .handled }
        .onKeyPress("b") { toggleBookmark(); return .handled }
        .sheet(isPresented: $editingText) { PageTextEditor(doc: doc, page: page).environment(model) }
        .sheet(isPresented: $convertingHandwriting) { HandwritingTextSheet(doc: doc, page: page).environment(model) }
        .task(id: doc.id) { await open() }
        .task(id: renderKey) { await render() }
        .onChange(of: prefs) { prefs.save(doc.id) }
        .onChange(of: page) { model.readingPositionChanged(doc, page: page) }
        .onAppear { focused = true }
    }

    private var renderKey: String { "\(doc.hash)|\(visible)|\(options.pixelWidth)|\(dark)|\(String(describing: options.invertPDF))|\(count)" }

    // MARK: Page area

    private var pageArea: some View {
        GeometryReader { geo in
            ScrollView(prefs.fit == FitMode.width.rawValue ? .vertical : []) {
                HStack(spacing: prefs.spread ? 2 : 0) {
                    ForEach(visible, id: \.self) { i in
                        pageView(i, size: geo.size)
                    }
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .overlay { if pageTurn != "swipe" { edgeZones } }
            .overlay(alignment: .bottom) {
                pageScrubber.padding(.bottom, 12)
                    .opacity(hudVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: hudVisible)
            }
            .background {
                if pageTurn != "tap" {
                    SwipePager { dir in flip(prefs.rtl ? -dir : dir) }
                }
            }
            .onContinuousHover { phase in
                if case .active = phase { showHUD() }
            }
            .onAppear { viewWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in viewWidth = w }
        }
    }

    @ViewBuilder
    private func pageView(_ i: Int, size: CGSize) -> some View {
        let perW = (size.width - 40) / CGFloat(visible.count)
        let perH = size.height - 40
        if let box = images[i] {
            let aspect = CGFloat(box.image.width) / CGFloat(max(box.image.height, 1))
            let fitWidth = prefs.fit == FitMode.width.rawValue
            let w = fitWidth ? perW : min(perW, perH * aspect)
            Image(decorative: box.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: w, height: w / aspect)
                .shadow(color: .black.opacity(dark ? 0.5 : 0.2), radius: 6, y: 2)
                .overlay(alignment: .topTrailing) {
                    if prefs.bookmarks?.contains(i) == true {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.red)
                            .padding(.trailing, 18)
                            .offset(y: -3)
                            .help("Bookmarked (B)")
                    }
                }
                .padding(.vertical, 20)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(dark ? Color(white: 0.11) : .white)
                if let error { Text(error).foregroundStyle(.secondary).padding() } else { ProgressView() }
            }
            .frame(width: min(perW, perH * 0.75), height: min(perW, perH * 0.75) / 0.75)
            .padding(.vertical, 20)
        }
    }

    /// Click the outer fifths of the page to turn pages, like the tablet and the web reader.
    private var edgeZones: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).onTapGesture { flip(prefs.rtl ? 1 : -1) }
            Color.clear.frame(maxWidth: .infinity).frame(maxWidth: .infinity).allowsHitTesting(false)
            Color.clear.frame(maxWidth: .infinity).allowsHitTesting(false)
            Color.clear.frame(maxWidth: .infinity).allowsHitTesting(false)
            Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).onTapGesture { flip(prefs.rtl ? -1 : 1) }
        }
    }

    private var pageScrubber: some View {
        HStack(spacing: 10) {
            Button { flip(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).disabled(page == 0)
            if count > 1 {
                Slider(value: Binding(get: { Double(page) }, set: { go(Int($0.rounded())) }), in: 0...Double(count - 1))
                    .frame(width: 220)
                    .controlSize(.small)
            }
            Button { showJump = true } label: {
                Text(visible.count > 1 ? "\(visible.map { $0 + 1 }.sorted().map(String.init).joined(separator: "–")) / \(count)" : "\(page + 1) / \(count)")
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .help("Go to page (G)")
            .popover(isPresented: $showJump) {
                HStack {
                    TextField("Page", text: $jumpText).frame(width: 70)
                        .onSubmit {
                            if let n = Int(jumpText) { go(n - 1) }
                            showJump = false
                            jumpText = ""
                        }
                    Text("of \(count)").foregroundStyle(.secondary)
                }
                .padding(10)
            }
            Button { flip(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).disabled(page >= count - 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
    }

    // MARK: Toolbar

    /// The reader's controls, in a slim bar at the top of its pane (not the window toolbar).
    private var readerBar: some View {
        HStack(spacing: 12) {
            Picker("Sidebar", selection: $panel) {
                Image(systemName: "rectangle.portrait").tag(ReaderPanel?.none).help("Hide sidebar")
                Image(systemName: "square.grid.3x3").tag(ReaderPanel?.some(.pages)).help("Pages")
                if doc.kind == .pdf { Image(systemName: "list.bullet.indent").tag(ReaderPanel?.some(.contents)).help("Contents") }
                Image(systemName: "bookmark").tag(ReaderPanel?.some(.bookmarks)).help("Bookmarks")
                Image(systemName: "highlighter").tag(ReaderPanel?.some(.highlights)).help("Highlights")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(count > 0 ? "page \(page + 1) of \(count)" : "").font(.mono(12)).foregroundStyle(Paper.textMuted).monospacedDigit()
            Spacer(minLength: 12)
            Group {
            if doc.kind == .notebook {
                Button { editingText = true } label: { Image(systemName: "character.cursor.ibeam") }
                    .help("Edit this page's typed text")
                    .accessibilityLabel("Edit typed text")
                    .disabled(!model.isPaired)
                Button { convertingHandwriting = true } label: { Image(systemName: "text.viewfinder") }
                    .help("Convert handwriting to text")
                    .accessibilityLabel("Convert handwriting to text")
                    .disabled(!model.isPaired)
            }
            Button(action: toggleBookmark) {
                Image(systemName: prefs.bookmarks?.contains(page) == true ? "bookmark.fill" : "bookmark")
            }
            .help(prefs.bookmarks?.contains(page) == true ? "Remove bookmark (B)" : "Bookmark this page (B)")
            AppearanceToggle()
            Toggle(isOn: $prefs.spread) { Image(systemName: "book.pages") }.help("Two-page view").toggleStyle(.button)
                .accessibilityLabel("Two-page view")
            if prefs.spread {
                Toggle(isOn: $prefs.rtl) { Image(systemName: "arrow.left.to.line") }.help("Right-to-left (manga)").toggleStyle(.button)
                    .accessibilityLabel("Right to left")
            }
            Picker("Fit", selection: $prefs.fit) {
                Image(systemName: "arrow.up.and.down.square").tag(FitMode.page.rawValue).help("Fit page")
                Image(systemName: "arrow.left.and.right.square").tag(FitMode.width.rawValue).help("Fit width")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if doc.kind == .pdf, dark {
                Menu {
                    Picker("Dark PDF pages", selection: $prefs.invert) {
                        Text("Automatic").tag(Bool?.none)
                        Text("Always darken").tag(Bool?.some(true))
                        Text("Original colours").tag(Bool?.some(false))
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: "circle.lefthalf.filled") }
                .help("Dark mode for this PDF")
                .menuIndicator(.hidden)
                .fixedSize()
            }
            }
            .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, Columns.gutter)
        .frame(height: 36)
        .background(Paper.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.border).frame(height: 1) }
    }

    // MARK: Actions

    private func open() async {
        prefs = ReaderPrefs.load(doc.id)
        count = await model.renderer.pageCount(doc)
        // A jump request (e.g. from a task) wins over the saved position.
        let jumpKey = "reader.openPage.\(doc.id)"
        let wanted = UserDefaults.standard.object(forKey: jumpKey) as? Int ?? doc.lastOpenedPage
        UserDefaults.standard.removeObject(forKey: jumpKey)
        page = min(max(wanted, 0), max(count - 1, 0))
        if doc.kind == .pdf {
            outline = await model.renderer.outline(doc)
            count = await model.renderer.pageCount(doc)
        }
    }

    private func render() async {
        error = nil
        let wanted = visible
        let opts = options
        for i in wanted {
            do {
                if let box = try await model.renderer.page(doc, index: i, options: opts) { images[i] = box }
            } catch {
                self.error = error.localizedDescription
            }
            if Task.isCancelled { return }
        }
        images = images.filter { wanted.contains($0.key) }
        await model.renderer.prefetch(doc, around: wanted.max() ?? page, count: count, options: opts)
        if highlights == nil, panel == .highlights { highlights = await model.renderer.highlights(doc) }
    }

    private func toggleBookmark() {
        var marks = Set(prefs.bookmarks ?? [])
        if marks.contains(page) { marks.remove(page) } else { marks.insert(page) }
        prefs.bookmarks = marks.sorted()
    }

    /// Shows the page bar; in full screen it fades out after a few seconds without mouse movement.
    private func showHUD() {
        hudVisible = true
        hudTimer += 1
        let token = hudTimer
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard token == hudTimer, NSApp.keyWindow?.styleMask.contains(.fullScreen) == true else { return }
            hudVisible = false
        }
    }

    private func flip(_ dir: Int) {
        let start = spreadStart(page)
        if dir > 0 {
            go(start + visible.count)
        } else if start > 0 {
            go(spreadStart(start - 1))
        }
    }

    private func go(_ i: Int) {
        let target = min(max(i, 0), max(count - 1, 0))
        if target != page { page = target }
    }
}

// MARK: - Sidebar

struct ReaderSidebar: View {
    @Environment(AppModel.self) private var model
    let doc: DocumentItem
    let panel: ReaderPanel
    let count: Int
    let current: Int
    let outline: [OutlineItem]
    let highlights: [HighlightItem]?
    var bookmarks: [Int] = []
    let dark: Bool
    let go: (Int) -> Void
    @State private var loadedHighlights: [HighlightItem]?

    var body: some View {
        switch panel {
        case .pages:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<count, id: \.self) { i in
                            PageThumb(doc: doc, index: i, dark: dark, selected: i == current)
                                .id(i)
                                .onTapGesture { go(i) }
                        }
                    }
                    .padding(14)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
                .onChange(of: current) { _, c in withAnimation { proxy.scrollTo(c, anchor: .center) } }
            }
        case .contents:
            if outline.isEmpty {
                ContentUnavailableView("No table of contents", systemImage: "list.bullet.indent")
            } else {
                List(outline) { item in
                    Button { go(item.pageIndex) } label: {
                        HStack {
                            Text(item.title).lineLimit(2).padding(.leading, CGFloat(item.depth) * 12)
                            Spacer()
                            Text("\(item.pageIndex + 1)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        case .bookmarks:
            if bookmarks.isEmpty {
                ContentUnavailableView("No bookmarks", systemImage: "bookmark",
                                       description: Text("Press B or click the bookmark button to mark a page."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(bookmarks.filter { $0 < count }, id: \.self) { i in
                            PageThumb(doc: doc, index: i, dark: dark, selected: i == current)
                                .onTapGesture { go(i) }
                        }
                    }
                    .padding(12)
                }
            }
        case .highlights:
            Group {
                if let items = highlights ?? loadedHighlights {
                    if items.isEmpty {
                        ContentUnavailableView("No highlights", systemImage: "highlighter",
                                               description: Text("Highlight text on your reMarkable and it appears here."))
                    } else {
                        List(items) { h in
                            Button { go(h.pageIndex) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(h.text).lineLimit(6)
                                    Text("Page \(h.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.leading, 8)
                                .overlay(alignment: .leading) { Rectangle().fill(h.swatch).frame(width: 3) }
                            }
                            .buttonStyle(.plain)
                        }
                        .safeAreaInset(edge: .bottom) {
                            Button("Copy as Markdown") { copyMarkdown(items) }.padding(8)
                        }
                    }
                } else {
                    ProgressView("Reading highlights…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task { if highlights == nil { loadedHighlights = await model.renderer.highlights(doc) } }
        }
    }

    private func copyMarkdown(_ items: [HighlightItem]) {
        var md = "# \(doc.name)\n\n"
        for h in items { md += "> \(h.text.replacingOccurrences(of: "\n", with: " "))\n\n— page \(h.pageIndex + 1)\n\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }
}

extension HighlightItem {
    var swatch: SwiftUI.Color {
        switch color {
        case .rgb(let r, let g, let b): return SwiftUI.Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .pen(let raw):
            let c = RmPalette.color(PenColor(raw: raw), dark: false)
            return SwiftUI.Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }
    }
}

struct PageThumb: View {
    @Environment(AppModel.self) private var model
    let doc: DocumentItem
    let index: Int
    let dark: Bool
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(0.75, contentMode: .fit)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text("\(index + 1)").font(.caption).foregroundStyle(selected ? .primary : .secondary)
        }
        .task(id: "\(doc.hash)-\(index)-\(dark)") {
            image = try? await model.renderer.page(doc, index: index, options: RenderOptions(dark: dark, invertPDF: nil, pixelWidth: 240))?.image
        }
    }
}

/// Light/dark switch for the reader toolbar. Dark mode changes how artwork and colour pages look,
/// so it's one click away rather than only in Settings. It switches the whole app.
struct AppearanceToggle: View {
    @AppStorage("readerTheme") private var theme: ReaderTheme = .system
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            theme = scheme == .dark ? .light : .dark
        } label: {
            Image(systemName: scheme == .dark ? "sun.max" : "moon")
        }
        .help(scheme == .dark ? "Switch to light mode" : "Switch to dark mode")
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
