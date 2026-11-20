import Foundation

/// Who said a transcript segment. The microphone is you; system audio (Zoom, Meet, Teams…) is everyone else.
public enum Speaker: String, Codable, Sendable, CaseIterable {
    case me, them

    public var label: String { self == .me ? "Me" : "Them" }
}

public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var speaker: Speaker
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// For "Them": which voice (1, 2…) after voice separation; nil when not separated.
    public var voice: Int?

    public init(speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A recorded meeting: your typed notes, the live transcript, optional tablet notebook, and AI notes.
public struct Meeting: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval = 0
    /// Notes you typed during the meeting (Markdown-ish plain text).
    public var myNotes: String = ""
    public var transcript: [TranscriptSegment] = []
    /// AI-written notes in Markdown, generated after the meeting.
    public var aiNotes: String = ""
    /// Tablet notebook whose handwriting is merged into the AI notes.
    public var linkedDocumentID: String?
    /// Audio files inside the meeting folder, per speaker.
    public var audioFiles: [String: String] = [:]
    /// Cloud document ID once the notes have been sent to the tablet.
    public var sentDocumentID: String?
    public var sentAt: Date?
    /// Calendar event this meeting was started from, and its attendees.
    public var calendarEventID: String?
    public var attendees: [String] = []
    /// Pages added to the linked notebook by "Send to Tablet" (replaced when sent again).
    public var appendedPageIDs: [String] = []
    /// Names given to separated voices ("1" → "Priya"). Two voices with one name read as one person.
    public var voiceNames: [String: String] = [:]
    /// Meeting time of each audio file's first sample (recordings resumed later start part-way in).
    public var audioOffsets: [String: TimeInterval] = [:]

    enum CodingKeys: String, CodingKey {
        case id, title, startedAt, duration, myNotes, transcript, aiNotes, linkedDocumentID, audioFiles, sentDocumentID, sentAt
        case calendarEventID, attendees, appendedPageIDs, voiceNames, audioOffsets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        myNotes = try c.decodeIfPresent(String.self, forKey: .myNotes) ?? ""
        transcript = try c.decodeIfPresent([TranscriptSegment].self, forKey: .transcript) ?? []
        aiNotes = try c.decodeIfPresent(String.self, forKey: .aiNotes) ?? ""
        linkedDocumentID = try c.decodeIfPresent(String.self, forKey: .linkedDocumentID)
        audioFiles = try c.decodeIfPresent([String: String].self, forKey: .audioFiles) ?? [:]
        sentDocumentID = try c.decodeIfPresent(String.self, forKey: .sentDocumentID)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        appendedPageIDs = try c.decodeIfPresent([String].self, forKey: .appendedPageIDs) ?? []
        voiceNames = try c.decodeIfPresent([String: String].self, forKey: .voiceNames) ?? [:]
        audioOffsets = try c.decodeIfPresent([String: TimeInterval].self, forKey: .audioOffsets) ?? [:]
    }

    /// Who said a segment: "Me", "Them", or a separated voice ("Them 2", or the name given to it).
    public func label(for s: TranscriptSegment) -> String {
        Self.label(for: s, names: voiceNames)
    }

    static func label(for s: TranscriptSegment, names: [String: String]) -> String {
        guard s.speaker == .them, let v = s.voice else { return s.speaker.label }
        let name = names[String(v)]?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Them \(v)" : name
    }

    /// Separated voices heard in the meeting, in order.
    public var voices: [Int] { Array(Set(transcript.compactMap(\.voice))).sorted() }

    /// Splits "Them" into voices using the recorded system audio. Returns how many voices were found.
    @discardableResult
    public mutating func separateVoices(folder: URL) -> Int {
        let tracks = audioFiles.filter { $0.value == Speaker.them.rawValue }.keys.sorted().map { file in
            VoiceSeparation.AudioTrack(url: folder.appending(path: file), offset: audioOffsets[file] ?? 0)
        }
        let result = VoiceSeparation.separate(transcript, tracks: tracks)
        for i in transcript.indices { transcript[i].voice = transcript[i].speaker == .them ? result.voices[transcript[i].id] : nil }
        return result.voices.isEmpty ? min(result.count, 1) : result.count
    }

    /// Back to a single "Them".
    public mutating func clearVoices() {
        for i in transcript.indices { transcript[i].voice = nil }
        voiceNames = [:]
    }

    /// Notes for pages added after the meeting page's own content: AI notes (or typed notes) and, optionally, the transcript.
    public func appendedPagesMarkdown(includeTranscript: Bool, transcriptLinesPerPage: Int = 30) -> String {
        var md = "# Meeting notes\n"
        var meta = "Recorded on Mac · " + startedAt.formatted(date: .abbreviated, time: .shortened)
        if duration > 0 { meta += " · \(Self.timestamp(duration))" }
        md += meta + "\n\n"
        if !aiNotes.isEmpty { md += aiNotes + "\n" } else if !myNotes.isEmpty { md += "## My notes\n" + myNotes + "\n" }
        if includeTranscript {
            let lines = transcriptText.components(separatedBy: "\n").filter { !$0.isEmpty }
            for start in stride(from: 0, to: lines.count, by: max(transcriptLinesPerPage, 1)) {
                md += "\n---\n## Transcript\n" + lines[start..<min(start + transcriptLinesPerPage, lines.count)].joined(separator: "\n") + "\n"
            }
        }
        return md
    }

    public init(id: String = UUID().uuidString.lowercased(), title: String = "", startedAt: Date = .now) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
    }

    /// Adds a final transcript segment, dropping speaker echo: on speakers the microphone also picks up
    /// the other people, so the same words arrive once as "Them" and again as "Me". The "Them" copy (the
    /// clean digital signal) is kept. Returns false when the segment was dropped as an echo.
    @discardableResult
    public mutating func appendSegment(_ segment: TranscriptSegment) -> Bool {
        let recent = transcript.indices.reversed().prefix(12)
        if segment.speaker == .me, recent.contains(where: { Self.isEcho(segment, of: transcript[$0]) }) {
            return false
        }
        if segment.speaker == .them {
            transcript.removeAll { $0.speaker == .me && Self.isEcho($0, of: segment) }
        }
        transcript.append(segment)
        return true
    }

    /// True when `mine` is the microphone hearing `theirs` through the speakers: close in time, nearly the same words.
    public static func isEcho(_ mine: TranscriptSegment, of theirs: TranscriptSegment) -> Bool {
        guard mine.speaker == .me, theirs.speaker == .them, abs(mine.start - theirs.start) < 5 else { return false }
        let a = words(mine.text), b = words(theirs.text)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let overlap = Double(a.intersection(b).count)
        // Mostly contained in what they said (the mic may catch only part of it), or near-identical overall.
        return overlap / Double(a.count) >= 0.7 || overlap / Double(a.union(b).count) >= 0.6
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The meeting as Markdown for a typed notebook: notes on the first page(s), then the transcript on
    /// new pages of `transcriptLinesPerPage` lines.
    public func tabletMarkdown(transcriptLinesPerPage: Int = 30) -> String {
        var md = "# \(displayTitle)\n"
        var meta = startedAt.formatted(date: .complete, time: .shortened)
        if duration > 0 { meta += " · \(Self.timestamp(duration))" }
        md += meta + "\n\n"
        if !aiNotes.isEmpty {
            md += aiNotes + "\n"
        } else if !myNotes.isEmpty {
            md += "## My notes\n" + myNotes + "\n"
        }
        md += "\n## Handwritten notes\n"
        let lines = transcriptText.components(separatedBy: "\n").filter { !$0.isEmpty }
        for start in stride(from: 0, to: lines.count, by: max(transcriptLinesPerPage, 1)) {
            md += "\n---\n## Transcript\n"
            md += lines[start..<min(start + transcriptLinesPerPage, lines.count)].joined(separator: "\n") + "\n"
        }
        return md
    }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Meeting \(startedAt.formatted(date: .abbreviated, time: .shortened))" : t
    }

    /// Transcript as plain text, one line per segment: `[mm:ss] Me: …`. Consecutive segments from the
    /// same speaker are merged so the AI (and you) read turns rather than fragments.
    public var transcriptText: String {
        Self.formatTranscript(transcript, names: voiceNames)
    }

    public static func formatTranscript(_ segments: [TranscriptSegment], names: [String: String] = [:]) -> String {
        var lines: [String] = []
        var current: TranscriptSegment?
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var c = current, label(for: c, names: names) == label(for: s, names: names), s.start - c.end < 4 {
                c.text += " " + text
                c.end = max(c.end, s.end)
                current = c
            } else {
                if let c = current { lines.append(line(c, names)) }
                var n = s
                n.text = text
                current = n
            }
        }
        if let c = current { lines.append(line(c, names)) }
        return lines.joined(separator: "\n")
    }

    private static func line(_ s: TranscriptSegment, _ names: [String: String]) -> String {
        "[\(timestamp(s.start))] \(label(for: s, names: names)): \(s.text)"
    }

    public static func timestamp(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Meetings on disk: `<root>/<id>/meeting.json` plus audio files in the same folder.
public final class MeetingStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func folder(for id: String) -> URL {
        let url = root.appending(path: id, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func save(_ meeting: Meeting) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .deferredToDate
        let data = try enc.encode(meeting)
        try lock.withLock { try data.write(to: folder(for: meeting.id).appending(path: "meeting.json"), options: .atomic) }
    }

    public func load(_ id: String) -> Meeting? {
        let url = root.appending(path: id).appending(path: "meeting.json")
        guard let data = lock.withLock({ try? Data(contentsOf: url) }) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .deferredToDate
        return try? dec.decode(Meeting.self, from: data)
    }

    /// All meetings, newest first.
    public func all() -> [Meeting] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap(load).sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: String) throws {
        try lock.withLock { try FileManager.default.removeItem(at: root.appending(path: id)) }
    }
}
