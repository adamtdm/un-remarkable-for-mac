import RMKit
import SwiftUI

/// Shared measurements of the column layout.
enum Columns {
    /// Height of the top band, shared by every column so the lists below line up.
    static let band: CGFloat = 200
    static let header: CGFloat = 40
    static let rail: CGFloat = 30
    static let gutter: CGFloat = 14
}

/// The width of one of the window's four columns, and how many of them the main area spans.
struct ColumnUnitKey: EnvironmentKey { static let defaultValue: CGFloat = 270 }
struct MainUnitsKey: EnvironmentKey { static let defaultValue: Int = 2 }
extension EnvironmentValues {
    var columnUnit: CGFloat {
        get { self[ColumnUnitKey.self] }
        set { self[ColumnUnitKey.self] = newValue }
    }
    var mainUnits: Int {
        get { self[MainUnitsKey.self] }
        set { self[MainUnitsKey.self] = newValue }
    }
}

/// The library window ("Column Rules"): four equal columns divided by full-height hairlines.
/// The main area (columns 1–2, wider when others are folded away) shows the library, a section, or an open
/// document or meeting. Column 3 is today and column 4 the tablet; either folds into a thin rail. Open documents
/// and meetings that aren't in front are minimised to rails on the left. Nothing opens a window of its own.
struct Workspace: View {
    @Environment(AppModel.self) private var model
    @Binding var section: LibrarySection?
    @Binding var searchText: String

    @AppStorage("homeShowToday") private var homeToday = true
    @AppStorage("homeShowTablet") private var homeTablet = true
    // With a document or meeting in front, the side columns start folded so it gets the room.
    @AppStorage("paneShowToday") private var paneToday = false
    @AppStorage("paneShowTablet") private var paneTablet = false

    var body: some View {
        let inPane = model.activePane != nil
        let showToday = inPane ? paneToday : homeToday
        let showTablet = inPane ? paneTablet : homeTablet
        let side = model.panes.filter { $0 != model.activePane }
        GeometryReader { g in
            let railCount = side.count + (showToday ? 0 : 1) + (showTablet ? 0 : 1)
            let unit = max((g.size.width - CGFloat(railCount) * (Columns.rail + 1) - 2) / 4, 160)
            let mainUnits = 4 - (showToday ? 1 : 0) - (showTablet ? 1 : 0)
            HStack(spacing: 0) {
                ForEach(side) { p in
                    PaneRail(pane: p)
                    ColumnRule()
                }
                main
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.columnUnit, unit)
                    .environment(\.mainUnits, mainUnits)
                ColumnRule()
                if showToday {
                    TodayColumn(navigate: navigate, hide: { set(today: false, inPane) })
                        .frame(width: unit)
                } else {
                    ColumnRail(title: "today") { set(today: true, inPane) }
                }
                ColumnRule()
                if showTablet {
                    TabletColumn(navigate: navigate, hide: { set(tablet: false, inPane) })
                        .frame(width: unit)
                } else {
                    ColumnRail(title: "tablet") { set(tablet: true, inPane) }
                }
            }
        }
        .background(Paper.background)
    }

    @ViewBuilder private var main: some View {
        if let pane = model.activePane {
            PaneView(pane: pane)
        } else if !model.isPaired && model.documents.isEmpty {
            PairingView()
        } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            BrowserView(section: section ?? .folder(""), searchText: $searchText, navigate: navigate)
        } else {
            switch section ?? .folder("") {
            case .meetings: MeetingsListView()
            case .tasks: TasksView()
            case .ask: AskView()
            case .highlights: HighlightsView()
            case .folder(""): LibraryHome(navigate: navigate)
            default: BrowserView(section: section ?? .folder(""), searchText: $searchText, navigate: navigate)
            }
        }
    }

    private func navigate(_ s: LibrarySection) {
        model.activePane = nil
        section = s
    }

    private func set(today: Bool? = nil, tablet: Bool? = nil, _ inPane: Bool) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let today { if inPane { paneToday = today } else { homeToday = today } }
            if let tablet { if inPane { paneTablet = tablet } else { homeTablet = tablet } }
        }
    }
}

