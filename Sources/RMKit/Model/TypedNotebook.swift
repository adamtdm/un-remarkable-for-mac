import Foundation

/// Builds the files of a native typed-text notebook (`.rm` pages, `.content`, `.metadata`, `.pagedata`),
/// like the web app's `NotebookEditor.create_notebook`.
public enum TypedNotebook {
    public struct File: Sendable, Equatable {
        public var name: String
        public var data: Data
    }

    /// Files for a notebook with the given pages. Pass an existing `docID` to rebuild it in place.
    public static func files(docID: String, title: String, parentID: String = "",
                             pages: [[RmWriter.Paragraph]], now: Date = .now) -> [File] {
        let pages = pages.isEmpty ? [[RmWriter.Paragraph("")]] : pages
        let pageIDs = pages.map { _ in UUID().uuidString.lowercased() }
        var files: [File] = []
        var total = 0
        for (id, paragraphs) in zip(pageIDs, pages) {
            let rm = RmWriter.page(paragraphs: paragraphs)
            total += rm.count
            files.append(File(name: "\(docID)/\(id).rm", data: rm))
        }
        files.append(File(name: "\(docID).pagedata", data: Data((pageIDs.map { _ in "P Blank" }.joined(separator: "\n") + "\n").utf8)))
        files.append(File(name: "\(docID).content", data: content(pageIDs: pageIDs, size: total)))
        files.append(File(name: "\(docID).metadata", data: metadata(title: title, parentID: parentID, now: now)))
        return files
    }

