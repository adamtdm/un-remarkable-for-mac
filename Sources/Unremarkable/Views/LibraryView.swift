import RMKit
import SwiftUI
import UniformTypeIdentifiers

enum SortOrder: String, CaseIterable, Identifiable {
    case modified, opened, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modified: return "Date Modified"
        case .opened: return "Last Opened"
        case .name: return "Name"
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var section: LibrarySection? = .folder("")
    @State private var searchText = ""
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Workspace(section: $section, searchText: $searchText)
        }
        .toolbar {
            ToolbarItem(placement: .principal) { SectionTabs(section: $section) }
            ToolbarItem(placement: .primaryAction) { ToolbarSearch(text: $searchText) }
            ToolbarItem(placement: .primaryAction) { SyncStatusButton() }
        }
        .overlay {
            if model.showCommandPalette {
                CommandPalette(navigate: { section = $0 })
            }
        }
        .onChange(of: section) { model.activePane = nil }
        .onChange(of: searchText) { if !searchText.isEmpty { model.activePane = nil } }
        .appAppearance()
        .sheet(item: Binding(get: { model.converting }, set: { model.converting = $0 })) { doc in
            ConverterSheet(source: .document(doc)).environment(model)
        }
        .alert("Rename", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let doc = model.renaming { Task { await model.rename(doc, to: newName) } }
                model.renaming = nil
            }
            Button("Cancel", role: .cancel) { model.renaming = nil }
        } message: {
            Text("The new name shows on your reMarkable after it syncs.")
        }
        .onChange(of: model.renaming?.id) { newName = model.renaming?.name ?? "" }
        .task {
            // Development aid: UNREMARKABLE_OPEN=<id>,<id> opens those documents at launch.
            let env = ProcessInfo.processInfo.environment
            // UNREMARKABLE_IMPORT=<markdown file> imports it as a typed notebook (development aid).
            if let path = env["UNREMARKABLE_IMPORT"] {
                for _ in 0..<60 where !model.isPaired { try? await Task.sleep(for: .milliseconds(500)) }
                await model.importMarkdown([URL(fileURLWithPath: path)], to: "")
                FileHandle.standardError.write(Data("IMPORTED \(path)\n".utf8))
            }
            // UNREMARKABLE_SECTION=meetings|tasks opens that section.
            switch env["UNREMARKABLE_SECTION"] {
            case "meetings": section = .meetings
            case "tasks": section = .tasks
            case "ask": section = .ask
            case "highlights": section = .highlights
            case let s? where s.hasPrefix("folder:"): section = .folder(String(s.dropFirst(7)))
            case let s? where s.hasPrefix("search:"): searchText = String(s.dropFirst(7))
            default: break
            }
            // UNREMARKABLE_EXPORT=<dir>:<docID,…> exports documents with their ink.
            if let spec = env["UNREMARKABLE_EXPORT"], let colon = spec.firstIndex(of: ":") {
                let dir = URL(fileURLWithPath: String(spec[..<colon]))
                let docs = spec[spec.index(after: colon)...].split(separator: ",").compactMap { model.byID[String($0)] }
                let n = await model.export(docs, to: dir)
                FileHandle.standardError.write(Data("EXPORTED \(n)\n".utf8))
            }
            for id in (env["UNREMARKABLE_OPEN"] ?? "").split(separator: ",") {
                model.open(String(id))
            }
            // UNREMARKABLE_MEETING=<id> opens a meeting; UNREMARKABLE_MEETING=record starts a new recording.
            if let m = env["UNREMARKABLE_MEETING"] {
                if m == "record" { MeetingActions.toggle() } else { AppModel.shared.openMeeting(m) }
                if m != "record", env["UNREMARKABLE_WRITE_NOTES"] != nil { await MeetingRecorder.shared.generateNotes(m) }
                if let s = env["UNREMARKABLE_STOP_AFTER"].flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(s))
                    await MeetingRecorder.shared.stop()
                }
            }
        }
    }
}

// MARK: - Search

