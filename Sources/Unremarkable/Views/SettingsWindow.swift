import AppKit
import RMKit
import SwiftUI

/// Settings sections, in sidebar order (modelled on the web app's settings page).
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, sync, reading, meetings, tasks, search, ai, server, mcp, delivery, updates, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Appearance"
        case .sync: "Account & Sync"
        case .reading: "Reading & Gestures"
        case .meetings: "Meetings"
        case .tasks: "Tasks"
        case .search: "Search"
        case .ai: "AI Providers"
        case .server: "Server"
        case .mcp: "MCP Server"
        case .delivery: "News & Puzzles"
        case .updates: "Updates"
        case .system: "System & Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .general: "paintpalette"
        case .sync: "arrow.triangle.2.circlepath"
        case .reading: "book"
        case .meetings: "waveform"
        case .tasks: "checklist"
        case .search: "magnifyingglass"
        case .ai: "sparkles"
        case .server: "server.rack"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .delivery: "newspaper"
        case .updates: "arrow.down.circle"
        case .system: "stethoscope"
        }
    }

    var tint: Color {
        switch self {
        case .general: .purple
        case .sync: .blue
        case .reading: .orange
        case .meetings: .red
        case .tasks: .green
        case .search: .gray
        case .ai: .pink
        case .server: .indigo
        case .mcp: .teal
        case .delivery: .brown
        case .updates: .blue
        case .system: .gray
        }
    }

    var summary: String {
        switch self {
        case .general: "Choose the app's theme or let it follow your Mac."
        case .sync: "Your reMarkable connection, background sync and library rescans."
        case .reading: "How documents look and how pages turn in the reader."
        case .meetings: "Recording, AI notes, calendar reminders and where notes go on the tablet."
        case .tasks: "Where tasks come from and the Tasks notebook on your reMarkable."
        case .search: "Search scope and folders kept out of search, tasks and Ask."
        case .ai: "The model that writes meeting notes, answers Ask and reads handwriting."
        case .server: "Run the Un-remarkable web server's background features on this Mac."
        case .mcp: "Let Claude, Cursor and other MCP clients search and edit your library."
        case .delivery: "A daily e-ink newspaper and puzzles, delivered to your reMarkable."
        case .updates: "Install new versions of Un-remarkable from inside the app."
        case .system: "Your library at a glance, storage, task scans and the activity log."
        }
    }

    static let groups: [(String, [SettingsPane])] = [
        ("App", [.general, .sync, .reading, .updates]),
        ("Features", [.meetings, .tasks, .search, .ai]),
        ("Server", [.server, .mcp, .delivery]),
        ("Help", [.system]),
    ]
}

/// Opens the Settings window at a pane from anywhere (menus, banners, launch hooks).
@MainActor @Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    /// Development aid: UNREMARKABLE_SETTINGS_TAB=<pane> opens on that pane.
    var pane: SettingsPane? = SettingsPane(rawValue: ProcessInfo.processInfo.environment["UNREMARKABLE_SETTINGS_TAB"] ?? "") ?? .general
    /// Set by the app's commands, which have SwiftUI's openWindow action.
    @ObservationIgnored var openWindow: (() -> Void)?

    static func open(_ pane: SettingsPane? = nil) {
        if let pane { shared.pane = pane }
        NSApp.activate()
        shared.openWindow?()
    }
}

struct SettingsView: View {
    @State private var link = SettingsRouter.shared
    @State private var updates = UpdateService.shared
    private var pane: SettingsPane? { link.pane }

    var body: some View {
        NavigationSplitView {
            List(selection: $link.pane) {
                ForEach(SettingsPane.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { p in
                            Label {
                                HStack {
                                    Text(p.title)
                                    if p == .updates && updates.updateAvailable {
                                        Spacer()
                                        Text("1").font(.caption2.bold()).foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.red, in: .capsule)
                                    }
                                }
                            } icon: {
                                SettingsIcon(pane: p, size: 20)
                            }
                            .tag(p)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralSettings()
                case .sync: AccountSyncSettings()
                case .reading: ReaderSettings()
                case .meetings: MeetingSettings()
                case .tasks: TaskSettings()
                case .search: SearchSettings()
                case .ai: AISettingsView()
                case .server: ServerSettings()
                case .mcp: MCPSettings()
                case .delivery: DeliverySettings()
                case .updates: UpdateSettings()
                case .system: SystemSettings()
                }
            }
            .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 540, idealHeight: 640)
    }
}