    static func content(pageIDs: [String], size: Int) -> Data {
        let pages: [[String: Any]] = pageIDs.enumerated().map { i, id in
            [
                "id": id,
                "idx": ["timestamp": "1:\(i + 1)", "value": pageOrderKey(i)],
                "template": ["timestamp": "1:1", "value": "P Blank"],
            ]
        }
        // Same fields as the web app's notebooks, which the tablet accepts.
        let obj: [String: Any] = [
            "cPages": [
                "lastOpened": ["timestamp": "1:1", "value": pageIDs.first ?? ""],
                "original": ["timestamp": "0:0", "value": -1],
                "pages": pages,
            ],
            "crdt": true,
            "dummyDocument": false,
            "extraMetadata": [String: Any](),
            "fileType": "notebook",
            "fontName": "",
            "formatVersion": 2,
            "lineHeight": -1,
            "margins": 125,
            "orientation": "portrait",
            "originalPageCount": -1,
            "pageCount": pageIDs.count,
            "pages": pageIDs,
            "pageTags": [Any](),
            "sizeInBytes": String(size),
            "textAlignment": "left",
            "textScale": 1,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func metadata(title: String, parentID: String, now: Date) -> Data {
        let ms = String(Int64(now.timeIntervalSince1970 * 1000))
        let obj: [String: Any] = [
            "createdTime": ms, "lastModified": ms, "lastOpened": ms, "lastOpenedPage": 0,
            "new": false, "parent": parentID, "pinned": false, "source": "",
            "type": "DocumentType", "visibleName": title,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Page position for `.content` cPages. The tablet sorts these as text, so they're fixed width ("baaa", "baab", …).
    public static func pageOrderKey(_ index: Int) -> String {
        var idx = index
        var letters = ""
        for _ in 0..<3 {
            letters = String(UnicodeScalar(UInt8(97 + idx % 26))) + letters
            idx /= 26
        }
        return "b" + letters
    }

    // MARK: Adding pages to an existing notebook

    /// Adds pages to the end of a notebook's `.content` page list (and removes earlier added pages by
    /// marking them deleted, as the tablet does). Returns the updated `.content`.
    public static func appendingPages(to content: Data, newPageIDs: [String], removing: [String] = []) throws -> Data {
        guard var obj = jsonObject(content), var cPages = obj["cPages"] as? [String: Any] else {
            throw RMError.malformed("Notebook has no page list")
        }
        var pages = cPages["pages"] as? [[String: Any]] ?? []
        // Next LWW timestamp: after every counter already used.
        var counter = 0
        func scan(_ v: Any) {
            if let d = v as? [String: Any] {
                if let ts = d["timestamp"] as? String, let n = Int(ts.split(separator: ":").last ?? "") { counter = max(counter, n) }
                d.values.forEach(scan)
            } else if let a = v as? [Any] { a.forEach(scan) }
        }
        scan(cPages)
        func next() -> String { counter += 1; return "1:\(counter)" }

        let drop = Set(removing)
        for i in pages.indices where drop.contains(pages[i]["id"] as? String ?? "") {
            pages[i]["deleted"] = ["timestamp": next(), "value": 1]
        }
        let live = pages.filter { (($0["deleted"] as? [String: Any])?["value"] as? Int ?? 0) == 0 }
        let maxKey = live.compactMap { ($0["idx"] as? [String: Any])?["value"] as? String }.max() ?? "b"
        for (i, id) in newPageIDs.enumerated() {
            // Sorts after maxKey ("ba" < "ba" + "na" < "ba" + "nb" …).
            let suffix = String(UnicodeScalar(UInt8(110 + i / 26))) + String(UnicodeScalar(UInt8(97 + i % 26)))
            pages.append(["id": id, "idx": ["timestamp": next(), "value": maxKey + suffix],
                          "template": ["timestamp": next(), "value": "Blank"]])
        }
        cPages["pages"] = pages
        obj["cPages"] = cPages
        obj["pageCount"] = live.count + newPageIDs.count
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Markdown

    /// Converts Markdown to typed pages. `---` on its own line starts a new page.
    ///
    /// `#` heading, `##`/`###` or a whole-line `**bold**` → bold, `- [ ]`/`- [x]` checkboxes, `-`/`*` bullets
    /// (indented → second level), `1.` lists and plain text. Inline Markdown markers are removed.
    public static func pages(fromMarkdown markdown: String) -> [[RmWriter.Paragraph]] {
        var pages: [[RmWriter.Paragraph]] = [[]]
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "***" {
                if !pages[pages.count - 1].isEmpty { pages.append([]) }
                continue
            }
            pages[pages.count - 1].append(paragraph(line, indent: indent))
        }
        // Trim blank lines at the ends of pages and drop empty pages.
        return pages.map { p in
            var p = p
            while p.first?.text.isEmpty == true { p.removeFirst() }
            while p.last?.text.isEmpty == true { p.removeLast() }
            return p
        }.filter { !$0.isEmpty }
    }

    static func paragraph(_ line: String, indent: Int) -> RmWriter.Paragraph {
        if line.hasPrefix("#") {
            let level = line.prefix { $0 == "#" }.count
            let text = inline(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces))
            return .init(text, style: level == 1 ? .heading : .bold)
        }
        if let m = line.firstMatch(of: /^(?:[-*+]\s+)?\[( |x|X)\]\s*(.*)$/) {
            return .init(inline(String(m.2)), style: m.1 == " " ? .checkbox : .checkboxChecked)
        }
        if let m = line.firstMatch(of: /^[-*+•]\s+(.*)$/) {
            return .init(inline(String(m.1)), style: indent >= 2 ? .bullet2 : .bullet)
        }
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4, !line.dropFirst(2).dropLast(2).contains("**") {
            return .init(String(line.dropFirst(2).dropLast(2)), style: .bold)
        }
        return .init(inline(line), style: .plain)
    }

    /// Strips inline emphasis and code markers; turns links into their text.
    static func inline(_ s: String) -> String {
        var t = s.replacing(/\[([^\]]+)\]\([^)]+\)/) { String($0.1) }
        for marker in ["**", "__", "`"] { t = t.replacingOccurrences(of: marker, with: "") }
        return t
    }

    /// Typed text of a page as Markdown-ish lines, the inverse of `paragraph` (for appending to notes).
    public static func paragraphs(from page: RmPage) -> [RmWriter.Paragraph] {
        page.paragraphs.map { RmWriter.Paragraph($0.text, style: $0.style == .basic ? .plain : $0.style) }
    }

    /// A page's typed text as Markdown that `pages(fromMarkdown:)` reads back to the same styles.
    public static func markdown(from page: RmPage) -> String {
        markdown(paragraphs(from: page))
    }

    public static func markdown(_ paragraphs: [RmWriter.Paragraph]) -> String {
        var lines = paragraphs.map { p -> String in
            switch p.style {
            case .heading: return "# " + p.text
            case .bold: return "## " + p.text
            case .bullet: return "- " + p.text
            case .bullet2: return "  - " + p.text
            case .checkbox: return "- [ ] " + p.text
            case .checkboxChecked: return "- [x] " + p.text
            case .basic, .plain: return p.text
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