struct ColumnRule: View {
    var body: some View {
        Rectangle().fill(Paper.border).frame(width: 1).frame(maxHeight: .infinity)
    }
}

// MARK: - Panes

/// An open document or meeting in front, with its header: minimise to the side, or close.
struct PaneView: View {
    @Environment(AppModel.self) private var model
    let pane: Pane

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: kind) {
                Text(title).font(.mono(12.5)).foregroundStyle(Paper.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Button { withAnimation(.easeOut(duration: 0.2)) { model.minimise(pane) } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.to.line").font(.system(size: 10, weight: .medium))
                        Text("minimise")
                    }
                }
                .buttonStyle(MonoButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Move it to the side (Esc). Click its rail to bring it back.")
                Button { withAnimation(.easeOut(duration: 0.2)) { model.close(pane) } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        Text("close")
                    }
                }
                .buttonStyle(MonoButtonStyle())
                .keyboardShortcut("w", modifiers: .command)
                .help(recording ? "Still recording: it moves to the side instead (⌘W)" : "Close (⌘W)")
            }
            Rectangle().fill(Paper.border).frame(height: 1)
            switch pane {
            case .document(let id): ReaderWindow(docID: id).id(id)
            case .meeting(let id): MeetingWindow(meetingID: id).id(id)
            }
        }
    }

    private var recording: Bool {
        if case .meeting(let id) = pane { return MeetingRecorder.shared.activeID == id }
        return false
    }

    private var kind: String {
        switch pane {
        case .document(let id):
            let k = model.byID[id]?.kind
            return k == .notebook ? "notebook" : k == .epub ? "book" : "reading"
        case .meeting(let id): return MeetingRecorder.shared.activeID == id ? "recording" : "meeting"
        }
    }

    private var title: String { PaneRail.title(of: pane, model: model) }
}

/// A minimised document or meeting at the left edge: click to bring it back, or close it.
struct PaneRail: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    @State private var hover = false

    var body: some View {
        let title = Self.title(of: pane, model: model)
        VStack(spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.2)) { model.close(pane) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
            Button { withAnimation(.easeOut(duration: 0.2)) { model.show(pane) } } label: {
                VStack(spacing: 10) {
                    if recording {
                        Circle().fill(Color.red).frame(width: 8, height: 8).accessibilityLabel("Recording")
                    } else {
                        Image(systemName: icon).font(.system(size: 11))
                    }
                    VerticalLabel(text: title, length: 260)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Bring back \(title)")
            .accessibilityLabel("Bring back \(title)")
        }
        .font(.mono(12))
        .foregroundStyle(hover ? Paper.text : Paper.textMuted)
        .padding(.top, 9)
        .frame(width: Columns.rail)
        .frame(maxHeight: .infinity)
        .background(hover ? Paper.raised : .clear)
        .onHover { hover = $0 }
    }

    private var recording: Bool {
        if case .meeting(let id) = pane { return MeetingRecorder.shared.activeID == id }
        return false
    }

    private var icon: String {
        if case .meeting = pane { return "waveform" }
        return "book.closed"
    }

    static func title(of pane: Pane, model: AppModel) -> String {
        switch pane {
        case .document(let id): return model.byID[id]?.coverTitle ?? "Document"
        case .meeting(let id): return MeetingRecorder.shared.meeting(id)?.displayTitle ?? "Meeting"
        }
    }
}

/// Text running down a rail, top to bottom.
struct VerticalLabel: View {
    let text: String
    var length: CGFloat = 120

    var body: some View {
        Text(text)
            .lineLimit(1).truncationMode(.tail)
            .frame(width: length, alignment: .leading)
            .rotationEffect(.degrees(90))
            .frame(width: 16, height: length)
    }
}

// MARK: - Library home

/// The main area on the library tab: the last thing you were in, then everything, scrolling.
struct LibraryHome: View {
    @Environment(AppModel.self) private var model
    let navigate: (LibrarySection) -> Void

