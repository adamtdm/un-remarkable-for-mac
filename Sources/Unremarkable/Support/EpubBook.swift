import Foundation
import RMKit

/// An unpacked EPUB: its reading-order chapter files and table of contents.
struct EpubBook: Sendable {
    struct Chapter: Identifiable, Hashable, Sendable {
        let id: Int
        let url: URL
        let title: String
    }

    let root: URL
    let chapters: [Chapter]

    /// Unpacks the EPUB payload into the cache (once per payload hash) and parses the OPF spine.
    static func load(_ doc: DocumentItem, sync: SyncEngine, cacheDir: URL) async throws -> EpubBook {
        guard let hash = doc.payloadHash else { throw RMError.notFound("This book has no EPUB file.") }
        _ = try await sync.blob(hash, filename: "\(doc.id).epub")
        let dir = cacheDir.appending(path: hash)
        if !FileManager.default.fileExists(atPath: dir.appending(path: "META-INF/container.xml").path) {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try unzip(sync.blobs.url(for: hash), to: dir)
        }
        return try parse(root: dir)
    }

    /// The book's cover image: the EPUB 3 `cover-image` item, the EPUB 2 `<meta name="cover">`, else the
    /// first image on the first page.
    static func coverImage(root: URL) -> URL? {
        guard let container = try? XMLDocument(contentsOf: root.appending(path: "META-INF/container.xml")),
              let opfPath = (try? container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path"))?.first?.stringValue,
              let opf = try? XMLDocument(contentsOf: root.appending(path: opfPath)) else { return nil }
        let base = root.appending(path: opfPath).deletingLastPathComponent()
        let items = ((try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? []).compactMap { $0 as? XMLElement }
        func href(_ e: XMLElement?) -> URL? {
            guard let h = e?.attribute(forName: "href")?.stringValue else { return nil }
            return base.appending(path: h.removingPercentEncoding ?? h).standardizedFileURL
        }
        if let e = items.first(where: { ($0.attribute(forName: "properties")?.stringValue ?? "").contains("cover-image") }) { return href(e) }
        if let id = (try? opf.nodes(forXPath: "//*[local-name()='meta'][@name='cover']/@content"))?.first?.stringValue,
           let e = items.first(where: { $0.attribute(forName: "id")?.stringValue == id }),
           (e.attribute(forName: "media-type")?.stringValue ?? "").hasPrefix("image") { return href(e) }
        if let e = items.first(where: { ($0.attribute(forName: "id")?.stringValue ?? "").lowercased().contains("cover")
            && ($0.attribute(forName: "media-type")?.stringValue ?? "").hasPrefix("image") }) { return href(e) }
        guard let book = try? parse(root: root), let first = book.chapters.first,
              let html = try? String(contentsOf: first.url, encoding: .utf8),
              let m = html.firstMatch(of: /(?:<img[^>]+src|<image[^>]+(?:xlink:)?href)\s*=\s*["']([^"']+)["']/) else { return nil }
        let src = String(m.1)
        return first.url.deletingLastPathComponent().appending(path: src.removingPercentEncoding ?? src).standardizedFileURL
    }

    static func unzip(_ file: URL, to dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", file.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RMError.malformed("Could not unpack the EPUB.") }
    }

    static func parse(root: URL) throws -> EpubBook {
        let container = try XMLDocument(contentsOf: root.appending(path: "META-INF/container.xml"))
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw RMError.malformed("EPUB has no package file.")
        }
        let opfURL = root.appending(path: opfPath)
        let base = opfURL.deletingLastPathComponent()
        let opf = try XMLDocument(contentsOf: opfURL)

        var manifest: [String: (href: String, type: String)] = [:]
        for case let item as XMLElement in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue {
                manifest[id] = (href.removingPercentEncoding ?? href, item.attribute(forName: "media-type")?.stringValue ?? "")
            }
        }
        let titles = tocTitles(opf: opf, manifest: manifest, base: base)

        var chapters: [Chapter] = []
        for case let ref as XMLElement in try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard let idref = ref.attribute(forName: "idref")?.stringValue, let item = manifest[idref] else { continue }
            let url = base.appending(path: item.href).standardizedFileURL
            let key = url.lastPathComponent
            chapters.append(Chapter(id: chapters.count, url: url, title: titles[key] ?? "Section \(chapters.count + 1)"))
        }
        guard !chapters.isEmpty else { throw RMError.malformed("EPUB has no readable chapters.") }
        return EpubBook(root: root, chapters: chapters)
    }

    /// Chapter titles keyed by file name, from the EPUB 3 nav document or the EPUB 2 NCX.
    static func tocTitles(opf: XMLDocument, manifest: [String: (href: String, type: String)], base: URL) -> [String: String] {
        var out: [String: String] = [:]
        func record(_ href: String, _ title: String) {
            let file = (href.components(separatedBy: "#").first ?? href).removingPercentEncoding ?? href
            let key = URL(fileURLWithPath: file).lastPathComponent
            if out[key] == nil, !title.isEmpty { out[key] = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let ncx = manifest.values.first(where: { $0.type == "application/x-dtbncx+xml" }),
           let doc = try? XMLDocument(contentsOf: base.appending(path: ncx.href)),
           let points = try? doc.nodes(forXPath: "//*[local-name()='navPoint']") {
            for case let p as XMLElement in points {
                let label = (try? p.nodes(forXPath: "./*[local-name()='navLabel']/*[local-name()='text']").first?.stringValue) ?? nil
                let src = (try? p.nodes(forXPath: "./*[local-name()='content']/@src").first?.stringValue) ?? nil
                if let label, let src { record(src, label) }
            }
        }
        if out.isEmpty,
           let nav = (try? opf.nodes(forXPath: "//*[local-name()='item'][contains(@properties,'nav')]/@href").first?.stringValue) ?? nil,
           let doc = try? XMLDocument(contentsOf: base.appending(path: nav), options: [.documentTidyHTML]),
           let links = try? doc.nodes(forXPath: "//*[local-name()='a']") {
            for case let a as XMLElement in links {
                if let href = a.attribute(forName: "href")?.stringValue { record(href, a.stringValue ?? "") }
            }
        }
        return out
    }
}

extension EpubBook {
    /// Relative size of each chapter (file bytes), a cheap proxy for its share of the book's pages.
    var weights: [Double] {
        chapters.map { c in Double((try? c.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1).clamped(min: 1) }
    }

    /// How far through the book a chapter starts, 0…1.
    func fraction(ofChapter index: Int) -> Double {
        let w = weights
        let total = w.reduce(0, +)
        guard total > 0, index > 0 else { return 0 }
        return w.prefix(min(index, w.count)).reduce(0, +) / total
    }

    /// The chapter containing a position given as a fraction through the book.
    func chapter(atFraction f: Double) -> Int {
        let w = weights
        let total = w.reduce(0, +)
        guard total > 0 else { return 0 }
        var acc = 0.0
        for (i, x) in w.enumerated() {
            acc += x / total
            if f < acc { return i }
        }
        return max(chapters.count - 1, 0)
    }
}

private extension Double {
    func clamped(min lo: Double) -> Double { Swift.max(self, lo) }
}
