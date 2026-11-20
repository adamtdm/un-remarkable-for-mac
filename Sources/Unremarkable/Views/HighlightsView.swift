import AppKit
import RMKit
import SwiftUI
import UniformTypeIdentifiers

/// Highlights from every PDF and EPUB, most recently read book first (the web app's library highlights).
/// Only the small page files are read, so books don't need to be downloaded.
@MainActor @Observable
final class HighlightsModel {
    static let shared = HighlightsModel()

    struct Book: Identifiable {
        let doc: DocumentItem
        let highlights: [HighlightItem]
        var id: String { doc.id }
    }

    private(set) var books: [Book] = []
    private(set) var progress: (done: Int, total: Int)?
    @ObservationIgnored private var cache: [String: (hash: String, items: [HighlightItem])] = [:]

    func refresh() async {
        guard progress == nil else { return }
        let model = AppModel.shared
        let docs = model.documents
            .filter { !$0.isTrashed && ($0.kind == .pdf || $0.kind == .epub) && $0.pages.contains { _ in true } }
            .filter { d in (0..<d.displayPageCount).contains { d.rmFile(for: $0) != nil } }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        progress = (0, docs.count)
        var out: [Book] = []
        for (i, d) in docs.enumerated() {
            let items: [HighlightItem]
            if let c = cache[d.id], c.hash == d.hash {
                items = c.items
            } else {
                items = await model.renderer.highlights(d)
                cache[d.id] = (d.hash, items)
            }
            if !items.isEmpty { out.append(Book(doc: d, highlights: items)) }
            progress = (i + 1, docs.count)
            if i % 10 == 9 { books = out }
        }
        books = out
        progress = nil
    }

    static func markdown(_ books: [Book]) -> String {
        var md = "# Highlights\n\n"
        for b in books {
            md += "## \(b.doc.name)\n\n"
            for h in b.highlights { md += "> \(h.text.replacingOccurrences(of: "\n", with: " "))\n\n— page \(h.pageIndex + 1)\n\n" }
        }
        return md
    }
}

struct HighlightsView: View {
    @Environment(AppModel.self) private var model
    @State private var store = HighlightsModel.shared
    @State private var filter = ""

    private var shown: [HighlightsModel.Book] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.books }
        return store.books.compactMap { b in
            if b.doc.name.localizedCaseInsensitiveContains(q) { return b }
            let hits = b.highlights.filter { $0.text.localizedCaseInsensitiveContains(q) }
            return hits.isEmpty ? nil : .init(doc: b.doc, highlights: hits)
        }
    }

    @Environment(\.columnUnit) private var unit
    @Environment(\.mainUnits) private var units

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "highlights") {
                Text(summary.lowercased()).font(.mono(12.5)).foregroundStyle(Paper.textMuted).lineLimit(1)
                Spacer(minLength: 12)
                RuledField(prompt: "Filter highlights", text: $filter).frame(maxWidth: 200)
                Button("export…", action: export).buttonStyle(MonoButtonStyle()).disabled(store.books.isEmpty)
                    .help("Export as Markdown")
                Button("rescan") { Task { await store.refresh() } }.buttonStyle(MonoButtonStyle())
                    .disabled(store.progress != nil)
            }
            if let p = store.progress {
                ProgressLine(value: Double(p.done) / Double(max(p.total, 1)))
            }
            if shown.isEmpty && store.progress == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(filter.isEmpty ? "no highlights yet" : "no matches").font(.display(26)).foregroundStyle(Paper.text)
                    Text(filter.isEmpty ? "Text you highlight in PDFs and books on your reMarkable shows up here." : "Try another word.")
                        .font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                }
                .padding(.horizontal, Columns.gutter).padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: max(units, 1)),
                              alignment: .leading, spacing: 30) {
                        ForEach(shown) { book in bookSection(book).padding(.horizontal, Columns.gutter) }
                    }
                    .background(alignment: .topLeading) { InnerRules(units: units, unit: unit) }
                    .padding(.top, 14).padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("Highlights")
        .task { if store.books.isEmpty { await store.refresh() } }
    }

    private var summary: String {
        let n = store.books.reduce(0) { $0 + $1.highlights.count }
        return n == 0 ? "From your PDFs and books" : "\(n) highlight\(n == 1 ? "" : "s") in \(store.books.count) book\(store.books.count == 1 ? "" : "s")"
    }

    private func bookSection(_ book: HighlightsModel.Book) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(book.doc.coverTitle).font(.mono(12.5, weight: .medium)).foregroundStyle(Paper.text).lineLimit(2)
                Spacer(minLength: 8)
                Button("open") { open(book.doc, page: nil) }.buttonStyle(MonoButtonStyle())
            }
            ForEach(book.highlights) { h in
                Button { open(book.doc, page: h.pageIndex) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(h.swatch).frame(width: 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.text).font(.display(16)).foregroundStyle(Paper.text)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Text("p. \(h.pageIndex + 1)").font(.mono(12)).foregroundStyle(Paper.textMuted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(h.text, forType: .string)
                    }
                }
            }
        }
    }

    private func open(_ doc: DocumentItem, page: Int?) {
        if let page { UserDefaults.standard.set(page, forKey: "reader.openPage.\(doc.id)") }
        model.open(doc.id)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Highlights.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? HighlightsModel.markdown(shown).write(to: url, atomically: true, encoding: .utf8)
    }
}
