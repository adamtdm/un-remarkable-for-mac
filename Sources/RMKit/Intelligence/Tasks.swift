import CryptoKit
import Foundation

/// A to-do found in a notebook, captured on the Mac, or taken from meeting notes.
public struct TaskItem: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case typed, handwriting, captured, meeting
    }

    public var id: String
    /// Identity across scans: the same text on the same page is the same task.
    public var fingerprint: String
    public var text: String
    public var source: Source
    public var docID: String
    public var docName: String
    public var pageIndex: Int
    public var createdAt: Date
    public var completedAt: Date?

    public var isDone: Bool { completedAt != nil }

    public init(text: String, source: Source, docID: String = "", docName: String = "", pageIndex: Int = 0,
                done: Bool = false, now: Date = .now) {
        let clean = TaskExtractor.clean(text)
        self.id = UUID().uuidString.lowercased()
        self.fingerprint = Self.fingerprint(source: source, docID: docID, page: pageIndex, text: clean)
        self.text = clean
        self.source = source
        self.docID = docID
        self.docName = docName
        self.pageIndex = pageIndex
        self.createdAt = now
        self.completedAt = done ? now : nil
    }

    static func fingerprint(source: Source, docID: String, page: Int, text: String) -> String {
        let scope = source == .captured ? "captured" : "\(docID):\(page)"
        let digest = SHA256.hash(data: Data("\(scope):\(text.lowercased())".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Rule-based task extraction from typed text, ported from the web app's `extract_tasks_from_text`.
///
/// A task starts with `*`, `- [ ]`/`[ ]` (done: `[x]`), or `TODO:`/`FIXME:`. An asterisk task runs to
/// the next `*`, a sentence-ending full stop, or the end of the line.
public enum TaskExtractor {
    public struct Found: Equatable, Sendable {
        public var text: String
        public var done: Bool
    }

    /// - Parameter bulletAware: for typed pages, treat `*` used as list bullets as bullets: indented `* ` lines,
    ///   and every `*` on a page with more than eight of them (pasted Markdown). Checkboxes and TODO always count.
    public static func extract(from text: String, bulletAware: Bool = false) -> [Found] {
        var out: [Found] = []
        let lines = text.components(separatedBy: .newlines)
        let starLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("*") }.count
        let starsAreBullets = bulletAware && starLines > 8
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let starLine = line.hasPrefix("*") || line.hasPrefix("- *")
            if bulletAware, starLine, starsAreBullets || raw.first?.isWhitespace == true { continue }
            if bulletAware, !starLine, starsAreBullets, line.contains("*"),
               line.firstMatch(of: /^(?:-\s*)?\[/) == nil, !line.uppercased().hasPrefix("TODO"), !line.uppercased().hasPrefix("FIXME") { continue }
            if let m = line.firstMatch(of: /^(?:-\s*)?\*\s*(.+)$/) {
                var content = String(m.1).trimmingCharacters(in: .whitespaces)
                if let star = content.firstIndex(of: "*") { content = String(content[..<star]).trimmingCharacters(in: .whitespaces) }
                let t = untilSentenceEnd(content)
                if !t.isEmpty { out.append(Found(text: t, done: false)) }
            } else if let m = line.firstMatch(of: /^(?:-\s*)?\[\s*\]\s+(.+)$/) {
                out.append(Found(text: String(m.1).trimmingCharacters(in: .whitespaces), done: false))
            } else if let m = line.firstMatch(of: /^(?:-\s*)?\[[xX]\]\s+(.+)$/) {
                out.append(Found(text: String(m.1).trimmingCharacters(in: .whitespaces), done: true))
            } else if let m = line.firstMatch(of: /^(?i:TODO|FIXME)\s*:?\s*(.+)$/) {
                out.append(Found(text: String(m.1).trimmingCharacters(in: .whitespaces), done: false))
            } else if line.contains("*") {
                // Asterisks inside a line: each one starts a task.
                for seg in line.split(separator: "*", omittingEmptySubsequences: false).dropFirst() {
                    var t = untilSentenceEnd(String(seg).trimmingCharacters(in: .whitespaces))
                    t = t.replacing(/^[-•]\s*/, with: "").trimmingCharacters(in: .whitespaces)
                    if t.count > 2, !out.contains(where: { $0.text.lowercased() == t.lowercased() }) {
                        out.append(Found(text: t, done: false))
                    }
                }
            }
        }
        return out.filter { !clean($0.text).isEmpty }
    }

    /// Text up to and including the first sentence-ending full stop (not one after a single letter, as in "e.g.").
    static func untilSentenceEnd(_ s: String) -> String {
        let chars = Array(s)
        for (i, c) in chars.enumerated() where c == "." {
            let atEnd = i + 1 == chars.count || chars[i + 1].isWhitespace
            guard atEnd else { continue }
            // Skip abbreviations like "e.g." or "A. Smith": a single letter word right before the stop.
            let singleLetter = i >= 1 && chars[i - 1].isLetter && (i == 1 || !chars[i - 2].isLetter)
            if singleLetter { continue }
            return String(chars[0...i])
        }
        return s
    }

    public static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// A notebook page's typed text in the form the rules expect: native checkbox paragraphs become `[ ]`/`[x]`.
    public static func text(of page: RmPage) -> String {
        page.paragraphs.map { p in
            switch p.style {
            case .checkbox: return "[ ] \(p.text)"
            case .checkboxChecked: return "[x] \(p.text)"
            default: return p.text
            }
        }.joined(separator: "\n")
    }

    /// Prompt for finding handwritten `*` tasks on a page image (same rules as the web app).
    public static let visionPrompt = """
    Analyze this handwritten notebook page and extract every task marked with an asterisk (*) written before it. \
    Ignore everything else, including plain bullet points and checkboxes.

    Rules:
    - A task starting with * runs until the next *, a sentence-ending period, or a line/paragraph break.
    - Status is "completed" only if the task is crossed out or struck through, otherwise "open".
    - Return strictly valid JSON array without Markdown code blocks:
    [{"text": "task text", "status": "open"|"completed"}]
    If no tasks are present on this page, return []
    """

    public static func parseVision(_ reply: String) -> [Found] {
        let json = reply.replacing(/^```(?:json)?\s*|\s*```$/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = json.firstIndex(of: "["), let end = json.lastIndex(of: "]"),
              let arr = try? JSONSerialization.jsonObject(with: Data(json[start...end].utf8)) as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let t = item["text"] as? String, !clean(t).isEmpty else { return nil }
            return Found(text: t, done: (item["status"] as? String) == "completed")
        }
    }

    /// Action items from AI meeting notes: `- [ ] Owner: task (due)` lines under "Action items".
    /// Only your own ("Me") items become tasks.
    public static func meetingActions(_ markdown: String) -> [Found] {
        var inActions = false
        var out: [Found] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { inActions = line.lowercased().contains("action"); continue }
            guard inActions, let m = line.firstMatch(of: /^[-*]\s*\[( |x|X)\]\s*(.+)$/) else { continue }
            var item = String(m.2)
            if let colon = item.firstIndex(of: ":") {
                let owner = item[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard owner == "me" || owner == "i" else { continue }
                item = String(item[item.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            out.append(Found(text: item, done: m.1 != " "))
        }
        return out
    }
}

// MARK: - Tasks notebook

public enum TasksNotebook {
    /// Typed lines per page, leaving room for long tasks to wrap (as in the web app).
    public static let linesPerPage = 18

    /// Lays out open tasks as typed pages, grouped by where each came from. A group running past the end
    /// of a page continues on the next under a repeated heading.
    public static func pages(title: String, tasks: [TaskItem]) -> [[RmWriter.Paragraph]] {
        let open = tasks.filter { !$0.isDone }.sorted {
            ($0.docName.isEmpty ? 0 : 1, $0.docName.lowercased(), $0.createdAt) < ($1.docName.isEmpty ? 0 : 1, $1.docName.lowercased(), $1.createdAt)
        }
        var pages: [[RmWriter.Paragraph]] = [[]]
        var lastSource: String?
        for t in open {
            let source = t.docName.isEmpty ? "Captured" : t.docName
            var newGroup = source != lastSource || pages[pages.count - 1].isEmpty
            let needed = 1 + (newGroup ? 1 : 0) + (newGroup && !pages[pages.count - 1].isEmpty ? 1 : 0)
            if !pages[pages.count - 1].isEmpty, pages[pages.count - 1].count + needed > linesPerPage {
                pages.append([])
                newGroup = true
            }
            if newGroup {
                if !pages[pages.count - 1].isEmpty { pages[pages.count - 1].append(.init("")) }
                pages[pages.count - 1].append(.init(source, style: .bold))
            }
            pages[pages.count - 1].append(.init(t.text, style: .checkbox))
            lastSource = source
        }
        if open.isEmpty { pages[0].append(.init("No open tasks.")) }
        return pages.enumerated().map { i, lines in
            [.init("\(title) · \(open.count) open · page \(i + 1)/\(pages.count)", style: .heading)] + lines
        }
    }

    /// Task texts ticked off in the Tasks notebook on the tablet (checked checkbox paragraphs).
    public static func ticked(in pages: [RmPage]) -> Set<String> {
        Set(pages.flatMap { $0.paragraphs }.filter { $0.style == .checkboxChecked }.map { TaskExtractor.clean($0.text).lowercased() })
    }
}
