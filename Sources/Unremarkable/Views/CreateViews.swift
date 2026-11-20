import RMKit
import SwiftUI
import UniformTypeIdentifiers

/// "+" toolbar menu: new typed notebook, new folder, import Markdown.
struct CreateMenu: View {
    @Environment(AppModel.self) private var model
    let folder: String
    @State private var showNotebook = false
    @State private var showFolder = false
    @State private var showImport = false
    @State private var showConvertPicker = false
    @State private var convertURL: URL?
    @State private var folderName = ""

    var body: some View {
        Menu {
            Button("New Typed Notebook…") { showNotebook = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Folder…") { folderName = ""; showFolder = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import Markdown…") { showImport = true }
            Button("Convert for reMarkable…") { showConvertPicker = true }
        } label: {
            Label("New", systemImage: "plus")
        }
        .help("Create a notebook or folder on your reMarkable")
        .onAppear {
            // Development aid: UNREMARKABLE_SHOW=new-notebook opens the sheet at launch.
            if ProcessInfo.processInfo.environment["UNREMARKABLE_SHOW"] == "new-notebook" { showNotebook = true }
        }
        .disabled(!model.isPaired)
        .sheet(isPresented: $showNotebook) {
            NewNotebookSheet(folder: folder).environment(model)
        }
        .alert("New Folder", isPresented: $showFolder) {
            TextField("Name", text: $folderName)
            Button("Create") {
                let name = folderName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await model.createFolder(name: name, in: folder) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's created on your reMarkable\(folder.isEmpty ? "" : " inside \(model.byID[folder]?.name ?? "this folder")").")
        }
        .fileImporter(isPresented: $showConvertPicker, allowedContentTypes: [.pdf, UTType(filenameExtension: "cbz") ?? .zip, .zip, UTType(filenameExtension: "epub") ?? .data]) { result in
            if case .success(let url) = result { _ = url.startAccessingSecurityScopedResource(); convertURL = url }
        }
        .sheet(item: Binding(get: { convertURL.map(IdentifiedURL.init) }, set: { convertURL = $0?.url })) { item in
            ConverterSheet(source: .file(item.url), folder: folder).environment(model)
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let access = urls.map { $0.startAccessingSecurityScopedResource() }
                await model.importMarkdown(urls, to: folder)
                for (u, ok) in zip(urls, access) where ok { u.stopAccessingSecurityScopedResource() }
            }
        }
    }
}

/// Write a typed notebook in Markdown, with a preview of how page 1 looks on the tablet.
struct NewNotebookSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State var folder: String
    @State private var title = ""
    @State private var text = ""
    @State private var busy = false
    @State private var preview: CGImage?
    @State private var pageCount = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Title", text: $title, prompt: Text("Notebook title"))
                    .textFieldStyle(.plain).font(.title2.weight(.semibold))
                Picker("Folder", selection: $folder) {
                    Text("My files").tag("")
                    ForEach(model.documents.filter { $0.isFolder && !$0.isTrashed }.sorted { $0.name < $1.name }) {
                        Text(model.path(to: $0.id).map(\.name).joined(separator: " › ")).tag($0.id)
                    }
                }
                .frame(width: 240)
            }
            .padding(16)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                    Text("# heading · ## bold · - bullet · - [ ] checkbox · --- new page")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(minWidth: 360)
                VStack(spacing: 6) {
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable().aspectRatio(contentMode: .fit)
                            .shadow(radius: 3)
                    } else {
                        Color.clear
                    }
                    Text(pageCount == 1 ? "1 page" : "Page 1 of \(pageCount)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(minWidth: 260, idealWidth: 300)
                .background(.background.secondary)
            }
            Divider()
            HStack {
                Text("Typed text you can keep editing on the tablet with the Type Folio or keyboard.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    busy = true
                    Task {
                        let name = title.trimmingCharacters(in: .whitespaces)
                        await model.createNotebook(title: name.isEmpty ? "Untitled" : name, markdown: text, in: folder)
                        busy = false
                        dismiss()
                    }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Send to reMarkable") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || (title.isEmpty && text.isEmpty))
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: text + (scheme == .dark ? "d" : "l")) {
            try? await Task.sleep(for: .milliseconds(200))
            let pages = TypedNotebook.pages(fromMarkdown: text.isEmpty ? " " : text)
            pageCount = max(pages.count, 1)
            let dark = scheme == .dark
            preview = await Task.detached {
                let data = RmWriter.page(paragraphs: pages.first ?? [])
                return PageRenderer.renderNotebook(RmParser.parse(data), options: RenderOptions(dark: dark, pixelWidth: 600))
            }.value
        }
    }
}

/// Quick note field for the menu bar panel and command palette: appends to the "Quick Notes" notebook.
struct QuickNoteField: View {
    @Environment(AppModel.self) private var model
    @AppStorage("quickCaptureMode") private var mode = "note"
    @State private var text = ""
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $mode) {
                Text("Note").tag("note")
                Text("Task").tag("task")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                TextField(mode == "task" ? "New task…" : "Quick note to your reMarkable…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if busy { ProgressView().controlSize(.small) }
            }
            Text(status ?? (mode == "task" ? "Added to your Tasks and the Tasks notebook." : "Added to \"\(AppModel.quickNotesTitle)\". Start a line with [ ] for a checkbox."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(!model.isPaired)
    }

    private func send() {
        let note = text
        guard !note.trimmingCharacters(in: .whitespaces).isEmpty, !busy else { return }
        if mode == "task" {
            TasksModel.shared.add(note)
            text = ""
            status = "Task added at \(Date.now.formatted(date: .omitted, time: .shortened))."
            return
        }
        busy = true
        Task {
            let doc = await model.quickNote(note)
            busy = false
            if doc != nil {
                text = ""
                status = "Sent at \(Date.now.formatted(date: .omitted, time: .shortened))."
            } else {
                status = model.lastError ?? "Couldn't send the note."
            }
        }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.path }
}
