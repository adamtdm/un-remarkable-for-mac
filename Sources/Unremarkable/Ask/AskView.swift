import RMKit
import SwiftUI

/// One question and its answer.
struct AskExchange: Identifiable {
    let id = UUID()
    let question: String
    var answer: NotesQA.Answer?
    var error: String?
}

@MainActor @Observable
final class AskModel {
    static let shared = AskModel()
    var exchanges: [AskExchange] = []
    var busy = false
    @ObservationIgnored private lazy var qa = NotesQA(sync: AppModel.shared.sync)

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        exchanges.append(AskExchange(question: q))
        let index = exchanges.count - 1
        busy = true
        let model = AppModel.shared
        let docs = model.documents
        let excluded = model.excludedIDs
        let provider = AIProvider(settings: AISettings.current)
        Task {
            do {
                exchanges[index].answer = try await qa.answer(q, documents: docs, excluded: excluded, provider: provider)
            } catch {
                exchanges[index].error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct AskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.columnUnit) private var unit
    @State private var ask = AskModel.shared
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "ask") {
                Text(AISettings.current.provider == .apple ? "on this mac, apple intelligence" : AISettings.current.provider.displayName.lowercased())
                    .font(.mono(12.5)).foregroundStyle(Paper.textMuted).lineLimit(1)
                Spacer(minLength: 12)
                if !ask.exchanges.isEmpty {
                    Button("clear") { ask.exchanges.removeAll() }.buttonStyle(MonoButtonStyle()).disabled(ask.busy)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        if ask.exchanges.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("ask your notes").font(.display(40)).tracking(-1.2).foregroundStyle(Paper.text)
                                Text("Answers come from your notebooks and PDFs, with the pages they're from. Excluded folders aren't searched.")
                                    .font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                            }
                            RuledList(title: "try", more: nil) {
                                ForEach(["What did I write about the budget?", "What did we decide in the last planning meeting?", "Which books mention habits?"], id: \.self) { s in
                                    RuledRow(title: s, trailing: "→") { question = s; send() }
                                }
                            }
                        }
                        ForEach(ask.exchanges) { ex in
                            ExchangeCard(exchange: ex).id(ex.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: max(unit * 2, 420) - Columns.gutter * 2, alignment: .leading)
                    .padding(.horizontal, Columns.gutter).padding(.top, 18).padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: ask.exchanges.count) { withAnimation { proxy.scrollTo("end") } }
            }
            HStack(spacing: 12) {
                TextField("Ask a question about your notes", text: $question, prompt: Text("ask a question about your notes…").foregroundStyle(Paper.textMuted))
                    .textFieldStyle(.plain).font(.mono(13.5))
                    .focused($focused)
                    .onSubmit(send)
                if ask.busy { ProgressView().controlSize(.small) }
                Button("ask", action: send).buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || ask.busy)
            }
            .padding(.horizontal, Columns.gutter).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
        }
        .background(Paper.background)
        .navigationTitle("Ask")
        .onAppear { focused = true }
    }

    private func send() {
        ask.ask(question)
        question = ""
    }
}

struct ExchangeCard: View {
    @Environment(AppModel.self) private var model
    let exchange: AskExchange
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(exchange.question).font(.display(26)).tracking(-0.6).foregroundStyle(Paper.text)
            if let error = exchange.error {
                Text(error).font(.mono(12.5)).foregroundStyle(Paper.accent)
            } else if let a = exchange.answer {
                Text(a.text).font(.system(size: 14)).foregroundStyle(Paper.text).textSelection(.enabled)
                    .lineSpacing(4)
                if !a.sources.isEmpty {
                    RuledList(title: "from", more: nil) {
                        ForEach(showAll ? a.considered : a.sources) { p in
                            RuledRow(title: p.docName, trailing: "p. \(p.page + 1)") {
                                UserDefaults.standard.set(p.page, forKey: "reader.openPage.\(p.docID)")
                                model.open(p.docID)
                            }
                            .help(p.text)
                        }
                    }
                    if a.considered.count > a.sources.count {
                        Button(showAll ? "show cited sources" : "show all \(a.considered.count) pages considered") { showAll.toggle() }
                            .buttonStyle(MonoButtonStyle())
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("reading your notes…").font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