/// Search everything, in the toolbar: a mono field on a single rule. ⌘F focuses it; Esc clears it.
struct ToolbarSearch: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Paper.textMuted)
            TextField("Search", text: $text, prompt: Text("search everything, handwriting too").foregroundStyle(Paper.textMuted))
                .textFieldStyle(.plain)
                .font(.mono(12.5))
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
                .accessibilityLabel("Search titles, notes and handwriting")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Paper.textMuted)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 250, height: 26)
        .background {
            Button("Find") { focused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }
}

// MARK: - Section tabs

/// The window's main sections as lowercase text tabs in the toolbar.
struct SectionTabs: View {
    @Environment(AppModel.self) private var model
    @Binding var section: LibrarySection?

    private let tabs: [(String, LibrarySection)] = [
        ("library", .folder("")), ("meetings", .meetings), ("tasks", .tasks), ("ask", .ask), ("highlights", .highlights),
    ]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
                let (title, target) = tab
                let on = model.activePane == nil && isOn(target)
                Button {
                    model.activePane = nil
                    section = target
                } label: {
                    HStack(spacing: 5) {
                        Text(title).foregroundStyle(on ? Paper.text : Paper.textMuted)
                        if target == .tasks, !TasksModel.shared.open.isEmpty {
                            Text("\(TasksModel.shared.open.count)").foregroundStyle(Paper.textMuted).monospacedDigit()
                        }
                    }
                    .font(.mono(13, weight: on ? .medium : .regular))
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .help("\(title.capitalized) (⌘\(i + 1))")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
    }

    private func isOn(_ target: LibrarySection) -> Bool {
        let s = section ?? .folder("")
        switch target {
        case .meetings, .tasks, .ask, .highlights: return s == target
        default: return ![.meetings, .tasks, .ask, .highlights].contains(s)
        }
    }
}

