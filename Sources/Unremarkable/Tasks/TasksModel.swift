import Foundation
import Observation
import RMKit
import SwiftUI

/// Tasks from the whole library, kept in a "Tasks" notebook on the tablet.
@MainActor @Observable
final class TasksModel {
    static let shared = TasksModel()

    private(set) var tasks: [TaskItem] = []
    private(set) var isRefreshing = false
    var status: String?

    @ObservationIgnored @AppStorage("tasksNotebookEnabled") var notebookEnabled = true
    @ObservationIgnored @AppStorage("tasksHandwriting") var readHandwriting = true
    @ObservationIgnored @AppStorage("tasksFromMeetings") var fromMeetings = true
    @ObservationIgnored @AppStorage("tasksNotebookTitle") var notebookTitle = "Tasks"
    @ObservationIgnored private lazy var scanner = TaskScanner(sync: AppModel.shared.sync)

    private var db: LibraryDatabase { AppModel.shared.db }

    private init() { reload() }

    var open: [TaskItem] { tasks.filter { !$0.isDone }.sorted { $0.createdAt > $1.createdAt } }
    var done: [TaskItem] { tasks.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) } }

    var notebookID: String? {
        get { db.value("tasksNotebookID") }
        set { db.setValue(newValue ?? "", for: "tasksNotebookID") }
    }

    func reload() { tasks = db.allTasks() }

    /// Can the configured AI read handwriting images?
    var visionAvailable: Bool { AISettings.current.provider.supportsImages }

    // MARK: Editing on the Mac

    func setDone(_ task: TaskItem, _ done: Bool) {
        var t = task
        t.completedAt = done ? .now : nil
        db.saveTask(t)
        reload()
        scheduleNotebookUpdate()
    }

    func add(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        db.mergeTasks([TaskItem(text: clean, source: .captured)])
        reload()
        scheduleNotebookUpdate()
    }

    func completeAll() {
        for t in open {
            var done = t
            done.completedAt = .now
            db.saveTask(done)
        }
        reload()
        scheduleNotebookUpdate()
    }

    func delete(_ task: TaskItem) {
        db.deleteTask(task.id)
        reload()
        scheduleNotebookUpdate()
    }

    @ObservationIgnored private var pendingUpdate: Task<Void, Never>?
    /// Batches quick edits into one notebook rebuild.
    private func scheduleNotebookUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await updateNotebook()
        }
    }

    // MARK: Refresh after a sync

    /// Called after each sync: reads ticks from the Tasks notebook, adds meeting action items, scans
    /// changed pages, then rebuilds the Tasks notebook if the open list changed.
    func refresh() async {
        let model = AppModel.shared
        guard model.isPaired, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; status = nil }

        await applyTicksFromTablet()
        if fromMeetings { addMeetingActions() }

        let lastScan = db.value("tasksLastScan").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        let since = (lastScan ?? .now.addingTimeInterval(-14 * 86_400)).addingTimeInterval(-86_400)
        let settings = AISettings.current
        let reader: HandwritingOCR.Reader? = !readHandwriting ? nil
            : UserDefaults.standard.string(forKey: "ocrEngine") == "ai"
                ? (settings.provider.supportsImages ? .vision(AIProvider(settings: settings)) : nil)
                : .remarkable(language: AppModel.handwritingLanguage)
        let skip = model.excludedIDs.union([notebookID].compactMap { $0 })
        let result = await scanner.scan(handwriting: reader, skip: skip, handwritingSince: since) { msg in
            Task { @MainActor in TasksModel.shared.status = msg }
        }
        db.setValue(String(Date.now.timeIntervalSince1970), for: "tasksLastScan")
        reload()
        if result.pagesScanned + result.handwritingPages > 0 {
            model.addLog("Scanned \(result.pagesScanned) page\(result.pagesScanned == 1 ? "" : "s") for tasks\(result.handwritingPages > 0 ? " (\(result.handwritingPages) handwritten)" : ""); \(open.count) open.")
        }
        await updateNotebook()
    }

    /// Tasks ticked off in the Tasks notebook on the tablet are completed here too.
    private func applyTicksFromTablet() async {
        guard let id = notebookID, let doc = AppModel.shared.byID[id], !doc.isTrashed else { return }
        var pages: [RmPage] = []
        for i in 0..<doc.displayPageCount {
            if let page = await AppModel.shared.renderer.rmPage(doc, i) { pages.append(page) }
        }
        let ticked = TasksNotebook.ticked(in: pages)
        guard !ticked.isEmpty else { return }
        for t in open where ticked.contains(t.text.lowercased()) {
            var done = t
            done.completedAt = .now
            db.saveTask(done)
        }
        reload()
    }

    private func addMeetingActions() {
        let meetings = MeetingRecorder.shared.meetings
        var items: [TaskItem] = []
        for m in meetings where !m.aiNotes.isEmpty {
            for a in TaskExtractor.meetingActions(m.aiNotes) {
                items.append(TaskItem(text: a.text, source: .meeting, docID: m.id, docName: m.displayTitle, done: a.done, now: m.startedAt))
            }
        }
        if !items.isEmpty { db.mergeTasks(items) }
        reload()
    }

    /// Rebuilds the Tasks notebook in place when its content would change.
    func updateNotebook() async {
        let model = AppModel.shared
        guard notebookEnabled, ServerMode.isOn, model.isPaired else { return }
        let pages = TasksNotebook.pages(title: notebookTitle, tasks: tasks)
        let signature = sha256Hex(Data(pages.flatMap { $0 }.map { "\($0.style.rawValue)|\($0.text)" }.joined(separator: "\n").utf8))
        // Our notebook, else adopt an existing one with the same name (e.g. made by the web app) so the
        // tablet keeps a single Tasks notebook.
        let id = notebookID.flatMap { model.byID[$0] }.flatMap { $0.isTrashed ? nil : $0.id }
            ?? model.documents.first { $0.kind == .notebook && !$0.isTrashed && $0.name == notebookTitle }?.id
        if id != nil, db.value("tasksNotebookSignature") == signature { return }
        // Nothing to show and no notebook yet: don't create an empty one.
        if id == nil, open.isEmpty { return }
        status = "Updating the \(notebookTitle) notebook…"
        let docID = id ?? UUID().uuidString.lowercased()
        let doc = await model.write("Updated") {
            try await model.sync.replaceTypedNotebook(id: docID, title: notebookTitle, pages: pages, parentID: model.byID[docID]?.parent ?? "")
        }
        if doc != nil {
            notebookID = docID
            db.setValue(signature, for: "tasksNotebookSignature")
        }
    }
}