    @AppStorage("sortOrder") private var sort: SortOrder = .modified
    @State private var filter: FileKind?

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "library") {
                Text("\(docs.count)").font(.mono(12.5)).foregroundStyle(Paper.textMuted).monospacedDigit()
                Spacer(minLength: 12)
                Chip(title: "All", selected: filter == nil) { filter = nil }
                Chip(title: "Notebooks", selected: filter == .notebook) { filter = .notebook }
                Chip(title: "PDFs", selected: filter == .pdf) { filter = .pdf }
                Chip(title: "Books", selected: filter == .epub) { filter = .epub }
                SortMenu(sort: $sort)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PickUpBand()
                        .frame(height: Columns.band, alignment: .topLeading)
                    let list = docs
                    if list.isEmpty {
                        Text(model.isSyncing ? "syncing your library…" : "nothing here yet. drop pdfs or epubs on this window to send them to your tablet.")
                            .font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                            .padding(.horizontal, Columns.gutter)
                    }
                    CoverGrid(docs: list, navigate: navigate)
                        .padding(.bottom, 32)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.upload(urls, to: "") }
                return true
            }
        }
        .navigationTitle("Library")
        .toolbar { ToolbarItem(placement: .navigation) { CreateMenu(folder: "") } }
    }

    private var docs: [DocumentItem] {
        let all = model.documents.filter { !$0.isFolder && !$0.isTrashed && (filter == nil || $0.kind == filter) }
        return all.sorted { a, b in
            switch sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: return a.lastModified > b.lastModified
            case .opened: return (a.lastOpened ?? .distantPast) > (b.lastOpened ?? .distantPast)
            }
        }
    }
}

/// "sort" as a mono text menu.
struct SortMenu: View {
    @Binding var sort: SortOrder
    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("sort").font(.mono(12.5)).foregroundStyle(Paper.textMuted)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Sort")
    }
}

/// Covers laid out two to a column, so the column rules fall in the gaps between them.
struct CoverGrid: View {
    @Environment(\.columnUnit) private var unit
    @Environment(\.mainUnits) private var units
    let docs: [DocumentItem]
    let navigate: (LibrarySection) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: max(units * 2, 2)),
                  alignment: .leading, spacing: 24) {
            ForEach(docs) { doc in
                LibraryCell(doc: doc, navigate: navigate)
                    .padding(.horizontal, Columns.gutter)
            }
        }
        .background(alignment: .topLeading) { InnerRules(units: units, unit: unit) }
    }
}

/// The column rules carried through the main area (it spans several columns).
struct InnerRules: View {
    let units: Int
    let unit: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(units, 1), id: \.self) { i in
                Rectangle().fill(i == 0 ? .clear : Paper.border).frame(width: 1)
                Spacer(minLength: 0).frame(width: max(unit - 1, 0))
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, -12)
        .allowsHitTesting(false)
    }
}

/// The top band of the library column: the document you were last in, with its cover.
struct PickUpBand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let doc = last {
            let pages = max(doc.displayPageCount, 1)
            let progress = Double(doc.lastOpenedPage + 1) / Double(pages)
            let writing = doc.kind == .notebook
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(text: writing ? "continue writing" : "continue reading")
                HStack(alignment: .bottom, spacing: 18) {
                    Button { model.open(doc.id) } label: {
                        Thumbnail(doc: doc)
                            .frame(width: 104, height: 139)
                            .clipped()
                            .overlay(Rectangle().strokeBorder(Paper.border))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(doc.coverTitle)")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(doc.coverTitle)
                            .font(.display(32))
                            .tracking(-0.8)
                            .foregroundStyle(Paper.text)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        Text(detail(doc, pages: pages, progress: progress))
                            .font(.mono(12.5)).foregroundStyle(Paper.textSecondary).monospacedDigit()
                        if !writing { ProgressLine(value: progress).frame(width: 160) }
                        Button(writing ? "continue writing" : "continue reading") { model.open(doc.id) }
                            .buttonStyle(AccentButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, Columns.gutter)
            .padding(.top, 14)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(text: "continue reading")
                Text("open something on your tablet or here and it waits for you in this spot.")
                    .font(.mono(12.5)).foregroundStyle(Paper.textMuted)
            }
            .padding(.horizontal, Columns.gutter).padding(.top, 14)
        }
    }

    private var last: DocumentItem? {
        model.documents.filter { !$0.isFolder && !$0.isTrashed && $0.lastOpened != nil }
            .max { ($0.lastOpened ?? .distantPast) < ($1.lastOpened ?? .distantPast) }
    }

    private func detail(_ doc: DocumentItem, pages: Int, progress: Double) -> String {
        let when = doc.lastOpened.map { "last opened " + $0.formatted(.relative(presentation: .named)) } ?? ""
        if doc.kind == .notebook { return "\(pages) page\(pages == 1 ? "" : "s") · \(when)" }
        if doc.kind == .epub { return "\(Int(progress * 100))% · \(when)" }
        return "page \(doc.lastOpenedPage + 1) of \(pages) · \(Int(progress * 100))%"
    }
}

