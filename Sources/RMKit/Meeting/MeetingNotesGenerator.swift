import Foundation

extension AISettings {
    /// The settings saved by Settings › AI (stored as JSON under `aiSettings`).
    public static var current: AISettings {
        guard let s = UserDefaults.standard.string(forKey: "aiSettings"), let d = s.data(using: .utf8),
              let v = try? JSONDecoder().decode(AISettings.self, from: d) else { return AISettings() }
        return v
    }
}

/// Writes meeting notes from your typed notes, the transcript and your tablet handwriting.
///
/// Like Granola, your own notes are the outline: the AI keeps your structure and wording, then fills
/// in the detail from the transcript, and adds decisions and action items.
public struct MeetingNotesGenerator: Sendable {
    public let provider: AIProvider

    public init(provider: AIProvider) { self.provider = provider }

    static let system = """
    You are an expert meeting note-taker. You write concise, accurate notes in Markdown for the person \
    who attended the meeting ("Me" in the transcript). Never invent facts, names, numbers or dates that \
    are not in the inputs. Write in British English.
    """

    /// Progress messages for the UI.
    public typealias Progress = @Sendable (String) -> Void

    /// - Parameters:
    ///   - handwriting: page images for providers that read images.
    ///   - handwritingText: the tablet pages converted to text, for providers that don't (Apple Intelligence).
    public func generate(_ meeting: Meeting, handwriting: [Data] = [], handwritingText: String = "", progress: Progress = { _ in }) async throws -> String {
        var transcript = meeting.transcriptText
        var notes = meeting.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = handwritingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !written.isEmpty {
            let cap = provider.settings.provider == .apple ? 1_500 : 6_000
            notes += (notes.isEmpty ? "" : "\n\n") + "Handwritten on my reMarkable during the meeting:\n" + String(written.prefix(cap))
        }
        guard !transcript.isEmpty || !notes.isEmpty || !handwriting.isEmpty else {
            throw RMError.malformed("There's nothing to write notes from yet: no transcript, typed notes or handwriting.")
        }
        let images = provider.settings.provider.supportsImages ? Array(handwriting.prefix(6)) : []

        // Long meetings: condense the transcript in chunks so it fits the model's window.
        let budget = provider.settings.provider.promptBudget
        let reserved = notes.count + 3_000
        if transcript.count > budget - reserved {
            let chunks = Self.chunk(transcript, size: max(2_000, (budget - reserved) / 2))
            var condensed: [String] = []
            for (i, c) in chunks.enumerated() {
                progress("Reading the transcript (\(i + 1) of \(chunks.count))…")
                condensed.append(try await provider.complete(prompt: Self.chunkPrompt(c, brief: provider.settings.provider == .apple),
                                                             system: Self.system, images: [], timeout: 180))
            }
            transcript = condensed.joined(separator: "\n\n")
            if transcript.count > budget - reserved { transcript = String(transcript.prefix(budget - reserved)) }
        }

        progress("Writing notes…")
        #if canImport(FoundationModels)
        if provider.settings.provider == .apple, #available(macOS 26.0, *) {
            let structured = try await AppleMeetingNotes.generate(
                prompt: Self.structuredPrompt(meeting: meeting, notes: notes, transcript: transcript), system: Self.system)
            let md = structured.markdown
            guard !md.isEmpty else { throw RMError.malformed("Apple Intelligence returned empty notes. Try again or use another provider.") }
            return md
        }
        #endif
        let prompt = Self.prompt(meeting: meeting, notes: notes, transcript: transcript, handwritingPages: images.count)
        let out = try await provider.complete(prompt: prompt, system: Self.system, images: images, timeout: 240)
        return Self.cleanup(out)
    }

    static func prompt(meeting: Meeting, notes: String, transcript: String, handwritingPages: Int) -> String {
        var p = """
        Meeting: \(meeting.displayTitle)
        Date: \(meeting.startedAt.formatted(date: .complete, time: .shortened))
        Duration: \(Meeting.timestamp(meeting.duration))
        \(meeting.attendees.isEmpty ? "" : "Attendees: " + meeting.attendees.joined(separator: ", ") + "\n")
        """
        if !notes.isEmpty {
            p += """

            ## My notes (typed during the meeting)
            \(notes)

            """
        }
        if handwritingPages > 0 {
            p += "\nThe \(handwritingPages) attached image(s) are my handwritten notes from my reMarkable tablet during the meeting. Read them carefully and include what they say.\n"
        }
        if !transcript.isEmpty {
            p += """

            ## Transcript ("Me" is me, "Them" is everyone else on the call; speech recognition may contain errors)
            \(transcript)

            """
        }
        p += """

        Write the meeting notes in Markdown with exactly these sections, leaving out any that would be empty:

        ## Summary
        Two or three sentences.

        ## Notes
        Use my notes as the outline: keep my headings, order and wording, and expand each point with the \
        relevant detail from the transcript and handwriting. Add short sub-headings (###) for other topics \
        that were discussed. Use bullet points.

        ## Decisions
        Bullet points.

        ## Action items
        One per line as "- [ ] Owner: task (due date if mentioned)". Use "Me" for things I agreed to do.

        ## Open questions
        Bullet points.

        Output only the Markdown, starting with "## Summary".
        """
        return p
    }

    /// Prompt for schema-guided generation: just the inputs and what matters, no formatting rules.
    static func structuredPrompt(meeting: Meeting, notes: String, transcript: String) -> String {
        var p = "Write notes for this meeting: \(meeting.displayTitle), \(Meeting.timestamp(meeting.duration)) long.\n"
        if !notes.isEmpty { p += "\nMy notes, typed during the meeting (use them as topic headings):\n\(notes)\n" }
        if !transcript.isEmpty { p += "\nTranscript (\"Me\" is me, \"Them\" is the other people):\n\(transcript)\n" }
        p += "\nInclude every decision, every commitment someone made (with who and when), and every unanswered question. Only use facts from the notes and transcript."
        return p
    }

    static func chunkPrompt(_ chunk: String, brief: Bool = false) -> String {
        """
        This is part of a meeting transcript ("Me" is me, "Them" is everyone else). Condense it into \
        \(brief ? "at most 8 short" : "detailed") bullet points that keep every fact, number, name, decision, \
        commitment and question. Merge repeated points. Keep who said what where it matters. Output only the bullet points.

        \(chunk)
        """
    }

    /// Splits on line boundaries into pieces of about `size` characters.
    static func chunk(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Removes `##` sections that have no content (small models often leave the heading behind).
    /// True for lines with no real content: blank, bullets alone, invisible characters, or "None"-style fillers.
    static func isPlaceholder(_ line: String) -> Bool {
        var t = line.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "/" }
            .trimmingCharacters(in: .whitespaces)
        if let colon = line.range(of: ":"), t.hasPrefix("me ") || t.hasPrefix("them ") {
            t = String(line[colon.upperBound...]).lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "/" }
                .trimmingCharacters(in: .whitespaces)
        }
        return t.isEmpty || ["none", "n/a", "na", "nothing", "none mentioned", "not mentioned", "none noted", "no decisions", "no action items", "no open questions",
                                "not specified", "unspecified", "unknown", "no date", "no due date", "not given"].contains(t)
    }

    static func dropEmptySections(_ text: String) -> String {
        var out: [String] = []
        var pending: [String] = []
        var hasContent = false
        func flush() {
            if hasContent { out += pending }
            pending = []
            hasContent = false
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { flush() }
            pending.append(line)
            if !line.hasPrefix("## "), !isPlaceholder(line) { hasContent = true }
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// Strips code fences and any chatter before the first heading.
    static func cleanup(_ text: String) -> String {
        var t = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
        if let r = t.range(of: "## ") { t = String(t[r.lowerBound...]) }
        t = dropEmptySections(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
