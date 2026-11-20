import Foundation

public struct PageRef: Codable, Hashable, Sendable {
    public var pageID: String
    /// Index of the backing PDF/EPUB page, or -1 for an inserted blank page.
    public var redir: Int

    public init(pageID: String, redir: Int = -1) {
        self.pageID = pageID
        self.redir = redir
    }
}

public enum FileKind: String, Codable, Sendable {
    case notebook, pdf, epub, folder

    init(rawFileType: String, isFolder: Bool) {
        if isFolder { self = .folder; return }
        switch rawFileType.lowercased() {
        case "pdf": self = .pdf
        case "epub": self = .epub
        default: self = .notebook
        }
    }
}

/// A document or folder in the reMarkable library.
public struct DocumentItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var parent: String
    public var kind: FileKind
    public var pageCount: Int
    public var pinned: Bool
    public var deleted: Bool
    public var lastModified: Date
    public var lastOpened: Date?
    public var lastOpenedPage: Int
    public var tags: [String]
    /// Hash of the document's `.docSchema` in the cloud.
    public var hash: String
    /// Subfile name (e.g. `<id>.pdf`, `<id>/<page>.rm`) → blob hash.
    public var subfiles: [String: String]
    public var pages: [PageRef]

    public init(
        id: String, name: String, parent: String = "", kind: FileKind, pageCount: Int = 0,
        pinned: Bool = false, deleted: Bool = false, lastModified: Date = .now, lastOpened: Date? = nil,
        lastOpenedPage: Int = 0, tags: [String] = [], hash: String = "", subfiles: [String: String] = [:],
        pages: [PageRef] = []
    ) {
        self.id = id
        self.name = name
        self.parent = parent
        self.kind = kind
        self.pageCount = pageCount
        self.pinned = pinned
        self.deleted = deleted
        self.lastModified = lastModified
        self.lastOpened = lastOpened
        self.lastOpenedPage = lastOpenedPage
        self.tags = tags
        self.hash = hash
        self.subfiles = subfiles
        self.pages = pages
    }

    public var isFolder: Bool { kind == .folder }
    public var isTrashed: Bool { parent == "trash" }

    /// Number of pages the reader should show.
    public var displayPageCount: Int {
        let rmCount = subfiles.keys.filter { $0.hasSuffix(".rm") }.count
        return max(pages.count, pageCount, rmCount, 1)
    }

    /// Blob hash of the main payload (`.pdf` or `.epub`), if any.
    public var payloadHash: String? {
        switch kind {
        case .pdf: return subfiles.first { $0.key.lowercased().hasSuffix(".pdf") }?.value
        case .epub: return subfiles.first { $0.key.lowercased().hasSuffix(".epub") }?.value
        default: return nil
        }
    }

    /// Backing PDF page for a logical page; -1 means an inserted note page. Falls back to 1:1 when `redir` is absent.
    public func pdfPageIndex(for pageIndex: Int) -> Int {
        guard !pages.isEmpty, pages.contains(where: { $0.redir >= 0 }) else { return pageIndex }
        return pages.indices.contains(pageIndex) ? pages[pageIndex].redir : -1
    }

    /// The `.rm` subfile name and blob hash for a logical page, if the page has ink.
    public func rmFile(for pageIndex: Int) -> (name: String, hash: String)? {
        if pages.indices.contains(pageIndex) {
            let pid = pages[pageIndex].pageID
            let exact = "\(id)/\(pid).rm"
            if let h = subfiles[exact] { return (exact, h) }
            if let match = subfiles.first(where: { $0.key.hasSuffix("/\(pid).rm") || $0.key == "\(pid).rm" }) {
                return (match.key, match.value)
            }
            return nil
        }
        let rm = subfiles.filter { $0.key.hasSuffix(".rm") }.sorted { $0.key < $1.key }
        return rm.indices.contains(pageIndex) ? (rm[pageIndex].key, rm[pageIndex].value) : nil
    }
}