/// Column 3: what's happening today.
struct TodayColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let navigate: (LibrarySection) -> Void
    let hide: () -> Void

    var body: some View {
        let tasks = TasksModel.shared.open
        VStack(spacing: 0) {
            ColumnHeader(title: "today") {
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).lowercased())
                    .font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                Spacer(minLength: 8)
                HideButton(title: "today", action: hide)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 3) {
                        Fact(changedToday.isEmpty ? "nothing changed yet" : "\(changedToday.count) changed", "since midnight")
                        if let next = nextMeeting {
                            Fact(next.title.lowercased(), next.isNow ? "now" : next.start.formatted(date: .omitted, time: .shortened))
                        }
                        if let m = readyNotes { Fact(m.displayTitle.lowercased(), "notes ready") }
                        Fact("\(tasks.count) open task\(tasks.count == 1 ? "" : "s")", "")
                    }
                    .padding(.top, 14)
                    .frame(height: Columns.band - 22, alignment: .topLeading)

                    RuledList(title: "meetings", more: { navigate(.meetings) }) {
                        ForEach(upcomingToday) { e in
                            RuledRow(title: "\(e.start.formatted(date: .omitted, time: .shortened)) \(e.title)",
                                     trailing: e.isNow ? "now" : e.start.formatted(.relative(presentation: .named))) {
                                navigate(.meetings)
                            }
                        }
                        ForEach(recentMeetings) { m in
                            RuledRow(title: m.displayTitle, trailing: m.aiNotes.isEmpty ? m.startedAt.formatted(.relative(presentation: .named)) : "notes ready") {
                                AppModel.shared.openMeeting(m.id)
                            }
                        }
                        if upcomingToday.isEmpty && recentMeetings.isEmpty {
                            RuledRow(title: "no meetings yet", trailing: "record", dim: true) { navigate(.meetings) }
                        }
                    }

                    RuledList(title: "open tasks · \(tasks.count)", more: { navigate(.tasks) }) {
                        ForEach(tasks.prefix(6)) { t in TaskRuledRow(task: t) { navigate(.tasks) } }
                        if tasks.count > 6 {
                            RuledRow(title: "\(tasks.count - 6) more", trailing: "→", dim: true) { navigate(.tasks) }
                        }
                        if tasks.isEmpty { RuledRow(title: "nothing open", trailing: "", dim: true) { navigate(.tasks) } }
                    }

                    if !changedToday.isEmpty {
                        RuledList(title: "changed today", more: nil) {
                            ForEach(changedToday.prefix(6)) { d in
                                RuledRow(title: d.coverTitle, trailing: d.lastModified.formatted(date: .omitted, time: .shortened)) {
                                    model.open(d.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Columns.gutter)
                .padding(.bottom, 32)
            }
        }
    }

    private var changedToday: [DocumentItem] {
        let start = Calendar.current.startOfDay(for: .now)
        return model.documents.filter { !$0.isFolder && !$0.isTrashed && $0.lastModified >= start }
            .sorted { $0.lastModified > $1.lastModified }
    }

    private var upcomingToday: [UpcomingMeeting] {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)
        return CalendarService.shared.upcoming.filter { $0.end > .now && $0.start < end }.prefix(4).map { $0 }
    }

    private var nextMeeting: UpcomingMeeting? { upcomingToday.first }

    private var recentMeetings: [Meeting] { Array(MeetingRecorder.shared.meetings.prefix(4)) }

    private var readyNotes: Meeting? {
        let start = Calendar.current.startOfDay(for: .now)
        return MeetingRecorder.shared.meetings.first { $0.startedAt >= start && !$0.aiNotes.isEmpty }
    }
}