// MARK: - Browser

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.columnUnit) private var unit
    @Environment(\.mainUnits) private var units
    let section: LibrarySection
    @Binding var searchText: String
    let navigate: (LibrarySection) -> Void

    @AppStorage("sortOrder") private var sort: SortOrder = .modified
    @AppStorage("libraryGrid") private var grid = true
    @State private var hits: [SearchHit] = []
    @AppStorage("searchNotesOnly") private var notesOnly = false
    @AppStorage("searchIncludeExcluded") private var includeExcluded = false
    @State private var dropTargeted = false
    @State private var filter: FileKind?
    @State private var showExcluded = false

    private var searching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if searching { searchHeader } else { header }
            if searching {
                SearchResultsView(hits: hits, open: open)
            } else {
                content
            }
        }
        .task(id: "\(searchText)|\(notesOnly)|\(includeExcluded)") {
            guard searching else { return }
            try? await Task.sleep(for: .milliseconds(120))
            hits = await model.search(searchText, notesOnly: notesOnly, includeExcluded: includeExcluded)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigation) { CreateMenu(folder: folderID) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.upload(urls, to: folderID) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                Rectangle()
                    .strokeBorder(Paper.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .overlay(Text("drop pdfs, epubs or markdown to send them to your remarkable").font(.mono(12.5))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Paper.background).overlay(Rectangle().strokeBorder(Paper.rule)))
                    .allowsHitTesting(false)
            }
        }
    }

    private var folderID: String { if case .folder(let id) = section { id } else { "" } }

    private var title: String {
        if case .folder(let id) = section, let f = model.byID[id] { return f.name }
        return section.title
    }

    private var items: [DocumentItem] {
        let raw = model.items(in: section)
        // Fixed orderings: these sections are meaningful only in their own order.
        if case .continueReading = section { return raw }
        if case .recent = section { return raw }
        return raw.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: return a.lastModified > b.lastModified
            case .opened: return (a.lastOpened ?? .distantPast) > (b.lastOpened ?? .distantPast)
            }
        }
    }

    private var isFolderView: Bool { if case .folder = section { return true } else { return false } }

    // MARK: Headers

    private var header: some View {
        ColumnHeader(title: "") {
            breadcrumbs
            Text("\(items.count)").font(.mono(12.5)).foregroundStyle(Paper.textMuted).monospacedDigit()
            Spacer(minLength: 12)
            if isFolderView {
                Chip(title: "All", selected: filter == nil && !showExcluded) { filter = nil; showExcluded = false }
                Chip(title: "Notebooks", selected: filter == .notebook && !showExcluded) { filter = .notebook; showExcluded = false }
                Chip(title: "PDFs", selected: filter == .pdf && !showExcluded) { filter = .pdf; showExcluded = false }
                Chip(title: "Books", selected: filter == .epub && !showExcluded) { filter = .epub; showExcluded = false }
                if !model.explicitExclusions.isEmpty {
                    Chip(title: "Excluded", selected: showExcluded) { filter = nil; showExcluded = true }
                }
            }
            Button(grid ? "list" : "grid") { grid.toggle() }
                .buttonStyle(MonoButtonStyle())
                .help(grid ? "Show as a list" : "Show as covers")
            if section != .continueReading && section != .recent { SortMenu(sort: $sort) }
        }
    }

    private var searchHeader: some View {
        ColumnHeader(title: "search") {
            Text("\(hits.count) result\(hits.count == 1 ? "" : "s")").font(.mono(12.5)).foregroundStyle(Paper.textMuted)
            Spacer(minLength: 12)
            Chip(title: "All documents", selected: !notesOnly) { notesOnly = false }
            Chip(title: "Notes only", selected: notesOnly) { notesOnly = true }
            Chip(title: "+ Excluded", selected: includeExcluded) { includeExcluded.toggle() }
                .help("Also search the contents of folders and documents excluded from search")
        }
    }

    /// "library / comics / …": each level goes back up.
    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            Button("library") { navigate(.folder("")) }.buttonStyle(MonoButtonStyle(prominent: true))
            Text("/").foregroundStyle(Paper.textMuted)
            if case .folder(let id) = section, !id.isEmpty {
                ForEach(model.path(to: id)) { f in
                    if f.id == id {
                        Text(f.name.lowercased()).foregroundStyle(Paper.text).truncationMode(.middle)
                    } else {
                        Button(f.name.lowercased()) { navigate(.folder(f.id)) }.buttonStyle(MonoButtonStyle())
                        Text("/").foregroundStyle(Paper.textMuted)
                    }
                }
            } else {
                Text(section.title.lowercased()).foregroundStyle(Paper.text)
            }
        }
        .font(.mono(12.5))
        .lineLimit(1)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let all = items
        let excluded = model.excludedIDs
        let list = showExcluded ? all.filter { excluded.contains($0.id) } : (filter.map { f in all.filter { $0.kind == f } } ?? all)
        let folders = list.filter(\.isFolder)
        let docs = list.filter { !$0.isFolder }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if list.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(emptyTitle.lowercased()).font(.display(26)).foregroundStyle(Paper.text)
                        Text(emptyMessage).font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                    }
                    .padding(.horizontal, Columns.gutter).padding(.top, 14)
                }
                if !folders.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeading(text: "folders").padding(.horizontal, Columns.gutter)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: max(units, 1)),
                                  alignment: .leading, spacing: 0) {
                            ForEach(folders) { f in
                                RuledRow(title: f.name, trailing: "\(model.children[f.id, default: []].filter { !$0.isTrashed }.count)") { open(f) }
                                    .contextMenu { DocumentMenu(doc: f, open: open, navigate: navigate) }
                                    .organisable(f)
                                    .padding(.horizontal, Columns.gutter)
                            }
                        }
                    }
                    .padding(.top, 14)
                }
                if !docs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !folders.isEmpty { SectionHeading(text: "documents").padding(.horizontal, Columns.gutter) }
                        if grid {
                            CoverGrid(docs: docs, navigate: navigate).padding(.top, folders.isEmpty ? 14 : 0)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(docs) { DocumentRow(doc: $0, open: open, navigate: navigate) }
                            }
                            .padding(.horizontal, Columns.gutter)
                            .padding(.top, folders.isEmpty ? 14 : 0)
                        }
                    }
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyTitle: String {
        if !model.isPaired { return "Not connected" }
        if model.isSyncing && model.documents.isEmpty { return "Syncing your library…" }
        return "Nothing here"
    }

    private var emptyMessage: String {
        switch section {
        case .continueReading: return "Books and PDFs you open on the tablet or here show up in this list."
        case .favorites: return "Star documents on your reMarkable to pin them here."
        default: return model.isSyncing ? model.progress.message : "Drop PDFs or EPUBs here to send them to your tablet."
        }
    }

    private func open(_ doc: DocumentItem) {
        if doc.isFolder { navigate(.folder(doc.id)) } else { model.open(doc.id) }
    }
}

