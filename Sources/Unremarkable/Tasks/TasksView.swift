import RMKit
import SwiftUI

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.columnUnit) private var unit
    @Environment(\.mainUnits) private var units
    @State private var tasks = TasksModel.shared
    @State private var newTask = ""
    @State private var showDone = false
    @State private var confirmAll = false
    @FocusState private var adding: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .medium)).foregroundStyle(Paper.textMuted)
                        TextField("Add a task", text: $newTask, prompt: Text("add a task").foregroundStyle(Paper.textMuted))
                            .textFieldStyle(.plain).font(.mono(12.5))
                            .focused($adding)
                            .onSubmit { tasks.add(newTask); newTask = ""; adding = true }
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
                    .frame(maxWidth: unit * 2 - Columns.gutter * 2, alignment: .leading)
                    .padding(.horizontal, Columns.gutter)

                    if tasks.open.isEmpty {
                        Text("No open tasks. Tasks come from lines starting with *, [ ] or TODO: in your notebooks, handwritten * tasks, and your action items in meeting notes.")
                            .font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                            .frame(maxWidth: unit * 2, alignment: .leading)
                            .padding(.horizontal, Columns.gutter)
                    }
                    grid(groups)
                    if showDone, !tasks.done.isEmpty {
                        grid([Group(name: "Done", items: Array(tasks.done.prefix(100)))])
                    }
                }
                .padding(.top, 14).padding(.bottom, 32)
            }
        }
        .navigationTitle("Tasks")
    }

    /// Notebooks' tasks laid across the columns, each a ruled list.
    private func grid(_ groups: [Group]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: max(units, 1)),
                  alignment: .leading, spacing: 26) {
            ForEach(groups, id: \.name) { group in
                RuledList(title: group.name, more: nil) {
                    ForEach(group.items) { row($0) }
                }
                .padding(.horizontal, Columns.gutter)
            }
        }
        .background(alignment: .topLeading) { InnerRules(units: units, unit: unit) }
    }

    private var header: some View {
        ColumnHeader(title: "tasks") {
            Text(tasks.status ?? "\(tasks.open.count) open" + (tasks.notebookEnabled && ServerMode.isOn ? " · in your \(tasks.notebookTitle) notebook" : ""))
                .font(.mono(12.5)).foregroundStyle(Paper.textMuted).lineLimit(1)
            Spacer(minLength: 12)
            Chip(title: "Show done", selected: showDone) { showDone.toggle() }
            if tasks.open.count > 1 {
                Button("complete all") { confirmAll = true }
                    .buttonStyle(MonoButtonStyle())
                    .confirmationDialog("Mark all \(tasks.open.count) open tasks as done?", isPresented: $confirmAll) {
                        Button("Complete All") { tasks.completeAll() }
                    }
            }
            Button(tasks.isRefreshing ? "scanning…" : "scan now") { Task { await tasks.refresh() } }
                .buttonStyle(MonoButtonStyle())
                .disabled(tasks.isRefreshing || !model.isPaired)
                .help("Scan notebooks for tasks and update the Tasks notebook")
            if let id = tasks.notebookID, model.byID[id] != nil {
                Button("open notebook") { model.open(id) }.buttonStyle(MonoButtonStyle())
            }
        }
    }

    private struct Group { let name: String; let items: [TaskItem] }

    private var groups: [Group] {
        let byName = Dictionary(grouping: tasks.open) { $0.docName.isEmpty ? "Captured" : $0.docName }
        return byName.map { Group(name: $0.key, items: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { ($0.name == "Captured" ? 0 : 1, $0.name.lowercased()) < ($1.name == "Captured" ? 0 : 1, $1.name.lowercased()) }
    }

    @ViewBuilder private func row(_ t: TaskItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { tasks.setDone(t, !t.isDone) } label: {
                ZStack {
                    Rectangle().strokeBorder(Paper.textMuted, lineWidth: 1).frame(width: 11, height: 11)
                    if t.isDone { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Paper.text) }
                }
                .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.isDone ? "Mark \(t.text) not done" : "Mark \(t.text) done")
            Text(t.text).strikethrough(t.isDone).foregroundStyle(t.isDone ? Paper.textMuted : Paper.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Image(systemName: icon(t.source)).font(.system(size: 10)).foregroundStyle(Paper.textMuted).help(label(t.source))
                .accessibilityLabel(label(t.source))
        }
        .font(.mono(12.5))
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
        .contentShape(Rectangle())
        .contextMenu {
            Button(t.isDone ? "Mark as Not Done" : "Mark as Done") { tasks.setDone(t, !t.isDone) }
            if !t.docID.isEmpty {
                Button(t.source == .meeting ? "Open Meeting" : "Open Page \(t.pageIndex + 1)") { openSource(t) }
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.text, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { tasks.delete(t) }
        }
        .onTapGesture(count: 2) { openSource(t) }
    }

    private func openSource(_ t: TaskItem) {
        guard !t.docID.isEmpty else { return }
        if t.source == .meeting {
            AppModel.shared.openMeeting(t.docID)
        } else {
            UserDefaults.standard.set(t.pageIndex, forKey: "reader.openPage.\(t.docID)")
            model.open(t.docID)
        }
    }

    private func icon(_ s: TaskItem.Source) -> String {
        switch s {
        case .typed: return "keyboard"
        case .handwriting: return "pencil.and.scribble"
        case .captured: return "plus.bubble"
        case .meeting: return "waveform"
        }
    }

    private func label(_ s: TaskItem.Source) -> String {
        switch s {
        case .typed: return "Typed in a notebook"
        case .handwriting: return "Handwritten"
        case .captured: return "Added on the Mac"
        case .meeting: return "Action item from a meeting"
        }
    }
}