/// Column 4: the tablet, its folders and the other ways into the library.
struct TabletColumn: View {
    @Environment(AppModel.self) private var model
    let navigate: (LibrarySection) -> Void
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "tablet") {
                Spacer(minLength: 8)
                HideButton(title: "tablet", action: hide)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TimelineView(.everyMinute) { ctx in
                        VStack(alignment: .leading, spacing: 3) {
                            Fact(syncLine(ctx.date), "")
                            Fact("\(model.documents.filter { !$0.isFolder && !$0.isTrashed }.count) items", "\(model.folders.count) folders")
                            Fact(ctx.date.formatted(date: .omitted, time: .shortened), city)
                            Button(model.isSyncing ? "syncing…" : "sync now") { Task { await model.syncNow() } }
                                .buttonStyle(.plain).font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                                .underline()
                                .disabled(!model.isPaired || model.isSyncing)
                                .padding(.top, 6)
                        }
                    }
                    .padding(.top, 14)
                    .frame(height: Columns.band - 22, alignment: .topLeading)

                    if let roots = model.subfolders(of: ""), !roots.isEmpty {
                        RuledList(title: "folders", more: nil) {
                            ForEach(roots) { f in
                                RuledRow(title: f.name, trailing: "\(model.children[f.id, default: []].filter { !$0.isTrashed }.count)") {
                                    navigate(.folder(f.id))
                                }
                                .organisable(f)
                            }
                        }
                    }
                    RuledList(title: "kinds", more: nil) {
                        kind("notebooks", .notebooks)
                        kind("pdfs", .pdfs)
                        kind("books", .books)
                    }
                    RuledList(title: "more", more: nil) {
                        kind("favourites", .favorites)
                        kind("continue reading", .continueReading)
                        RuledRow(title: "recent", trailing: "") { navigate(.recent) }
                        kind("trash", .trash)
                    }
                    if !model.allTags.isEmpty {
                        RuledList(title: "tags", more: nil) {
                            ForEach(model.allTags, id: \.self) { t in kind("#\(t)", .tag(t)) }
                        }
                    }
                }
                .padding(.horizontal, Columns.gutter)
                .padding(.bottom, 32)
            }
        }
    }

    private func kind(_ title: String, _ s: LibrarySection) -> some View {
        RuledRow(title: title, trailing: "\(model.items(in: s).count)") { navigate(s) }
    }

    private func syncLine(_ now: Date) -> String {
        if !model.isPaired { return "not connected" }
        if model.isSyncing { return "syncing…" }
        guard let last = model.lastSync else { return "not synced yet" }
        if now.timeIntervalSince(last) < 60 { return "synced just now" }
        return "synced " + last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private var city: String {
        let id = TimeZone.current.identifier
        return (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ").lowercased()
    }
}

// MARK: - Pieces

/// A column's top row: a mono label, then whatever options the column has.
struct ColumnHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            if !title.isEmpty {
                Text(title).font(.mono(12.5, weight: .medium)).foregroundStyle(Paper.text)
                    .lineLimit(1).fixedSize()
                    .accessibilityAddTraits(.isHeader)
            }
            trailing
        }
        .padding(.horizontal, Columns.gutter)
        .frame(height: Columns.header)
    }
}

struct HideButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.right.to.line").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Paper.textMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide the \(title) column")
        .accessibilityLabel("Hide \(title) column")
    }
}