struct SettingsIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(pane.tint.gradient, in: .rect(cornerRadius: size * 0.24))
    }
}

/// Large icon, title and description at the top of a settings pane, like the web app's section cards.
struct SettingsHeader: View {
    let pane: SettingsPane
    init(_ pane: SettingsPane) { self.pane = pane }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                SettingsIcon(pane: pane, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).font(.title3.weight(.semibold))
                    Text(pane.summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Appearance

struct GeneralSettings: View {
    @AppStorage("readerTheme") private var theme: ReaderTheme = .system

    var body: some View {
        Form {
            SettingsHeader(.general)
            Section("Theme") {
                ForEach(ReaderTheme.allCases) { t in
                    Button { theme = t } label: {
                        HStack(spacing: 14) {
                            ThemeSwatch(theme: t)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.body.weight(.medium))
                                Text(t.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: theme == t ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(theme == t ? Color.accentColor : .secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Text("The theme applies to the library, the reader and your documents. Switch a single document from the reader's toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension ReaderTheme {
    var title: String {
        switch self {
        case .system: "Follow this Mac"
        case .dark: "Dark (basalt)"
        case .light: "Light (warm paper)"
        }
    }

    var blurb: String {
        switch self {
        case .system: "Switches between paper and basalt with your Mac's light and dark appearance."
        case .dark: "Deep surfaces with chalk-white type. Easier on the eyes in dim light."
        case .light: "A warm paper canvas with charcoal ink, like the tablet itself."
        }
    }
}

struct ThemeSwatch: View {
    let theme: ReaderTheme

    var body: some View {
        ZStack {
            switch theme {
            case .light: swatch(Color(red: 0.965, green: 0.961, blue: 0.945), Color(red: 0.094, green: 0.094, blue: 0.086))
            case .dark: swatch(Color(red: 0.071, green: 0.071, blue: 0.067), Color(red: 0.961, green: 0.957, blue: 0.937))
            case .system:
                HStack(spacing: 0) {
                    swatch(Color(red: 0.965, green: 0.961, blue: 0.945), Color(red: 0.094, green: 0.094, blue: 0.086))
                    swatch(Color(red: 0.071, green: 0.071, blue: 0.067), Color(red: 0.961, green: 0.957, blue: 0.937))
                }
            }
        }
        .frame(width: 56, height: 38)
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    private func swatch(_ paper: Color, _ ink: Color) -> some View {
        ZStack(alignment: .topLeading) {
            paper
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(ink).frame(width: 18, height: 3)
                Capsule().fill(ink.opacity(0.5)).frame(width: 24, height: 2)
                Capsule().fill(ink.opacity(0.5)).frame(width: 14, height: 2)
            }
            .padding(6)
        }
    }
}

// MARK: - Account & Sync

struct AccountSyncSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("syncIntervalMinutes") private var interval = 2
    @AppStorage("coverDownloads") private var coverDownloads = true
    @State private var confirm = false
    @State private var rescanning = false

    var body: some View {
        Form {
            SettingsHeader(.sync)
            Section("reMarkable cloud") {
                LabeledContent("Status") {
                    Label(model.isPaired ? "Connected" : "Not connected",
                          systemImage: model.isPaired ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.isPaired ? .green : .secondary)
                }
                if model.isPaired {
                    LabeledContent("Last sync") {
                        Text(model.isSyncing ? "Syncing…" : model.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                    }
                    LabeledContent("Library") { Text("\(model.documents.filter { !$0.isTrashed }.count) items") }
                    HStack {
                        Button("Sync Now") { Task { await model.syncNow() } }.disabled(model.isSyncing)
                        Spacer()
                        Button("Disconnect This Mac…", role: .destructive) { confirm = true }
                    }
                    .confirmationDialog("Disconnect from reMarkable?", isPresented: $confirm) {
                        Button("Disconnect", role: .destructive) { Task { await model.unpair() } }
                    } message: {
                        Text("Downloaded files stay on this Mac. To revoke access fully, also remove the desktop app in your reMarkable account.")
                    }
                } else {
                    Text("Open the Library window to connect.").foregroundStyle(.secondary)
                }
            }
            Section("Background sync") {
                Picker("Check for changes", selection: $interval) {
                    Text("Every minute").tag(1)
                    Text("Every 2 minutes").tag(2)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Every hour").tag(60)
                }
                .onChange(of: interval) { model.scheduleTimer() }
                Toggle(isOn: $coverDownloads) {
                    Text("Download books and short PDFs to draw covers")
                    Text("When the tablet hasn't made a thumbnail. PDFs over 60 pages are only drawn once you open them.")
                }
                Text(ServerMode.enabled("indexNotebookText")
                     ? "Notebook text is indexed for search after each sync. PDFs are indexed once you have opened them."
                     : "Titles are searchable. To search notebook text too, turn on Server › Index notebook text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rescan & re-index library") {
                HStack(alignment: .top) {
                    Text("Rescans every document, rebuilds the search index and the task scan. Excluded folders and documents stay excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(rescanning ? "Rescanning…" : "Rescan Library") {
                        rescanning = true
                        Task { await model.rebuildIndexes(); rescanning = false }
                    }
                    .disabled(rescanning || !model.isPaired)
                }
            }
            Section("Activity") {
                if model.log.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(model.log.prefix(8)) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.date.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(line.text).font(.caption).foregroundStyle(line.isError ? .red : .primary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Server

/// "Operate as a server": one switch for the web server's background features, each with its own toggle.
struct ServerSettings: View {
    @State private var mcp = MCPService.shared
    @AppStorage(ServerMode.key) private var serverMode = false
    @AppStorage("mcpEnabled") private var mcpEnabled = true
    @AppStorage("indexNotebookText") private var indexText = true
    @AppStorage("tasksNotebookEnabled") private var tasksNotebook = true
    @AppStorage("ocrHandwriting") private var ocr = false
    @AppStorage("ocrEngine") private var ocrEngine = "remarkable"
    @AppStorage("handwritingLanguage") private var language = HandwritingConversion.defaultLanguage
    @AppStorage("deliveryNewsEnabled") private var news = false
    @AppStorage("deliveryPuzzlesEnabled") private var puzzles = false

    var body: some View {
        Form {
            SettingsHeader(.server)
            Section {
                Toggle(isOn: $serverMode) {
                    Text("Operate as a server")
                    Text(serverMode
                         ? "This Mac runs the background features below."
                         : "Off: the app just syncs with your reMarkable. The reader, meetings, writing to the tablet, quick capture, title search and Ask all still work.")
                }
                .onChange(of: serverMode) { ServerMode.apply() }
            }
            Section("Server features") {
                Toggle(isOn: $mcpEnabled) {
                    Text("MCP server for AI assistants")
                    Text(mcp.running ? "Running on port \(mcp.port). Connection details are under MCP Server." : (mcp.lastError ?? "Lets Claude and other assistants read and write your library."))
                }
                .onChange(of: mcpEnabled) { ServerMode.apply() }
                Toggle(isOn: $indexText) {
                    Text("Index notebook text for search")
                    Text("Downloads every notebook's page files so typed text is searchable and Ask can use it.")
                }
                .onChange(of: indexText) { ServerMode.apply() }
                Toggle(isOn: $ocr) {
                    Text("Read handwriting into search")
                    Text(ocrEngine == "ai"
                         ? (AISettings.current.provider.supportsImages
                            ? "Changed handwritten pages are sent to \(AISettings.current.provider.displayName) and the text is added to search and Ask."
                            : "Needs an AI provider that reads images (Gemini, OpenAI or Ollama with a vision model).")
                         : "Changed handwritten pages are converted by reMarkable's handwriting service, as \"Convert to text\" on the tablet does, and added to search and Ask.")
                }
                .onChange(of: ocr) { ServerMode.apply() }
                if ocr {
                    Picker("Read with", selection: $ocrEngine) {
                        Text("reMarkable conversion").tag("remarkable")
                        Text("AI provider (vision)").tag("ai")
                    }
                    .onChange(of: ocrEngine) { ServerMode.apply() }
                    if ocrEngine != "ai" {
                        Picker("Handwriting language", selection: $language) {
                            ForEach(HandwritingConversion.languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                    }
                }
                Toggle(isOn: $tasksNotebook) {
                    Text("Keep a Tasks notebook on the tablet")
                    Text("Name and options are under Tasks.")
                }
                .onChange(of: tasksNotebook) { ServerMode.apply() }
                Toggle(isOn: $news) {
                    Text("Daily newspaper")
                    Text("The Morning Chronicle: full articles from your feeds, with a tappable index. Set up under News & Puzzles.")
                }
                .onChange(of: news) { ServerMode.apply() }
                Toggle(isOn: $puzzles) {
                    Text("Daily puzzles")
                    Text("Guardian quick and cryptic crosswords and a sudoku.")
                }
                .onChange(of: puzzles) { ServerMode.apply() }
            }
            .disabled(!serverMode)
        }
        .formStyle(.grouped)
    }
}

// MARK: - News & Puzzles

struct DeliverySettings: View {
    @Environment(AppModel.self) private var model
    @State private var delivery = DeliveryService.shared
    @AppStorage(ServerMode.key) private var serverMode = false
    @AppStorage("deliveryNewsEnabled") private var news = false
    @AppStorage("deliveryNewsFolder") private var newsFolder = "Daily News"
    @AppStorage("deliveryNewsTime") private var newsTime = 6 * 60
    @AppStorage("deliveryNewsFeeds") private var feeds = NewsFeeds.defaults.joined(separator: "\n")
    @AppStorage("deliveryArticlesPerFeed") private var perFeed = 2
    @AppStorage("deliveryWikipedia") private var wikipedia = true
    @AppStorage("deliveryWeather") private var weather = true
    @AppStorage("deliveryWeatherLocation") private var location = ""
    @AppStorage("deliveryImages") private var images = false
    @AppStorage("deliveryPuzzlesEnabled") private var puzzles = false
    @AppStorage("deliveryPuzzlesFolder") private var puzzlesFolder = "Puzzles"
    @AppStorage("deliveryPuzzlesTime") private var puzzlesTime = 6 * 60
    @AppStorage("deliveryQuick") private var quick = true
    @AppStorage("deliveryCryptic") private var cryptic = true
    @AppStorage("deliverySudoku") private var sudoku = true
    @AppStorage("deliverySudokuDifficulty") private var difficulty = "medium"
    @AppStorage("deliveryLastNews") private var lastNews = ""
    @AppStorage("deliveryLastPuzzles") private var lastPuzzles = ""
    @State private var editAsText = false

    var body: some View {
        Form {
            SettingsHeader(.delivery)
            if !serverMode {
                Section {
                    Label("Deliveries run when Server › Operate as a server is on. You can still set them up and use Deliver Now.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(isOn: $news) {
                    Text("Daily newspaper").font(.headline)
                    Text("Your feeds, Wikipedia's featured article and the weather as \"The Morning Chronicle\": a tappable index, then each full article on its own pages.")
                }
                .onChange(of: news) { ServerMode.apply() }
                TextField("Folder on reMarkable", text: $newsFolder)
                DatePicker("Deliver after", selection: timeBinding($newsTime), displayedComponents: .hourAndMinute)
                Picker("Articles per feed", selection: $perFeed) {
                    Text("1 (compact, ~6–8 pages)").tag(1)
                    Text("2 (balanced, ~10–14 pages)").tag(2)
                    Text("3 (comprehensive, ~15–20 pages)").tag(3)
                    Text("5 (in depth, 25+ pages)").tag(5)
                }
                Toggle("Wikipedia's featured article", isOn: $wikipedia)
                Toggle("Weather", isOn: $weather)
                if weather { TextField("Weather location", text: $location, prompt: Text("Automatic (by network location)")) }
                Toggle("Article images", isOn: $images)
                deliverRow(.news, last: lastNews)
            }
            Section {
                FeedManager(feeds: $feeds, editAsText: $editAsText)
            } header: {
                Text("Newspaper feeds")
            } footer: {
                Text("Only articles whose full text can be read are included; summary-only posts are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $puzzles) {
                    Text("Daily puzzles").font(.headline)
                    Text("Crosswords are trimmed to fill the screen. The sudoku comes with its solution on the next page.")
                }
                .onChange(of: puzzles) { ServerMode.apply() }
                TextField("Folder on reMarkable", text: $puzzlesFolder)
                DatePicker("Deliver after", selection: timeBinding($puzzlesTime), displayedComponents: .hourAndMinute)
                Toggle("Guardian quick crossword", isOn: $quick)
                Toggle("Guardian cryptic crossword", isOn: $cryptic)
                Toggle("Sudoku", isOn: $sudoku)
                if sudoku {
                    Picker("Sudoku difficulty", selection: $difficulty) {
                        Text("Easy").tag("easy")
                        Text("Medium").tag("medium")
                        Text("Hard").tag("hard")
                    }
                }
                deliverRow(.puzzles, last: lastPuzzles)
            }
            Section {
                Text("Sized for \(DeviceProfile.current.displayName) (Reading & Gestures › My tablet). Each delivery arrives at the first sync after its time. If the Un-remarkable web server also delivers, switch its delivery off so the tablet doesn't get two copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func deliverRow(_ kind: DeliveryService.Kind, last: String) -> some View {
        HStack {
            Text(delivery.status[kind] ?? (last.isEmpty ? "Not delivered yet" : "Last delivered \(last)"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if delivery.running == kind { ProgressView().controlSize(.small) }
            Button(kind == .news ? "Deliver Today's Paper Now" : "Deliver Today's Puzzles Now") { Task { await delivery.deliver(kind) } }
                .disabled(delivery.running != nil || !model.isPaired)
        }
    }

    /// Minutes after midnight as a Date today, for the time picker.
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
            set: { minutes.wrappedValue = DeliveryService.minutesNow($0) })
    }
}

/// Active feeds with remove buttons, presets, raw text editing, the catalogue and discovery by web address.
struct FeedManager: View {
    @Binding var feeds: String
    @Binding var editAsText: Bool
    @State private var query = ""
    @State private var category = "All"
    @State private var discovering = false
    @State private var discovered: [FeedDirectory.Checked] = []
    @State private var discoverStatus: String?

    private var list: [String] { feeds.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        HStack {
            Text("\(list.count) active feed\(list.count == 1 ? "" : "s")").font(.headline)
            Spacer()
            Menu("Presets") {
                ForEach(FeedDirectory.presets) { p in
                    Button { feeds = p.feeds.joined(separator: "\n") } label: {
                        Text(p.name)
                        Text(p.summary)
                    }
                }
                Divider()
                Button("Reset to Defaults") { feeds = NewsFeeds.defaults.joined(separator: "\n") }
            }
            .fixedSize()
            Toggle("Edit as Text", isOn: $editAsText).toggleStyle(.button)
        }
        if editAsText {
            TextEditor(text: $feeds)
                .font(.caption.monospaced())
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
        } else {
            ForEach(list, id: \.self) { url in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(FeedDirectory.name(for: url) ?? URL(string: url)?.host() ?? url)
                        Text(url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { remove(url) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain).help("Remove this feed")
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Discover & add feeds").font(.headline)
            HStack {
                TextField("Search the catalogue or enter any website (e.g. wired, kottke.org)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(discover)
                Button(discovering ? "Looking…" : "Find Feed", action: discover)
                    .disabled(discovering || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Category", selection: $category) {
                ForEach(FeedDirectory.categories, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let discoverStatus { Text(discoverStatus).font(.caption).foregroundStyle(.secondary) }
            ForEach(discovered) { c in
                feedRow(title: c.title, detail: c.headlines.first.map { "Latest: \($0)" } ?? c.summary, url: c.url, badge: c.source)
            }
            ForEach(FeedDirectory.search(query, category: category).prefix(query.isEmpty ? 40 : 12)) { f in
                feedRow(title: f.name, detail: f.summary, url: f.url, badge: f.category)
            }
        }
        .padding(.top, 4)
    }

    private func feedRow(title: String, detail: String, url: String, badge: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.body.weight(.medium))
                    Text(badge).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if list.contains(url) {
                Label("Added", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Add") { feeds = (list + [url]).joined(separator: "\n") }
            }
        }
        .padding(.vertical, 2)
    }

    private func remove(_ url: String) {
        feeds = list.filter { $0 != url }.joined(separator: "\n")
    }

    /// Catalogue matches show as you type; Find Feed also looks the text up as a web address.
    private func discover() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.contains(".") || q.hasPrefix("http") else {
            discoverStatus = q.isEmpty ? nil : "Showing catalogue matches. Enter a web address (with a dot) to find a site's own feed."
            discovered = []
            return
        }
        discovering = true
        discoverStatus = nil
        Task {
            let found = await FeedDirectory.discover(q)
            discovered = found
            discoverStatus = found.isEmpty ? "No feed found at \(q)." : "Found \(found.count) feed\(found.count == 1 ? "" : "s") at \(q)."
            discovering = false
        }
    }
}

// MARK: - Updates

struct UpdateSettings: View {
    @State private var updates = UpdateService.shared
    @AppStorage("updateAutoCheck") private var autoCheck = true
    @AppStorage("updateFeedURL") private var feedURL = UpdateService.defaultFeed

    var body: some View {
        Form {
            SettingsHeader(.updates)
            Section {
                LabeledContent("This version") { Text(updates.current) }
                LabeledContent("Latest") {
                    switch updates.phase {
                    case .checking: ProgressView().controlSize(.small)
                    default: Text(updates.latest.map { "\($0.version) (\($0.commit))" } ?? "Not checked yet")
                    }
                }
                if let checked = updates.lastChecked {
                    LabeledContent("Last checked") { Text(checked.formatted(.relative(presentation: .named))) }
                }
                HStack {
                    status
                    Spacer()
                    Button("Check Now") { Task { await updates.check() } }
                        .disabled(updates.phase == .checking || updates.phase == .downloading || updates.phase == .installing)
                    if updates.updateAvailable {
                        Button("Install and Relaunch") { Task { await updates.install() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(updates.installBlocker != nil || updates.phase == .downloading || updates.phase == .installing)
                    }
                }
                if updates.updateAvailable, let blocker = updates.installBlocker {
                    Text(blocker).font(.caption).foregroundStyle(.orange)
                }
            }
            if let release = updates.latest, updates.updateAvailable {
                Section("What's new in \(release.version)") {
                    Text(release.notes.isEmpty ? "No release notes." : release.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(release.size), countStyle: .file)) download")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Options") {
                Toggle("Check for updates automatically", isOn: $autoCheck)
                TextField("Download page", text: $feedURL, prompt: Text("https://example.com/unremarkable"))
                    .font(.callout.monospaced())
                Text("Updates are checked against the checksum on the download page and must be signed with the same certificate as this copy. Your settings, library and meetings are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if updates.latest == nil { await updates.check() } }
    }

    @ViewBuilder private var status: some View {
        switch updates.phase {
        case .idle where feedURL.trimmingCharacters(in: .whitespaces).isEmpty:
            Text("Updates are off: enter your download page below, or build with DOWNLOAD_URL set.").foregroundStyle(.secondary)
        case .idle, .checking: EmptyView()
        case .upToDate: Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available: Label("Update available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .downloading: Label("Downloading…", systemImage: "arrow.down.circle")
        case .installing: Label("Installing…", systemImage: "gearshape.2")
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
        }
    }
}

// MARK: - System & Diagnostics

struct SystemSettings: View {
    @Environment(AppModel.self) private var model
    @State private var tasks = TasksModel.shared
    @State private var usage: Int64?
    @State private var scanning = false

    var body: some View {
        Form {
            SettingsHeader(.system)
            Section("Library") {
                let docs = model.documents.filter { !$0.isTrashed && !$0.isFolder }
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        stat("Documents", docs.count)
                        stat("Notebooks", docs.filter { $0.kind == .notebook }.count)
                        stat("PDFs & EPUBs", docs.filter { $0.kind == .pdf || $0.kind == .epub }.count)
                        stat("Open tasks", tasks.open.count)
                    }
                }
                HStack {
                    Button(scanning ? "Scanning…" : "Scan Documents for Tasks") {
                        scanning = true
                        Task { await tasks.refresh(); scanning = false }
                    }
                    .disabled(scanning || !model.isPaired)
                    Spacer()
                    if let indexing = model.indexing {
                        ProgressView(value: Double(indexing.done), total: Double(max(indexing.total, 1))) { Text("Indexing").font(.caption) }
                            .frame(width: 160)
                    }
                }
            }
            Section("Storage") {
                LabeledContent("Downloaded files") {
                    Text(usage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                }
                LabeledContent("Location") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.support]) }
                }
                Button("Clear Thumbnail Cache") { Task { await model.renderer.clearThumbnails() } }
            }
            Section("Sync history") {
                let snaps = model.db.snapshots(limit: 12)
                if snaps.isEmpty {
                    Text("Each sync that finds changes records a snapshot of the library here.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snaps) { s in
                    HStack {
                        Text(s.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text("\(s.changed) changed · \(s.documentCount) items · generation \(s.generation)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Section("About") {
                LabeledContent("Version") { Text(UpdateService.shared.current) }
                LabeledContent("macOS") { Text(ProcessInfo.processInfo.operatingSystemVersionString) }
                LabeledContent("Server mode") { Text(ServerMode.isOn ? "On" : "Off") }
                LabeledContent("MCP") { Text(MCPService.shared.running ? "Running on port \(MCPService.shared.port)" : "Off") }
            }
        }
        .formStyle(.grouped)
        .task { usage = await Task.detached { [blobs = model.blobs] in blobs.diskUsage() }.value }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}