// MARK: - Tiles and rows

/// A document as an index row: tiny cover, title, kind, pages and date, on a full-ink rule.
struct DocumentRow: View {
    let doc: DocumentItem
    let open: (DocumentItem) -> Void
    let navigate: (LibrarySection) -> Void
    @State private var hover = false

    var body: some View {
        Button { open(doc) } label: {
            HStack(spacing: 12) {
                Thumbnail(doc: doc).frame(width: 22, height: 29).clipped()
                    .overlay(Rectangle().strokeBorder(Paper.border))
                HStack(spacing: 4) {
                    if doc.pinned { Image(systemName: "star.fill").font(.system(size: 8)) }
                    Text(doc.coverTitle).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(Paper.text)
                Spacer(minLength: 12)
                ForEach(doc.tags.prefix(2), id: \.self) { Text("#" + $0).foregroundStyle(Paper.textMuted) }
                Text(doc.kind.label.lowercased()).foregroundStyle(Paper.textMuted).frame(width: 70, alignment: .leading)
                Text(doc.shortDetail).foregroundStyle(Paper.textMuted).monospacedDigit().frame(width: 150, alignment: .trailing)
            }
            .font(.mono(12.5))
            .padding(.vertical, 5)
            .background(hover ? Paper.raised : .clear)
            .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { DocumentMenu(doc: doc, open: open, navigate: navigate) }
        .help(doc.name)
        .organisable(doc)
    }
}

struct DocumentMenu: View {
    @Environment(AppModel.self) private var model
    let doc: DocumentItem
    let open: (DocumentItem) -> Void
    let navigate: (LibrarySection) -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(doc.isFolder ? "Open Folder" : "Open") { open(doc) }
        if !doc.isFolder, !doc.parent.isEmpty, doc.parent != "trash" {
            Button("Show in Folder") { navigate(.folder(doc.parent)) }
        }
        Divider()
        if doc.isTrashed {
            Button("Put Back") { Task { await model.restore(doc) } }
        } else {
            Button(doc.pinned ? "Remove from Favourites" : "Add to Favourites") { Task { await model.setFavourite(doc, !doc.pinned) } }
            Button("Rename…") { model.renaming = doc }
            Menu("Move To") {
                Button("My files") { Task { await model.move([doc], to: "") } }.disabled(doc.parent.isEmpty)
                Divider()
                ForEach(folderChoices, id: \.id) { f in
                    Button(f.label) { Task { await model.move([doc], to: f.id) } }
                        .disabled(f.id == doc.parent || f.id == doc.id || model.isAncestor(doc.id, of: f.id))
                }
            }
        }
        if !doc.isTrashed {
            if model.isExplicitlyExcluded(doc.id) {
                Button("Include in Search & Tasks") { model.setExcluded(doc, false) }
            } else if model.excludedIDs.contains(doc.id) {
                Button("Excluded by Its Folder") {}.disabled(true)
            } else {
                Button(doc.isFolder ? "Exclude Folder from Search & Tasks" : "Exclude from Search & Tasks") { model.setExcluded(doc, true) }
            }
        }
        if doc.kind == .pdf || doc.kind == .epub {
            Button("Optimise for Tablet…") { model.converting = doc }
        }
        Button("Export…") { export() }
        Button("Export as ZIP…") { exportZip() }
        Divider()
        Button("Copy Name") { copy(doc.name) }
        Button("Copy Document ID") { copy(doc.id) }
        if !doc.isTrashed {
            Divider()
            Button("Move to Trash", role: .destructive) { Task { await model.trash([doc]) } }
        }
    }

    /// All folders as an indented list for the Move To menu.
    private var folderChoices: [(id: String, label: String)] {
        var out: [(String, String)] = []
        func walk(_ parent: String, _ depth: Int) {
            for f in (model.subfolders(of: parent) ?? []) {
                out.append((f.id, String(repeating: "    ", count: depth) + f.name))
                walk(f.id, depth + 1)
            }
        }
        walk("", 0)
        return out.map { (id: $0.0, label: $0.1) }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = doc.isFolder ? "Export \"\(doc.name)\" as a folder of PDFs with your ink" : "Export \"\(doc.name)\" with your ink"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            let n = await model.export([doc], to: dir)
            model.addLog("Exported \(n) file\(n == 1 ? "" : "s") to \(dir.lastPathComponent).")
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    /// A ZIP of the document or folder tree (PDFs with ink, EPUBs as they are), like the web app's export.
    private func exportZip() {
        let panel = NSSavePanel()
        var name = doc.name.replacingOccurrences(of: "/", with: "-")
        for ext in [".pdf", ".epub"] where name.lowercased().hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        panel.nameFieldStringValue = name + ".zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            if let n = await model.exportZip(doc, to: dest) {
                model.addLog("Exported \(n) file\(n == 1 ? "" : "s") to \(dest.lastPathComponent).")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct Thumbnail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @AppStorage("readerTheme") private var theme: ReaderTheme = .system
    let doc: DocumentItem
    @State private var image: CGImage?

    private var dark: Bool { theme == .dark || (theme == .system && scheme == .dark) }

    var body: some View {
        ZStack {
            if doc.isFolder {
                Image(systemName: "folder.fill")
                    .resizable().scaledToFit().padding(18)
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            } else if let image {
                // Fill the cover area, anchored to the top of the page (like the web app's cards).
                GeometryReader { g in
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: g.size.width, height: g.size.height, alignment: .top)
                        .clipped()
                }
            } else {
                placeholder
            }
        }
        .task(id: "\(doc.hash)-\(dark)") {
            guard !doc.isFolder else { return }
            image = await model.renderer.thumbnail(doc, dark: dark)
        }
    }

    /// A plain "book cover" until the real thumbnail is available (books and PDFs aren't downloaded just to browse).
    private var placeholder: some View {
        Rectangle()
            .fill(Paper.raised)
            .overlay {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Text(doc.coverTitle)
                        .font(.display(15, weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .foregroundStyle(Paper.textSecondary)
                        .padding(.horizontal, 12)
                    Rectangle().fill(Paper.borderStrong).frame(width: 28, height: 1)
                    Spacer(minLength: 0)
                    Image(systemName: doc.kind.symbol).font(.caption).foregroundStyle(Paper.textMuted).padding(.bottom, 10)
                }
            }
    }
}

// MARK: - Search

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let hits: [SearchHit]
    let open: (DocumentItem) -> Void

    var body: some View {
        if hits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("no results").font(.display(26)).foregroundStyle(Paper.text)
                Text("Try other words, or include excluded folders.").font(.mono(12.5)).foregroundStyle(Paper.textMuted)
            }
            .padding(.horizontal, Columns.gutter).padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(hits) { hit in
                        if let doc = model.byID[hit.docID] { SearchHitRow(hit: hit, doc: doc, location: locationLine(doc), snippet: highlighted(hit.snippet), open: open) }
                    }
                }
                .padding(.horizontal, Columns.gutter).padding(.top, 14).padding(.bottom, 32)
            }
        }
    }

    private func locationLine(_ doc: DocumentItem) -> String {
        let path = model.path(to: doc.parent).map(\.name)
        return ([doc.kind.label] + (path.isEmpty ? ["My files"] : path)).joined(separator: " · ")
    }

    /// FTS snippet marks matches with « »; render them bold.
    private func highlighted(_ s: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var buf = ""
        func flush() {
            var a = AttributedString(buf)
            if bold { a.font = .mono(12, weight: .semibold); a.foregroundColor = Paper.text }
            out += a
            buf = ""
        }
        for ch in s {
            if ch == "«" { flush(); bold = true } else if ch == "»" { flush(); bold = false } else { buf.append(ch) }
        }
        flush()
        return out
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    let doc: DocumentItem
    let location: String
    let snippet: AttributedString
    let open: (DocumentItem) -> Void
    @State private var hover = false

    var body: some View {
        Button { open(doc) } label: {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(doc: doc).frame(width: 30, height: 40).clipped().overlay(Rectangle().strokeBorder(Paper.border))
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.coverTitle).font(.mono(12.5, weight: .medium)).foregroundStyle(Paper.text).lineLimit(1)
                    if !hit.snippet.isEmpty, hit.snippet != doc.name {
                        Text(snippet).font(.mono(12)).foregroundStyle(Paper.textSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Text(location.lowercased()).font(.mono(12)).foregroundStyle(Paper.textMuted).lineLimit(1)
            }
            .padding(.vertical, 8)
            .background(hover ? Paper.raised : .clear)
            .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Display helpers

extension FileKind {
    var symbol: String {
        switch self {
        case .notebook: return "pencil.and.scribble"
        case .pdf: return "doc.richtext"
        case .epub: return "book.closed"
        case .folder: return "folder"
        }
    }

    var label: String {
        switch self {
        case .notebook: return "Notebook"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .folder: return "Folder"
        }
    }

    var tint: Color {
        switch self {
        case .notebook: return .orange
        case .pdf: return .red
        case .epub: return .blue
        case .folder: return .accentColor
        }
    }
}

extension DocumentItem {
    /// Name tidied for a cover: no file extension, underscores as spaces.
    var coverTitle: String {
        var t = name
        for ext in [".pdf", ".epub", ".PDF", ".EPUB"] where t.hasSuffix(ext) { t = String(t.dropLast(ext.count)) }
        return t.replacingOccurrences(of: "_", with: " ")
    }

    /// Card meta: progress for books and PDFs, otherwise pages and age.
    var shortDetail: String {
        let pages = displayPageCount
        if kind != .notebook, lastOpenedPage > 0, pages > 1 {
            return "\(Int(Double(lastOpenedPage + 1) / Double(pages) * 100))% read"
        }
        if kind == .epub { return lastModified.formatted(.relative(presentation: .named)) }
        return "\(pages)p · \(lastModified.formatted(.relative(presentation: .named)))"
    }

    var detailLine: String {
        let when = lastModified.formatted(.relative(presentation: .named))
        if isFolder { return "Folder · \(when)" }
        let pages = displayPageCount
        var parts = [kind.label]
        if kind != .epub { parts.append("\(pages) page\(pages == 1 ? "" : "s")") }
        if kind != .notebook, lastOpenedPage > 0, pages > 1 {
            parts.append("\(Int(Double(lastOpenedPage + 1) / Double(pages) * 100))% read")
        } else {
            parts.append(when)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Drag to organise

extension View {
    /// Documents can be dragged; folders accept dropped documents (moving them in).
    func organisable(_ doc: DocumentItem) -> some View {
        modifier(OrganisableModifier(doc: doc))
    }
}

struct OrganisableModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let doc: DocumentItem
    @State private var targeted = false

    func body(content: Content) -> some View {
        let draggable = content.draggable(DocumentDrag(id: doc.id)) {
            Label(doc.name, systemImage: doc.kind.symbol).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        if doc.isFolder && !doc.isTrashed {
            draggable
                .dropDestination(for: DocumentDrag.self) { items, _ in
                    let docs = items.compactMap { model.byID[$0.id] }
                    Task { await model.move(docs, to: doc.id) }
                    return !docs.isEmpty
                } isTargeted: { targeted = $0 }
                .overlay {
                    if targeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2) }
                }
        } else {
            draggable
        }
    }
}

/// A library document being dragged inside the app.
struct DocumentDrag: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .unremarkableDocument)
    }
}

extension UTType {
    static let unremarkableDocument = UTType(exportedAs: "com.unremarkable.mac.document")
}
