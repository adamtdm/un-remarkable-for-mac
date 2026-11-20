import RMKit
import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "connect") {
                Text("no tablet linked yet").font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("connect your remarkable").font(.display(40)).tracking(-1.2).foregroundStyle(Paper.text)
                    Text("Un-remarkable syncs straight from the reMarkable cloud. No server, no jailbreak.")
                        .font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                }
                VStack(alignment: .leading, spacing: 0) {
                    step(1, "Sign in on the reMarkable connect page and get a one-time code.") {
                        Link("get a code ↗", destination: AuthManager.pairingURL)
                            .font(.mono(12.5, weight: .medium)).foregroundStyle(Paper.text)
                    }
                    step(2, "Type the 8-character code here.") {
                        RuledField(prompt: "abcd1234", text: $code)
                            .frame(width: 140)
                            .focused($focused)
                            .onSubmit(connect)
                            .onChange(of: code) { _, v in code = String(v.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8)) }
                    }
                    Rectangle().fill(Paper.rule).frame(height: 1)
                }
                if let error {
                    Text(error).font(.mono(12.5)).foregroundStyle(Paper.accent)
                }
                HStack(spacing: 14) {
                    Button(busy ? "connecting…" : "connect", action: connect)
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.count != 8 || busy)
                    Text("Your sign-in token is stored only on this Mac. It shows up as a desktop app in your reMarkable account.")
                        .font(.mono(12)).foregroundStyle(Paper.textMuted)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, Columns.gutter).padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { focused = true }
    }

    private func step(_ n: Int, _ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 14) {
            Text("\(n)").font(.mono(12.5, weight: .medium)).foregroundStyle(Paper.text).frame(width: 18, alignment: .leading)
            Text(text).font(.mono(12.5)).foregroundStyle(Paper.textSecondary)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
    }

    private func connect() {
        guard code.count == 8, !busy else { return }
        busy = true
        error = nil
        Task {
            do { try await model.pair(code: code) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

// MARK: - Sync status

struct SyncStatusButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            if model.isSyncing {
                ProgressView().controlSize(.small)
            } else if model.lastError != nil {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
            } else if !model.isPaired {
                Image(systemName: "icloud.slash")
            } else {
                Image(systemName: "checkmark.icloud")
            }
        }
        .help("Sync status")
        .popover(isPresented: $showing, arrowEdge: .bottom) { SyncMonitor().environment(model) }
    }
}

struct SyncMonitor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sync").font(.headline)
                Spacer()
                Button("Sync Now") { Task { await model.syncNow() } }
                    .disabled(!model.isPaired || model.isSyncing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.progress.stage).fontWeight(.medium)
                if model.isSyncing, model.progress.total > 0 {
                    ProgressView(value: model.progress.fraction)
                }
                if !model.progress.message.isEmpty {
                    Text(model.progress.message).font(.caption).foregroundStyle(.secondary)
                }
                if let i = model.indexing, i.total > 0 {
                    Text("Indexing text for search: \(i.done) of \(i.total)").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(i.done), total: Double(i.total))
                }
            }
            HStack {
                Text("\(model.documents.filter { !$0.isFolder }.count) documents")
                Spacer()
                if let d = model.lastSync { Text("Last sync \(d.formatted(.relative(presentation: .named)))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Activity").font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.log) { line in
                        HStack(alignment: .top) {
                            Text(line.date, format: .dateTime.hour().minute()).monospacedDigit().foregroundStyle(.tertiary)
                            Text(line.text).foregroundStyle(line.isError ? .red : .primary)
                        }
                        .font(.caption)
                    }
                    if model.log.isEmpty { Text("No activity yet.").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            .frame(height: 160)
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - Command palette

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let navigate: (LibrarySection) -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let action: () -> Void
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Paper.textMuted)
                    TextField("Go to", text: $query, prompt: Text("open a document, folder or command…").foregroundStyle(Paper.textMuted))
                        .textFieldStyle(.plain).font(.mono(15)).focused($focused)
                        .onSubmit { run(selected) }
                }
                .padding(.horizontal, Columns.gutter).frame(height: 48)
                Rectangle().fill(Paper.rule).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                HStack(spacing: 10) {
                                    Image(systemName: row.symbol).font(.system(size: 11)).frame(width: 16)
                                        .foregroundStyle(i == selected ? Paper.onAccent : Paper.textMuted)
                                    Text(row.title).lineLimit(1)
                                    Spacer()
                                    Text(row.detail.lowercased()).foregroundStyle(i == selected ? Paper.onAccent : Paper.textMuted).lineLimit(1)
                                }
                                .font(.mono(12.5))
                                .foregroundStyle(i == selected ? Paper.onAccent : Paper.text)
                                .padding(.horizontal, Columns.gutter).frame(height: 30)
                                .background(i == selected ? Paper.text : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { run(i) }
                                .id(i)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selected) { _, s in proxy.scrollTo(s) }
                }
            }
            .background(Paper.background)
            .overlay(Rectangle().strokeBorder(Paper.rule))
            .frame(width: 600)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(rows.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Row] = []
        let commands: [Row] = [
            Row(id: "cmd-sync", title: "Sync now", detail: "Command", symbol: "arrow.triangle.2.circlepath") { Task { await model.syncNow() } },
            Row(id: "cmd-settings", title: "Settings", detail: "Command", symbol: "gearshape") { SettingsRouter.open() },
            Row(id: "cmd-continue", title: "Continue Reading", detail: "Section", symbol: "book") { navigate(.continueReading) },
            Row(id: "cmd-fav", title: "Favourites", detail: "Section", symbol: "star") { navigate(.favorites) },
            Row(id: "cmd-recent", title: "Recent", detail: "Section", symbol: "clock") { navigate(.recent) },
        ]
        out += commands.filter { q.isEmpty || $0.title.lowercased().contains(q) }

        let docs = model.documents.filter { !$0.isTrashed }
        let matches: [DocumentItem] = q.isEmpty
            ? docs.filter { !$0.isFolder }.sorted { $0.lastModified > $1.lastModified }.prefix(12).map { $0 }
            : docs.compactMap { d in fuzzyScore(d.name.lowercased(), q).map { (d, $0) } }
                .sorted { $0.1 > $1.1 }.prefix(40).map(\.0)
        for d in matches {
            out.append(Row(id: d.id, title: d.name, detail: d.isFolder ? "Folder" : d.kind.label, symbol: d.kind.symbol) {
                if d.isFolder { navigate(.folder(d.id)) } else { model.open(d.id) }
            })
        }
        return out
    }

    /// Subsequence match; contiguous runs and word starts score higher.
    private func fuzzyScore(_ text: String, _ q: String) -> Int? {
        if text.contains(q) { return 1000 - text.count + (text.hasPrefix(q) ? 500 : 0) }
        var score = 0, ti = text.startIndex, prevMatched = false
        for qc in q {
            guard let found = text[ti...].firstIndex(of: qc) else { return nil }
            score += found == ti && prevMatched ? 8 : 1
            if found == text.startIndex || text[text.index(before: found)] == " " { score += 6 }
            prevMatched = true
            ti = text.index(after: found)
        }
        return score
    }

    private func run(_ i: Int) {
        let r = rows
        guard r.indices.contains(i) else { return }
        close()
        r[i].action()
    }

    private func close() { model.showCommandPalette = false; query = "" }
}
