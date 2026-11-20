import AppKit
import Observation
import RMKit
import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Sidebar destinations in the library window.
enum LibrarySection: Hashable {
    case folder(String) // "" = top level
    case continueReading, favorites, recent, notebooks, pdfs, books, trash, meetings, tasks, ask, highlights
    case tag(String)

    var title: String {
        switch self {
        case .folder: return "My files"
        case .continueReading: return "Continue Reading"
        case .favorites: return "Favourites"
        case .recent: return "Recent"
        case .notebooks: return "Notebooks"
        case .pdfs: return "PDFs"
        case .books: return "Books"
        case .trash: return "Trash"
        case .meetings: return "Meetings"
        case .tasks: return "Tasks"
        case .ask: return "Ask"
        case .highlights: return "Highlights"
        case .tag(let t): return "#\(t)"
        }
    }
}

/// Something open in the library window besides the library itself.
enum Pane: Hashable, Identifiable {
    case document(String), meeting(String)
    var id: String {
        switch self {
        case .document(let id): return "doc-" + id
        case .meeting(let id): return "meeting-" + id
        }
    }
}

struct SyncLogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let isError: Bool
}

/// App-wide state: pairing, the synced library, sync status and the services behind them.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let paths = AppPaths()
    let auth: AuthManager
    let client: CloudClient
    let sync: SyncEngine
    let indexer: TextIndexer
    let db: LibraryDatabase
    let blobs: BlobStore
    let renderer: DocumentRenderer
    let localSearch: LocalSearchProvider

    /// This Mac's index, plus the self-hosted web app when Settings › Search › Companion server is on.
    var searchProviders: [any SearchProvider] {
        var out: [any SearchProvider] = [localSearch]
        let d = UserDefaults.standard
        if d.bool(forKey: "companionSearch"), let url = URL(string: (d.string(forKey: "companionURL") ?? Self.defaultCompanionURL).trimmingCharacters(in: .whitespaces)) {
            out.append(CompanionSearchProvider(base: url))
        }
        return out
    }
    /// No built-in server: enter your own companion web app's address in Settings › Search
    /// (or build with COMPANION_URL in config.local.env).
    nonisolated static let defaultCompanionURL = (Bundle.main.object(forInfoDictionaryKey: "UnremarkableCompanionURL") as? String) ?? ""
    nonisolated static let exampleCompanionURL = "http://my-server:8099"

    var isPaired = false
    var documents: [DocumentItem] = [] { didSet { rebuildIndexes() } }
    private(set) var byID: [String: DocumentItem] = [:]
    private(set) var children: [String: [DocumentItem]] = [:]
    private(set) var allTags: [String] = []

    var isSyncing = false
    var progress = SyncProgress(stage: "Idle")
    var lastSync: Date?
    var lastError: String?
    var log: [SyncLogLine] = []
    var indexing: (done: Int, total: Int)?

    var showCommandPalette = false
    @ObservationIgnored private var tasksRefreshed = false
    /// Document being renamed (drives the rename prompt in the library).
    var renaming: DocumentItem?
    /// Documents and meetings open in the library window, in the order opened. One is in front (`activePane`);
    /// the rest are minimised to rails at the side. Nothing opens in a window of its own.
    var panes: [Pane] = []
    var activePane: Pane?
    /// The document in front, if it's a document.
    var reading: String? {
        get { if case .document(let id)? = activePane { id } else { nil } }
        set { if let newValue { show(.document(newValue)) } else { activePane = nil } }
    }
    /// Set by the app's commands: brings the library window back if it was closed.
    @ObservationIgnored var showLibraryWindow: (() -> Void)?
    /// Document shown in the converter sheet.
    var converting: DocumentItem?
    /// Explicit search exclusions (documents and folders).
    var explicitExclusions: Set<String> = []

    /// Opens a document in the library window's reader; folders are navigated by the caller.
    func open(_ id: String) { show(.document(id)) }

    /// Opens a meeting's notes in the library window.
    func openMeeting(_ id: String) { show(.meeting(id)) }

    /// Brings a pane to the front, opening it if needed.
    func show(_ pane: Pane) {
        if !panes.contains(pane) { panes.append(pane) }
        activePane = pane
        if NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("library") == true && $0.isVisible }) == nil {
            showLibraryWindow?()
        }
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("library") == true }?.makeKeyAndOrderFront(nil)
    }

    /// Moves a pane to the side; the library (or section) comes back to the front.
    func minimise(_ pane: Pane) { if activePane == pane { activePane = nil } }

    /// Closes a pane. A meeting that is still recording only minimises.
    func close(_ pane: Pane) {
        if case .meeting(let id) = pane, MeetingRecorder.shared.activeID == id { minimise(pane); return }
        panes.removeAll { $0 == pane }
        if activePane == pane { activePane = nil }
    }

    @ObservationIgnored @AppStorage("syncIntervalMinutes") var syncIntervalMinutes = 2
    @ObservationIgnored @AppStorage("indexNotebookText") var indexNotebookText = true
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var positionTasks: [String: Task<Void, Never>] = [:]

    private init() {
        db = try! LibraryDatabase(url: paths.database)
        blobs = BlobStore(root: paths.blobs)
        auth = AuthManager()
        client = CloudClient(auth: auth)
        sync = SyncEngine(client: client, blobs: blobs, db: db)
        indexer = TextIndexer(sync: sync)
        renderer = DocumentRenderer(sync: sync, thumbnails: paths.thumbnails)
        localSearch = LocalSearchProvider(db: db)
        documents = db.allDocuments()
        explicitExclusions = db.explicitExclusions()
        if let s = db.value("lastSync") { lastSync = ISO8601DateFormatter().date(from: s) }
        Task { await bootstrap() }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        isPaired = await auth.isPaired
        guard isPaired else { return }
        scheduleTimer()
        await syncNow()
    }

    func scheduleTimer() {
        timer?.invalidate()
        let minutes = max(1, syncIntervalMinutes)
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.syncNow(quiet: true) }
        }
    }

    func pair(code: String) async throws {
        try await auth.pair(code: code)
        isPaired = true
        addLog("Paired this Mac with your reMarkable account.")
        scheduleTimer()
        await syncNow()
    }

    func unpair() async {
        await auth.unpair()
        timer?.invalidate()
        isPaired = false
        addLog("Signed out. Your downloaded files stay on this Mac.")
    }

    // MARK: Sync

    func syncNow(quiet: Bool = false) async {
        guard isPaired, !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        do {
            let outcome = try await sync.sync { p in Task { @MainActor in AppModel.shared.progress = p } }
            documents = db.allDocuments()
            lastSync = .now
            switch outcome {
            case .upToDate: if !quiet { addLog("Already up to date.") }
            case .synced(let changed, let total): addLog("Synced \(changed) changed item\(changed == 1 ? "" : "s") (\(total) in library).")
            }
            progress = SyncProgress(stage: "Up to date", done: 1, total: 1)
            if indexNotebookText && ServerMode.isOn { Task { await indexText(); await readHandwriting() } }
            DeliveryService.shared.checkSchedule()
            if case .synced = outcome { Task { await TasksModel.shared.refresh() } } else if !tasksRefreshed {
                tasksRefreshed = true
                Task { await TasksModel.shared.refresh() }
            }
        } catch {
            lastError = error.localizedDescription
            progress = SyncProgress(stage: "Sync failed", message: error.localizedDescription)
            addLog(error.localizedDescription, isError: true)
            if case RMError.notPaired = error { isPaired = false }
        }
    }

    func indexText() async {
        guard indexing == nil else { return }
        indexing = (0, 0)
        let n = await indexer.indexAll { done, total in
            Task { @MainActor in AppModel.shared.indexing = (done, total) }
        }
        indexing = nil
        if n > 0 { addLog("Indexed text from \(n) document\(n == 1 ? "" : "s") for search.") }
    }

    @ObservationIgnored private var readingHandwriting = false

    /// Transcribes changed handwritten pages into search and Ask (Server › Read handwriting into search).
    func readHandwriting() async {
        guard ServerMode.enabled("ocrHandwriting", default: false), !readingHandwriting else { return }
        let settings = AISettings.current
        let useAI = UserDefaults.standard.string(forKey: "ocrEngine") == "ai"
        guard !useAI || settings.provider.supportsImages else { return }
        readingHandwriting = true
        defer { readingHandwriting = false }
        let ocr = HandwritingOCR(sync: sync)
        let reader: HandwritingOCR.Reader = useAI ? .vision(AIProvider(settings: settings)) : .remarkable(language: Self.handwritingLanguage)
        let result = await ocr.run(reader: reader, skip: excludedIDs, maxPages: useAI ? 20 : 80) { msg in
            Task { @MainActor in AppModel.shared.progress = SyncProgress(stage: "Handwriting", message: msg) }
        }
        for id in result.documents {
            if let doc = db.document(id) { await indexer.index(doc) }
        }
        if result.pagesRead > 0 {
            addLog("Read handwriting on \(result.pagesRead) page\(result.pagesRead == 1 ? "" : "s") for search\(result.remaining > 0 ? " (\(result.remaining) more next sync)" : "").")
        }
        progress = SyncProgress(stage: "Up to date", done: 1, total: 1)
    }

    /// Language for reMarkable's handwriting conversion (Settings › Search).
    static var handwritingLanguage: String {
        UserDefaults.standard.string(forKey: "handwritingLanguage") ?? HandwritingConversion.defaultLanguage
    }

    func addLog(_ text: String, isError: Bool = false) {
        log.insert(SyncLogLine(text: text, isError: isError), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    // MARK: Library queries

    private func rebuildIndexes() {
        var by: [String: DocumentItem] = [:]
        var kids: [String: [DocumentItem]] = [:]
        var tags = Set<String>()
        for d in documents {
            by[d.id] = d
            kids[d.parent, default: []].append(d)
            tags.formUnion(d.tags)
        }
        byID = by
        children = kids
        allTags = tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var folders: [DocumentItem] { documents.filter { $0.isFolder && !$0.isTrashed } }

    func items(in section: LibrarySection) -> [DocumentItem] {
        let live = documents.filter { !$0.isTrashed }
        switch section {
        case .folder(let id): return children[id, default: []]
        case .continueReading:
            return live.filter { !$0.isFolder && $0.lastOpened != nil && $0.kind != .notebook }
                .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        case .favorites: return live.filter(\.pinned)
        case .recent: return Array(live.filter { !$0.isFolder }.sorted { $0.lastModified > $1.lastModified }.prefix(60))
        case .notebooks: return live.filter { $0.kind == .notebook }
        case .pdfs: return live.filter { $0.kind == .pdf }
        case .books: return live.filter { $0.kind == .epub }
        case .trash: return documents.filter(\.isTrashed)
        case .meetings, .tasks, .ask, .highlights: return []
        case .tag(let t): return live.filter { $0.tags.contains(t) }
        }
    }

    /// Folder chain from the top level down to `id`, for breadcrumbs.
    func path(to id: String) -> [DocumentItem] {
        var out: [DocumentItem] = []
        var cur = byID[id]
        var guardCount = 0
        while let c = cur, guardCount < 64 {
            out.insert(c, at: 0)
            cur = byID[c.parent]
            guardCount += 1
        }
        return out
    }

    func subfolders(of id: String) -> [DocumentItem]? {
        let f = children[id, default: []].filter(\.isFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return f.isEmpty ? nil : f
    }

    /// Search with the user's scope: excluded documents match on their title only (unless included), and
    /// "Notes only" limits results to notebooks.
    func search(_ text: String, notesOnly: Bool = false, includeExcluded: Bool = false) async -> [SearchHit] {
        var seen = Set<String>()
        var hits: [SearchHit] = []
        let excluded = includeExcluded ? [] : excludedIDs
        // Providers run together; results keep provider order (this Mac first), duplicates dropped.
        let providers = searchProviders
        let results = await withTaskGroup(of: (Int, [SearchHit]).self) { group in
            for (i, p) in providers.enumerated() { group.addTask { (i, (try? await p.search(text)) ?? []) } }
            var out = Array(repeating: [SearchHit](), count: providers.count)
            for await (i, r) in group { out[i] = r }
            return out
        }
        for found in results {
            for h in found where seen.insert(h.docID).inserted {
                guard let doc = byID[h.docID], !doc.isTrashed else { continue }
                if notesOnly, doc.kind != .notebook { continue }
                if excluded.contains(doc.id) {
                    guard SearchExclusions.titleMatches(doc.name, query: text) else { continue }
                    hits.append(SearchHit(docID: doc.id, snippet: doc.name))
                } else {
                    hits.append(h)
                }
            }
        }
        return hits
    }

    // MARK: Exclusions

    /// Documents excluded from search contents, OCR, tasks and Ask (folders apply recursively).
    var excludedIDs: Set<String> { SearchExclusions.expand(explicitExclusions, documents: documents) }

    func isExplicitlyExcluded(_ id: String) -> Bool { explicitExclusions.contains(id) }

    func setExcluded(_ doc: DocumentItem, _ excluded: Bool) {
        db.setExcluded(doc.id, excluded)
        explicitExclusions = db.explicitExclusions()
        addLog("\(excluded ? "Excluded" : "Included") \(doc.name) \(excluded ? "from" : "in") search, tasks and Ask.")
    }

    func rebuildIndexes() async {
        db.resetIndexes()
        addLog("Rebuilding the search index and task scan…")
        await indexText()
        await TasksModel.shared.refresh()
    }

    // MARK: Reading position

    /// Debounced so flipping through pages doesn't publish a root per page.
    func readingPositionChanged(_ doc: DocumentItem, page: Int) {
        positionTasks[doc.id]?.cancel()
        // Opening a document restores its saved page; only push real page turns to the cloud.
        guard page != (byID[doc.id]?.lastOpenedPage ?? doc.lastOpenedPage) else { return }
        positionTasks[doc.id] = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await sync.setReadingPosition(docID: doc.id, page: page)
            if let updated = db.document(doc.id), let i = documents.firstIndex(where: { $0.id == doc.id }) {
                documents[i] = updated
            }
        }
    }

    // MARK: Upload

    func upload(_ urls: [URL], to parent: String) async {
        let markdown = urls.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
        if !markdown.isEmpty { await importMarkdown(markdown, to: parent) }
        for url in urls where ["pdf", "epub"].contains(url.pathExtension.lowercased()) {
            do {
                addLog("Uploading \(url.lastPathComponent)…")
                try await sync.upload(fileURL: url, parentID: parent)
                addLog("Uploaded \(url.lastPathComponent).")
            } catch {
                addLog("Upload failed for \(url.lastPathComponent): \(error.localizedDescription)", isError: true)
            }
        }
        await syncNow(quiet: true)
    }
}

// MARK: - Writing to the tablet

extension AppModel {
    /// Runs a cloud write, refreshes the library from the local database and logs the outcome.
    @discardableResult
    func write(_ what: String, _ body: () async throws -> DocumentItem) async -> DocumentItem? {
        guard isPaired else {
            addLog("Connect your reMarkable first.", isError: true)
            return nil
        }
        do {
            let doc = try await body()
            documents = db.allDocuments()
            addLog("\(what): \(doc.name).")
            return doc
        } catch {
            addLog("\(what) failed: \(error.localizedDescription)", isError: true)
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createNotebook(title: String, markdown: String, in parent: String) async -> DocumentItem? {
        await write("Created notebook") { try await sync.createTypedNotebook(title: title, markdown: markdown, parentID: parent) }
    }

    @discardableResult
    func createFolder(name: String, in parent: String) async -> DocumentItem? {
        await write("Created folder") { try await sync.createFolder(name: name, parentID: parent) }
    }

    func importMarkdown(_ urls: [URL], to parent: String) async {
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                addLog("Couldn't read \(url.lastPathComponent).", isError: true)
                continue
            }
            let title = url.deletingPathExtension().lastPathComponent
            await createNotebook(title: title, markdown: text, in: parent)
        }
    }

    @AppStorage("quickNotesNotebook") static var quickNotesTitle = "Quick Notes"

    @discardableResult
    func quickNote(_ text: String) async -> DocumentItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await write("Added a quick note to") { try await sync.appendNote(trimmed, toNotebookNamed: Self.quickNotesTitle) }
    }
}

// MARK: - Organising and exporting

extension AppModel {
    /// Runs a metadata edit on a document and refreshes the library.
    func organise(_ what: String, _ doc: DocumentItem, _ body: () async throws -> Void) async {
        guard isPaired else { return addLog("Connect your reMarkable first.", isError: true) }
        do {
            try await body()
            documents = db.allDocuments()
            addLog("\(what): \(doc.name).")
        } catch {
            addLog("\(what) failed for \(doc.name): \(error.localizedDescription)", isError: true)
            lastError = error.localizedDescription
        }
    }

    func rename(_ doc: DocumentItem, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != doc.name else { return }
        await organise("Renamed", doc) { try await sync.rename(doc.id, to: name) }
    }

    func move(_ docs: [DocumentItem], to folder: String) async {
        for doc in docs where doc.parent != folder && doc.id != folder && !isAncestor(doc.id, of: folder) {
            await organise("Moved", doc) { try await sync.move(doc.id, to: folder) }
        }
    }

    func trash(_ docs: [DocumentItem]) async {
        for doc in docs { await organise("Moved to Trash", doc) { try await sync.trash(doc.id) } }
    }

    func restore(_ doc: DocumentItem) async {
        await organise("Restored", doc) { try await sync.move(doc.id, to: "") }
    }

    func setFavourite(_ doc: DocumentItem, _ on: Bool) async {
        await organise(on ? "Added to Favourites" : "Removed from Favourites", doc) { try await sync.setPinned(doc.id, on) }
    }

    /// True when `ancestor` contains `id` (moving a folder into its own subfolder would make a cycle).
    func isAncestor(_ ancestor: String, of id: String) -> Bool {
        var cur = byID[id]?.parent
        var steps = 0
        while let p = cur, !p.isEmpty, steps < 100 {
            if p == ancestor { return true }
            cur = byID[p]?.parent
            steps += 1
        }
        return false
    }

    /// The document as a PDF with its ink: original pages (PDF documents) or notebook pages.
    func annotatedPDF(_ doc: DocumentItem) async throws -> Data {
        try await renderer.annotatedPDF(doc)
    }

    /// Exports documents to a directory: PDFs with ink for notebooks and PDFs, the original file for EPUBs,
    /// and folders as subdirectories. Returns the number of files written.
    @discardableResult
    func export(_ docs: [DocumentItem], to dir: URL) async -> Int {
        var written = 0
        let fm = FileManager.default
        for doc in docs {
            var safe = doc.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            for ext in [".pdf", ".epub"] where safe.lowercased().hasSuffix(ext) { safe = String(safe.dropLast(ext.count)) }
            do {
                switch doc.kind {
                case .folder:
                    let sub = dir.appending(path: safe, directoryHint: .isDirectory)
                    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                    written += await export(children[doc.id, default: []].filter { !$0.isTrashed }, to: sub)
                case .epub:
                    guard let hash = doc.payloadHash else { continue }
                    let data = try await sync.blob(hash, filename: "\(doc.id).epub")
                    try data.write(to: unique(dir.appending(path: "\(safe).epub")))
                    written += 1
                case .notebook, .pdf:
                    try await annotatedPDF(doc).write(to: unique(dir.appending(path: "\(safe).pdf")))
                    written += 1
                }
            } catch {
                addLog("Export failed for \(doc.name): \(error.localizedDescription)", isError: true)
            }
        }
        return written
    }

    /// Exports into a temporary folder and zips it (`ditto`, like Finder's Compress). For a folder the ZIP
    /// holds its contents; for a document, the file itself. Returns the number of files, nil on failure.
    func exportZip(_ doc: DocumentItem, to dest: URL) async -> Int? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let n = await export(doc.isFolder ? children[doc.id, default: []].filter { !$0.isTrashed } : [doc], to: work)
            try? fm.removeItem(at: dest)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", work.path, dest.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw RMError.malformed("ditto failed (\(p.terminationStatus))") }
            return n
        } catch {
            addLog("ZIP export failed for \(doc.name): \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    private func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appending(path: "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }
}

struct AppPaths {
    let support: URL
    let caches: URL

    init() {
        let fm = FileManager.default
        support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Unremarkable")
        caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Unremarkable")
        for d in [support, caches, thumbnails, epubs] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    var database: URL { support.appending(path: "library.sqlite") }
    var blobs: URL { support.appending(path: "blobs") }
    var thumbnails: URL { caches.appending(path: "thumbnails") }
    var epubs: URL { caches.appending(path: "epub") }
}