/// A hidden column, folded into a thin rail with its name running vertically. Click to bring it back.
struct ColumnRail: View {
    let title: String
    let show: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: show) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.left.to.line").font(.system(size: 11, weight: .medium))
                Text(title).font(.mono(12)).fixedSize().rotationEffect(.degrees(90)).frame(width: 14, height: 60)
                Spacer()
            }
            .foregroundStyle(hover ? Paper.text : Paper.textMuted)
            .padding(.top, 13)
            .frame(width: Columns.rail)
            .frame(maxHeight: .infinity)
            .background(hover ? Paper.raised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Show the \(title) column")
        .accessibilityLabel("Show \(title) column")
    }
}

/// One line of fact in a column's top band: value in ink, qualifier muted.
struct Fact: View {
    let value: String
    let note: String
    init(_ value: String, _ note: String) { self.value = value; self.note = note }
    var body: some View {
        (Text(value).foregroundStyle(Paper.text) + Text(note.isEmpty ? "" : "  " + note).foregroundStyle(Paper.textMuted))
            .font(.mono(12.5)).monospacedDigit().lineLimit(1)
    }
}

/// A titled, ruled index list.
struct RuledList<Content: View>: View {
    let title: String
    let more: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeading(text: title)
                Spacer()
                if let more {
                    Button(action: more) { Text("all →").font(.mono(12)).foregroundStyle(Paper.textMuted) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show all \(title)")
                }
            }
            VStack(spacing: 0) { content }
        }
    }
}

/// A row of a ruled list: a full-ink hairline above, title left, a tabular fact right.
struct RuledRow: View {
    let title: String
    var trailing: String = ""
    var dim = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(dim ? Paper.textMuted : Paper.text)
                Spacer(minLength: 8)
                Text(trailing).lineLimit(1).foregroundStyle(Paper.textMuted).monospacedDigit().fixedSize()
            }
            .font(.mono(12.5))
            .frame(height: 28)
            .background(hover ? Paper.raised : .clear)
            .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// An open task with a square box you can tick.
struct TaskRuledRow: View {
    let task: TaskItem
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button { TasksModel.shared.setDone(task, true) } label: {
                Rectangle().strokeBorder(Paper.textMuted, lineWidth: 1).frame(width: 11, height: 11)
                    .frame(width: 18, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mark done")
            .accessibilityLabel("Mark \(task.text) done")
            Button(action: open) {
                HStack(spacing: 8) {
                    Text(task.text).lineLimit(1).foregroundStyle(Paper.text)
                    Spacer(minLength: 8)
                    Text(task.docName).lineLimit(1).foregroundStyle(Paper.textMuted).frame(maxWidth: 84, alignment: .trailing)
                        .layoutPriority(1)
                }
                .frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.mono(12.5))
        .background(hover ? Paper.raised : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
        .onHover { hover = $0 }
    }
}

/// A library cover in the home grid: square-cornered thumbnail, mono title and a tabular fact.
struct LibraryCell: View {
    @Environment(AppModel.self) private var model
    let doc: DocumentItem
    let navigate: (LibrarySection) -> Void
    @State private var hover = false

    var body: some View {
        Button { model.open(doc.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(0.75, contentMode: .fit)
                    .overlay { Thumbnail(doc: doc) }
                    .clipped()
                    .overlay(Rectangle().strokeBorder(hover ? Paper.rule : Paper.border))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if doc.pinned { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Paper.text) }
                        Text(doc.coverTitle).lineLimit(1).truncationMode(.tail).foregroundStyle(Paper.text)
                    }
                    Text(fact).foregroundStyle(Paper.textMuted).monospacedDigit().lineLimit(1)
                }
                .font(.mono(11.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { DocumentMenu(doc: doc, open: { model.open($0.id) }, navigate: navigate) }
        .help(doc.name)
        .accessibilityLabel("\(doc.coverTitle), \(doc.kind.label), \(fact)")
        .organisable(doc)
    }

    private var fact: String {
        let pages = doc.displayPageCount
        if doc.kind == .epub {
            return doc.lastOpenedPage > 0 && pages > 1 ? "\(Int(Double(doc.lastOpenedPage + 1) / Double(pages) * 100))%" : "book"
        }
        if doc.kind == .pdf, doc.lastOpenedPage > 0 { return "\(doc.lastOpenedPage + 1)/\(pages)" }
        return "\(pages) pp"
    }
}