/// Parsed `.metadata` + `.content` JSON for one document.
public struct DocumentMetadata: Sendable {
    public var visibleName = ""
    public var isFolder = false
    public var parent = ""
    public var lastModified: Date?
    public var lastOpened: Date?
    public var lastOpenedPage = 0
    public var pinned = false
    public var deleted = false
    public var pageCount = 0
    public var fileType = ""
    public var tags: [String] = []
    public var pages: [PageRef] = []

    public init() {}

    public static func parse(metadata: Data?, content: Data?) -> DocumentMetadata {
        var m = DocumentMetadata()
        if let metadata, let obj = jsonObject(metadata) {
            m.visibleName = obj.string("visibleName") ?? ""
            m.isFolder = obj.string("type") == "CollectionType"
            m.parent = obj.string("parent") ?? ""
            m.lastModified = obj.millisDate("lastModified")
            m.lastOpened = obj.millisDate("lastOpened")
            m.lastOpenedPage = obj.int("lastOpenedPage") ?? 0
            m.pinned = obj.bool("pinned") ?? false
            m.deleted = obj.bool("deleted") ?? false
        }
        guard let content, let obj = jsonObject(content) else { return m }
        if m.visibleName.isEmpty { m.visibleName = obj.string("visibleName") ?? "" }
        m.fileType = obj.string("fileType") ?? ""
        m.pageCount = obj.int("pageCount") ?? 0
        m.pages = parsePages(obj)

        if let tags = obj["tags"] as? [Any] {
            m.tags = tags.compactMap { t in
                if let s = t as? String { return s.isEmpty ? nil : s }
                if let d = t as? [String: Any], let n = d["name"] as? String, !n.isEmpty { return n }
                return nil
            }
        }
        if m.lastOpenedPage == 0,
           let lastID = ((obj["cPages"] as? [String: Any])?["lastOpened"] as? [String: Any])?["value"] as? String,
           let idx = m.pages.firstIndex(where: { $0.pageID == lastID }) {
            m.lastOpenedPage = idx
        }
        if !m.pages.isEmpty { m.pageCount = m.pages.count }
        return m
    }

    /// Firmware 3.x `cPages.pages` (sorted by `idx.value`, skipping deleted) or legacy `pages`.
    static func parsePages(_ content: [String: Any]) -> [PageRef] {
        if let cPages = (content["cPages"] as? [String: Any])?["pages"] as? [[String: Any]], !cPages.isEmpty {
            var active: [(String, PageRef)] = []
            for (pos, page) in cPages.enumerated() {
                guard let id = page["id"] as? String else { continue }
                if isDeleted(page["deleted"]) { continue }
                let idx = ((page["idx"] as? [String: Any])?["value"] as? String)
                    ?? (page["idx"] as? String)
                    ?? String(format: "%06d", pos)
                let redir = ((page["redir"] as? [String: Any])?["value"] as? Int) ?? (page["redir"] as? Int) ?? -1
                active.append((idx, PageRef(pageID: id, redir: redir)))
            }
            // Stable sort keeps file order for equal idx values.
            return active.enumerated()
                .sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
                .map { $0.element.1 }
        }
        if let legacy = content["pages"] as? [String] {
            return legacy.enumerated().map { PageRef(pageID: $0.element, redir: $0.offset) }
        }
        return []
    }

    static func isDeleted(_ value: Any?) -> Bool {
        if let d = value as? [String: Any] { return (d["value"] as? Int) == 1 }
        if let i = value as? Int { return i == 1 }
        if let b = value as? Bool { return b }
        return false
    }
}

func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

extension Dictionary where Key == String, Value == Any {
    func string(_ k: String) -> String? { self[k] as? String }
    func bool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let s = self[k] as? String { return s == "true" }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let i = self[k] as? Int { return i }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    /// reMarkable stores timestamps as millisecond strings.
    func millisDate(_ k: String) -> Date? {
        let ms: Double? = (self[k] as? String).flatMap(Double.init) ?? (self[k] as? Double)
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
