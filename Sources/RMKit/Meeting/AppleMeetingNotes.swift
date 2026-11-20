import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Meeting notes as data. Small on-device models fill a schema far more reliably than they follow
/// formatting instructions, so Apple Intelligence generates this and the app writes the Markdown.
public struct StructuredMeetingNotes: Sendable, Equatable {
    public struct Topic: Sendable, Equatable {
        public var title: String
        public var points: [String]
    }
    public struct ActionItem: Sendable, Equatable {
        public var owner: String
        public var task: String
        public var due: String?
    }

    public var summary: String
    public var topics: [Topic]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]

    /// Markdown in the same shape as the prompt-based providers produce.
    public var markdown: String {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func real(_ s: String) -> Bool { !MeetingNotesGenerator.isPlaceholder(s) }
        var out: [String] = []
        if real(summary) { out += ["## Summary", clean(summary), ""] }
        let topics = self.topics.map { Topic(title: clean($0.title), points: $0.points.map(clean).filter(real)) }.filter { !$0.points.isEmpty }
        if !topics.isEmpty {
            out.append("## Notes")
            for t in topics {
                if real(t.title) { out.append("### \(t.title)") }
                out += t.points.map { "- \($0)" }
                out.append("")
            }
        }
        let decisions = decisions.map(clean).filter(real)
        if !decisions.isEmpty { out += ["## Decisions"] + decisions.map { "- \($0)" } + [""] }
        let actions = actionItems.filter { real($0.task) }
        if !actions.isEmpty {
            out.append("## Action items")
            for a in actions {
                let owner = real(a.owner) ? clean(a.owner) : "Someone"
                let task = clean(a.task)
                // Skip the due date when the task already says it ("…by Friday").
                let due = a.due.map(clean).flatMap { real($0) && !task.localizedCaseInsensitiveContains($0) ? " (\($0))" : nil } ?? ""
                out.append("- [ ] \(owner): \(task)\(due)")
            }
            out.append("")
        }
        let questions = openQuestions.map(clean).filter(real)
        if !questions.isEmpty { out += ["## Open questions"] + questions.map { "- \($0)" } }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum AppleMeetingNotes {
    static func schema() throws -> GenerationSchema {
        let text = DynamicGenerationSchema(type: String.self)
        let topic = DynamicGenerationSchema(name: "Topic", properties: [
            .init(name: "title", description: "Short heading for one topic that was discussed", schema: text),
            .init(name: "points", description: "Bullet points with the concrete facts, numbers, dates, names and who said what",
                  schema: DynamicGenerationSchema(arrayOf: text, minimumElements: 1)),
        ])
        let action = DynamicGenerationSchema(name: "ActionItem", properties: [
            .init(name: "owner", description: "Who will do it: \"Me\", \"Them\", or a name from the transcript", schema: text),
            .init(name: "task", description: "What they said they would do", schema: text),
            .init(name: "due", description: "The day or date this person said it is due. Leave out if no date was said for this task.", schema: text, isOptional: true),
        ])
        let root = DynamicGenerationSchema(name: "MeetingNotes", properties: [
            .init(name: "topics", description: "The topics discussed, using my own note headings where they fit",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Topic"), minimumElements: 1)),
            .init(name: "decisions", description: "Everything that was agreed or decided, such as \"we decided to…\". Empty if nothing was decided.",
                  schema: DynamicGenerationSchema(arrayOf: text)),
            .init(name: "actionItems", description: "Every commitment to do something, such as \"I'll send…\" or \"can you…\". Empty if none.",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "ActionItem"))),
            .init(name: "openQuestions", description: "Questions that were asked but not answered. Empty if none.",
                  schema: DynamicGenerationSchema(arrayOf: text)),
            .init(name: "summary", description: "Two or three sentences on the outcome of the meeting", schema: text),
        ])
        return try GenerationSchema(root: root, dependencies: [topic, action])
    }

    static func generate(prompt: String, system: String) async throws -> StructuredMeetingNotes {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw RMError.auth("Apple Intelligence isn't available: turn it on in System Settings › Apple Intelligence & Siri.")
        }
        let session = LanguageModelSession(model: model, instructions: system)
        let content = try await session.respond(to: prompt, schema: try schema(),
                                                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 1_100)).content
        let topics: [GeneratedContent] = (try? content.value([GeneratedContent].self, forProperty: "topics")) ?? []
        let actions: [GeneratedContent] = (try? content.value([GeneratedContent].self, forProperty: "actionItems")) ?? []
        return StructuredMeetingNotes(
            summary: (try? content.value(String.self, forProperty: "summary")) ?? "",
            topics: topics.map {
                .init(title: (try? $0.value(String.self, forProperty: "title")) ?? "",
                      points: (try? $0.value([String].self, forProperty: "points")) ?? [])
            },
            decisions: (try? content.value([String].self, forProperty: "decisions")) ?? [],
            actionItems: actions.map {
                .init(owner: (try? $0.value(String.self, forProperty: "owner")) ?? "",
                      task: (try? $0.value(String.self, forProperty: "task")) ?? "",
                      due: try? $0.value(String?.self, forProperty: "due"))
            },
            openQuestions: (try? content.value([String].self, forProperty: "openQuestions")) ?? []
        )
    }
}
#endif
