import AppKit
import RMKit
import SwiftUI

/// Turns a two-finger horizontal trackpad swipe over the page into one page turn (+1 next, -1 previous),
/// like swiping in the web reader. Vertical scrolling (fit-width mode) passes through untouched.
struct SwipePager: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        let v = SwipeView()
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ v: SwipeView, context: Context) { v.onSwipe = onSwipe }

    static func dismantleNSView(_ v: SwipeView, coordinator: ()) { v.stop() }

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event was a page swipe (and is consumed).
        private func handle(_ e: NSEvent) -> Bool {
            guard e.window === window, e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return false }
            let p = convert(e.locationInWindow, from: nil)
            guard bounds.contains(p) else { return false }
            if e.phase.contains(.began) { accumulated = 0; fired = false }
            let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
            guard abs(dx) > abs(dy) || accumulated != 0 else { return false }
            accumulated += dx
            if !fired, abs(accumulated) > 60 {
                fired = true
                // Fingers moving left (negative delta) brings in the next page, as on an iPad.
                onSwipe?(accumulated < 0 ? 1 : -1)
            }
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) { accumulated = 0; fired = false }
            return true
        }
    }
}

/// The web app's Type Folio drawer: edit a notebook page's typed text as Markdown. Handwriting on the page
/// is kept; the change syncs to the tablet.
struct PageTextEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let doc: DocumentItem
    let page: Int
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Typed text").font(.headline)
                    Text("\(doc.name), page \(page + 1)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(14)
            Divider()
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .disabled(loading)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("# heading · ## bold · - bullet · - [ ] checkbox. Handwriting on the page stays where it is.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button {
                        save()
                    } label: {
                        if saving { ProgressView().controlSize(.small) } else { Text("Save to reMarkable") }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(loading || saving || text == original)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 560, minHeight: 460)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let file = doc.rmFile(for: page) else { return } // a blank page: start empty
        do {
            let data = try await model.sync.blob(file.hash, filename: file.name)
            guard let parsed = RmParser.parse(data) else { return }
            original = TypedNotebook.markdown(from: parsed)
            text = original
        } catch {
            self.error = "Couldn't read the page: \(error.localizedDescription)"
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            let updated = await model.write("Updated page \(page + 1) of") {
                try await model.sync.replacePageText(docID: doc.id, page: page, markdown: text)
            }
            saving = false
            if updated != nil { dismiss() } else { error = model.lastError ?? "Couldn't save the page." }
        }
    }
}

/// "Convert to text" as on the tablet: reMarkable's handwriting service reads this page or the whole notebook.
/// The text can be copied or sent back as a typed notebook. Results are cached per page version for search.
struct HandwritingTextSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let doc: DocumentItem
    let page: Int
    @State private var wholeNotebook = false
    @State private var text = ""
    @State private var status: String?
    @State private var working = false
    @State private var error: String?
    @State private var copied = false
    @AppStorage("handwritingLanguage") private var language = HandwritingConversion.defaultLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Convert handwriting to text").font(.headline)
                    Text(doc.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Convert", selection: $wholeNotebook) {
                    Text("Page \(page + 1)").tag(false)
                    Text("Whole notebook").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(working)
                Picker("Language", selection: $language) {
                    ForEach(HandwritingConversion.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(working)
                .help("Handwriting language")
            }
            .padding(14)
            Divider()
            ZStack {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .accessibilityLabel("Converted text")
                if working {
                    VStack(spacing: 8) {
                        ProgressView()
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(16)
                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
                } else if text.isEmpty, error == nil {
                    Text("No handwriting found.").foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Converted by reMarkable's handwriting service. You can correct the text before copying or saving it.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    }
                    .disabled(text.isEmpty || working)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save as Typed Notebook", action: saveNotebook)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(text.isEmpty || working || !model.isPaired)
                        .help("Creates \"\(doc.name) (text)\" next to this notebook on your reMarkable")
                }
            }
            .padding(14)
        }
        .frame(minWidth: 600, minHeight: 480)
        .task(id: "\(wholeNotebook)-\(language)") { await convert() }
        .onChange(of: text) { copied = false }
    }

    private func convert() async {
        working = true
        error = nil
        defer { working = false; status = nil }
        let pages = wholeNotebook ? Array(0..<doc.displayPageCount) : [page]
        var parts: [String] = []
        for i in pages {
            if Task.isCancelled { return }
            guard let rm = doc.rmFile(for: i), let parsed = await model.renderer.rmPage(doc, i),
                  HandwritingConversion.hasHandwriting(parsed) else { continue }
            status = pages.count > 1 ? "Page \(i + 1) of \(pages.count)…" : "Converting…"
            do {
                // Search caches the user's default language only; other languages are one-offs.
                let cached = language == AppModel.handwritingLanguage ? model.db.ocrText(rm.hash) : nil
                let converted: String
                if let cached, !cached.isEmpty {
                    converted = cached
                } else {
                    converted = try await model.sync.client.convertHandwriting(parsed, language: language)
                    if language == AppModel.handwritingLanguage { model.db.setOCRText(converted, for: rm.hash) }
                }
                guard !converted.isEmpty else { continue }
                parts.append(wholeNotebook ? "## Page \(i + 1)\n\(converted)" : converted)
            } catch {
                self.error = "Couldn't convert page \(i + 1): \(error.localizedDescription)"
            }
        }
        text = parts.joined(separator: "\n\n")
    }

    private func saveNotebook() {
        let title = "\(doc.name) (text)"
        let md = text
        Task {
            if await model.write("Created notebook", { try await model.sync.createTypedNotebook(title: title, markdown: md, parentID: doc.parent) }) != nil {
                dismiss()
            } else {
                error = model.lastError ?? "Couldn't create the notebook."
            }
        }
    }
}
