import AppKit
import Foundation
import Observation
import RMKit
import SwiftUI

/// The app's MCP server: the web app's 17 library tools plus Ask and meetings, over HTTP (this Mac or the
/// local network) with a bearer token. `--mcp-stdio` bridges stdio clients to it.
@MainActor @Observable
final class MCPService {
    static let shared = MCPService()
    nonisolated static let defaultPort: UInt16 = 8100

    private(set) var running = false
    private(set) var lastError: String?
    private(set) var recent: [String] = []
    @ObservationIgnored private var server: MCPHTTPServer?

    @ObservationIgnored @AppStorage("mcpEnabled") var enabled = true
    @ObservationIgnored @AppStorage("mcpScope") var scope = "network"
    @ObservationIgnored @AppStorage("mcpPort") var port = Int(MCPService.defaultPort)

    /// Token clients send as `Authorization: Bearer …`; created on first use and kept in the secrets file.
    var token: String {
        if let t = Secrets.get("mcp-token"), !t.isEmpty { return t }
        let t = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }.joined().prefix(48)
        Secrets.set(String(t), for: "mcp-token")
        return String(t)
    }

    func regenerateToken() {
        Secrets.set(nil, for: "mcp-token")
        _ = token
        restart()
    }

    func restart() {
        server?.stop()
        server = nil
        running = false
        lastError = nil
        guard enabled, ServerMode.isOn else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let s = MCPHTTPServer(handler: MCPHandler(tools: Self.tools(), serverName: "un-remarkable-mac", version: version), token: token)
        s.onLog = { line in Task { @MainActor in MCPService.shared.log(line) } }
        do {
            try s.start(port: UInt16(clamping: port), scope: scope == "localhost" ? .localhost : .network)
            server = s
            running = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func log(_ line: String) {
        recent.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(line)", at: 0)
        if recent.count > 30 { recent.removeLast() }
    }

    var localURL: String { "http://127.0.0.1:\(port)/mcp" }
    var networkURL: String {
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local.local", with: ".local")
        return "http://\(host.hasSuffix(".local") ? host : host + ".local"):\(port)/mcp"
    }

    // MARK: Tools

    nonisolated static func tools() -> [MCPTool] {
        typealias P = MCPTool
        return [
            MCPTool(name: "list_documents",
                    description: "List documents and folders in the reMarkable library, optionally inside one folder or of one type. Excluded folders and files are left out unless include_excluded is true.",
                    properties: ["parent_id": P.prop("string", "Folder ID, or empty for the top level"),
                                 "file_type": P.prop("string", "notebook, pdf, epub or folder (optional)"),
                                 "include_excluded": P.prop("boolean", "Include documents excluded from search")]) { args in
                await MainActor.run {
                    let m = AppModel.shared
                    let parent = args.string("parent_id") ?? ""
                    let type = (args.string("file_type") ?? "").lowercased()
                    let excluded = (args.bool("include_excluded") ?? false) ? [] : m.excludedIDs
                    return .json(m.documents.filter { $0.parent == parent && !$0.isTrashed && !excluded.contains($0.id) && (type.isEmpty || $0.kind.rawValue == type) }
                        .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
                        .map(describe))
                }
            },
            MCPTool(name: "search",
                    description: "Search titles, tags, typed notebook text and PDF text across the reMarkable library. Excluded folders and files match on title only.",
                    properties: ["query": P.prop("string", "Words to search for"), "limit": P.prop("integer", "Maximum results (default 20)"),
                                 "notes_only": P.prop("boolean", "Only notebooks")], required: ["query"]) { args in
                let q = args.string("query") ?? ""
                let limit = args.int("limit") ?? 20
                let hits = await AppModel.shared.search(q, notesOnly: args.bool("notes_only") ?? false)
                return await MainActor.run {
                    .json(hits.prefix(limit).compactMap { h -> [String: Any]? in
                        guard let d = AppModel.shared.byID[h.docID] else { return nil }
                        var r = describe(d)
                        r["snippet"] = h.snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
                        return r
                    })
                }
            },
            MCPTool(name: "get_document", description: "Get metadata, page count, pages and tags for a document.",
                    properties: ["doc_id": P.prop("string", "Document ID")], required: ["doc_id"]) { args in
                try await MainActor.run {
                    guard let d = AppModel.shared.byID[args.string("doc_id") ?? ""] else { throw RMError.notFound("No such document") }
                    var r = describe(d)
                    r["pages"] = d.pages.enumerated().map { i, p in ["index": i, "page_id": p.pageID, "has_ink": d.rmFile(for: i) != nil] }
                    r["path"] = AppModel.shared.path(to: d.parent).map(\.name).joined(separator: " / ")
                    return .json(r)
                }
            },
            MCPTool(name: "get_page_text", description: "Typed notebook text or PDF text of one page (for handwriting use convert_handwriting or get_page_image).",
                    properties: ["doc_id": P.prop("string", "Document ID"), "page_idx": P.prop("integer", "Page index from 0")], required: ["doc_id"]) { args in
                let (doc, sync) = try await MainActor.run { () throws -> (DocumentItem, SyncEngine) in
                    guard let d = AppModel.shared.byID[args.string("doc_id") ?? ""] else { throw RMError.notFound("No such document") }
                    return (d, AppModel.shared.sync)
                }
                let page = args.int("page_idx") ?? 0
                let text = await NotesQA(sync: sync).text(of: doc, page: page)
                return .json(["doc_id": doc.id, "name": doc.name, "page_idx": page, "text": text])
            },
            MCPTool(name: "convert_handwriting", description: "Handwriting on a notebook page as text, converted by reMarkable's own handwriting recognition (as \"Convert to text\" on the tablet).",
                    properties: ["doc_id": P.prop("string", "Document ID"), "page_idx": P.prop("integer", "Page index from 0"),
                                 "language": P.prop("string", "Language code such as en_US, en_GB, de_DE (default: the app's setting)")], required: ["doc_id"]) { args in
                let (doc, sync, renderer, lang) = try await MainActor.run { () throws -> (DocumentItem, SyncEngine, DocumentRenderer, String) in
                    guard let d = AppModel.shared.byID[args.string("doc_id") ?? ""] else { throw RMError.notFound("No such document") }
                    return (d, AppModel.shared.sync, AppModel.shared.renderer, AppModel.handwritingLanguage)
                }
                let page = args.int("page_idx") ?? 0
                guard let parsed = await renderer.rmPage(doc, page) else {
                    return .json(["doc_id": doc.id, "name": doc.name, "page_idx": page, "text": ""])
                }
                let text = try await sync.client.convertHandwriting(parsed, language: args.string("language") ?? lang)
                return .json(["doc_id": doc.id, "name": doc.name, "page_idx": page, "text": text])
            },
            MCPTool(name: "get_page_image", description: "Render a page (with handwriting) as a PNG image, for reading handwriting.",
                    properties: ["doc_id": P.prop("string", "Document ID"), "page_idx": P.prop("integer", "Page index from 0"),
                                 "dark_mode": P.prop("boolean", "Render in dark mode")], required: ["doc_id"]) { args in
                let (doc, renderer) = try await MainActor.run { () throws -> (DocumentItem, DocumentRenderer) in
                    guard let d = AppModel.shared.byID[args.string("doc_id") ?? ""] else { throw RMError.notFound("No such document") }
                    return (d, AppModel.shared.renderer)
                }
                let page = args.int("page_idx") ?? 0
                guard let box = try await renderer.page(doc, index: page, options: RenderOptions(dark: args.bool("dark_mode") ?? false, pixelWidth: 1400)),
                      let png = NSBitmapImageRep(cgImage: box.image).representation(using: .png, properties: [:]) else {
                    throw RMError.notFound("Couldn't render that page")
                }
                return .png(png, caption: "\(doc.name), page \(page + 1)")
            },
            MCPTool(name: "recent_changes", description: "Documents modified most recently (excluded ones left out).",
                    properties: ["limit": P.prop("integer", "How many (default 15)")]) { args in
                await MainActor.run {
                    let m = AppModel.shared
                    let ex = m.excludedIDs
                    return .json(m.documents.filter { !$0.isFolder && !$0.isTrashed && !ex.contains($0.id) }
                        .sorted { $0.lastModified > $1.lastModified }.prefix(args.int("limit") ?? 15).map(describe))
                }
            },
            MCPTool(name: "sync_status", description: "Cloud sync status: connected, syncing, last sync, document count.") { _ in
                await MainActor.run {
                    let m = AppModel.shared
                    return .json(["connected": m.isPaired, "syncing": m.isSyncing, "stage": m.progress.stage,
                                  "last_sync": m.lastSync.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                                  "documents": m.documents.filter { !$0.isFolder }.count, "last_error": m.lastError ?? ""])
                }
            },
            MCPTool(name: "list_tasks", description: "Tasks from notebooks, meetings and quick capture.",
                    properties: ["status": P.prop("string", "open (default), completed or all"), "doc_id": P.prop("string", "Only tasks from this document")]) { args in
                await MainActor.run {
                    let status = args.string("status") ?? "open"
                    let doc = args.string("doc_id") ?? ""
                    return .json(TasksModel.shared.tasks.filter {
                        (status == "all" || (status == "open") != $0.isDone) && (doc.isEmpty || $0.docID == doc)
                    }.map { t -> [String: Any] in
                        ["task_id": t.id, "text": t.text, "status": t.isDone ? "completed" : "open", "source": t.source.rawValue,
                         "doc_id": t.docID, "doc_name": t.docName, "page_idx": t.pageIndex]
                    })
                }
            },
            MCPTool(name: "complete_task", description: "Mark a task as completed.", properties: ["task_id": P.prop("string", "Task ID")], required: ["task_id"]) { args in
                try await MainActor.run {
                    guard let t = TasksModel.shared.tasks.first(where: { $0.id == args.string("task_id") }) else { throw RMError.notFound("No such task") }
                    TasksModel.shared.setDone(t, true)
                    return .json(["ok": true, "task_id": t.id])
                }
            },
            MCPTool(name: "create_notebook", description: "Create a typed notebook on the tablet from Markdown (# heading, - bullets, - [ ] checkboxes, --- new page).",
                    properties: ["title": P.prop("string", "Notebook name"), "text": P.prop("string", "Markdown content"),
                                 "parent_id": P.prop("string", "Folder ID (optional)")], required: ["title"]) { args in
                guard let d = await AppModel.shared.createNotebook(title: args.string("title") ?? "Untitled", markdown: args.string("text") ?? "",
                                                                  in: args.string("parent_id") ?? "") else { throw RMError.malformed("Couldn't create the notebook") }
                return .json(describe(d))
            },
            MCPTool(name: "append_task", description: "Add a task; it appears in the Tasks notebook on the tablet.",
                    properties: ["text": P.prop("string", "Task"), "notebook_title": P.prop("string", "Ignored; the Tasks notebook is used")], required: ["text"]) { args in
                await MainActor.run { TasksModel.shared.add(args.string("text") ?? "") }
                return .json(["ok": true])
            },
            MCPTool(name: "quick_capture", description: "Capture a task (to Tasks) or a dated note (to the Quick Notes notebook).",
                    properties: ["text": P.prop("string", "What to capture"), "is_task": P.prop("boolean", "Task (default) or note"),
                                 "notebook_title": P.prop("string", "Notebook for notes (default Quick Notes)")], required: ["text"]) { args in
                let text = args.string("text") ?? ""
                if args.bool("is_task") ?? true {
                    await MainActor.run { TasksModel.shared.add(text) }
                    return .json(["ok": true, "captured_as": "task"])
                }
                let fallback = await MainActor.run { AppModel.quickNotesTitle }
                let title = args.string("notebook_title").flatMap { $0.isEmpty ? nil : $0 } ?? fallback
                guard let d = await AppModel.shared.write("Added a quick note to", { try await AppModel.shared.sync.appendNote(text, toNotebookNamed: title) }) else {
                    throw RMError.malformed("Couldn't add the note")
                }
                return .json(["ok": true, "captured_as": "note", "notebook": d.name])
            },
            MCPTool(name: "update_page_text", description: "Replace the typed text of a notebook page (Markdown). Handwriting on the page is kept.",
                    properties: ["doc_id": P.prop("string", "Notebook ID"), "page_idx": P.prop("integer", "Page index from 0"),
                                 "text": P.prop("string", "New typed text (Markdown)")], required: ["doc_id", "page_idx", "text"]) { args in
                let id = args.string("doc_id") ?? ""
                guard let d = await AppModel.shared.write("Updated", { try await AppModel.shared.sync.replacePageText(docID: id, page: args.int("page_idx") ?? 0, markdown: args.string("text") ?? "") }) else {
                    throw RMError.malformed("Couldn't update the page")
                }
                return .json(["ok": true, "doc_id": d.id])
            },
            MCPTool(name: "list_folders", description: "All folders with their full paths (excluded folders left out).") { _ in
                await MainActor.run {
                    let m = AppModel.shared
                    let ex = m.excludedIDs
                    return .json(m.documents.filter { $0.isFolder && !$0.isTrashed && !ex.contains($0.id) }.map { f -> [String: Any] in
                        ["id": f.id, "name": f.name, "parent_id": f.parent, "path": m.path(to: f.id).map(\.name).joined(separator: " / ")]
                    }.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") })
                }
            },
            MCPTool(name: "create_folder", description: "Create a folder.",
                    properties: ["name": P.prop("string", "Folder name"), "parent_id": P.prop("string", "Parent folder ID (optional)")], required: ["name"]) { args in
                guard let f = await AppModel.shared.createFolder(name: args.string("name") ?? "New Folder", in: args.string("parent_id") ?? "") else {
                    throw RMError.malformed("Couldn't create the folder")
                }
                return .json(describe(f))
            },
            MCPTool(name: "move_document", description: "Move a document or folder into another folder (empty for the top level).",
                    properties: ["doc_id": P.prop("string", "Document or folder ID"), "parent_id": P.prop("string", "Target folder ID")], required: ["doc_id"]) { args in
                guard let d = await MainActor.run(body: { AppModel.shared.byID[args.string("doc_id") ?? ""] }) else { throw RMError.notFound("No such document") }
                await AppModel.shared.move([d], to: args.string("parent_id") ?? "")
                return .json(["ok": true])
            },
            MCPTool(name: "delete_document", description: "Move a document or folder to the tablet's Trash (recoverable there).",
                    properties: ["doc_id": P.prop("string", "Document or folder ID")], required: ["doc_id"]) { args in
                guard let d = await MainActor.run(body: { AppModel.shared.byID[args.string("doc_id") ?? ""] }) else { throw RMError.notFound("No such document") }
                await AppModel.shared.trash([d])
                return .json(["ok": true, "moved_to": "trash"])
            },
            // Mac-only tools
            MCPTool(name: "ask_notes", description: "Answer a question from the user's notes and PDFs, citing documents and pages (runs the app's Ask).",
                    properties: ["question": P.prop("string", "The question")], required: ["question"]) { args in
                let (docs, excluded, sync) = await MainActor.run { (AppModel.shared.documents, AppModel.shared.excludedIDs, AppModel.shared.sync) }
                let a = try await NotesQA(sync: sync).answer(args.string("question") ?? "", documents: docs, excluded: excluded,
                                                             provider: AIProvider(settings: AISettings.current))
                return .json(["answer": a.text, "sources": a.sources.map { ["doc_id": $0.docID, "name": $0.docName, "page_idx": $0.page, "excerpt": $0.text] }])
            },
            MCPTool(name: "list_meetings", description: "Meetings recorded on this Mac, newest first.",
                    properties: ["limit": P.prop("integer", "How many (default 20)")]) { args in
                await MainActor.run {
                    .json(MeetingRecorder.shared.meetings.prefix(args.int("limit") ?? 20).map { m -> [String: Any] in
                        ["meeting_id": m.id, "title": m.displayTitle, "started": ISO8601DateFormatter().string(from: m.startedAt),
                         "duration_seconds": Int(m.duration), "has_ai_notes": !m.aiNotes.isEmpty]
                    })
                }
            },
            MCPTool(name: "get_meeting", description: "A recorded meeting's AI notes, typed notes and transcript.",
                    properties: ["meeting_id": P.prop("string", "Meeting ID")], required: ["meeting_id"]) { args in
                try await MainActor.run {
                    guard let m = MeetingRecorder.shared.meeting(args.string("meeting_id") ?? "") else { throw RMError.notFound("No such meeting") }
                    return .json(["title": m.displayTitle, "started": ISO8601DateFormatter().string(from: m.startedAt),
                                  "ai_notes": m.aiNotes, "my_notes": m.myNotes, "transcript": m.transcriptText])
                }
            },
        ]
    }

    nonisolated static func describe(_ d: DocumentItem) -> [String: Any] {
        ["id": d.id, "name": d.name, "type": d.kind.rawValue, "parent_id": d.parent, "pages": d.displayPageCount,
         "modified": ISO8601DateFormatter().string(from: d.lastModified), "tags": d.tags, "favourite": d.pinned]
    }
}

private func describe(_ d: DocumentItem) -> [String: Any] { MCPService.describe(d) }
