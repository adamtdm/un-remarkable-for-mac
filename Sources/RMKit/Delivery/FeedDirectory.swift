import Foundation

/// The web app's curated feed directory: popular feeds by category, presets, validation and discovery of a
/// site's feed from its address (`rss_directory.py`).
public enum FeedDirectory {
    public struct Feed: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var url: String
        public var siteURL: String
        public var category: String
        public var summary: String
        public var isDefault: Bool
    }

    public struct Preset: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var summary: String
        public var feeds: [String]
    }

    /// A checked feed: its title, description and latest headlines.
    public struct Checked: Sendable, Hashable, Identifiable {
        public var id: String { url }
        public var url: String
        public var title: String
        public var summary: String
        public var articleCount: Int
        public var headlines: [String]
        public var source: String
    }

    static let userAgent = "Un-remarkable-Mac (reMarkable Daily Newspaper RSS Reader)"

    /// Catalogue feeds matching a query (name, description, category, URL) within a category ("All" for any).
    public static func search(_ query: String, category: String = "All") -> [Feed] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return popular.filter { f in
            if category != "All", f.category.caseInsensitiveCompare(category) != .orderedSame { return false }
            guard !q.isEmpty else { return true }
            return [f.name, f.summary, f.category, f.url, f.siteURL].contains { $0.lowercased().contains(q) }
        }
    }

    /// The catalogue name for a feed URL, if it's a known feed.
    public static func name(for url: String) -> String? {
        popular.first { $0.url.caseInsensitiveCompare(url) == .orderedSame }?.name
    }

    static func normalised(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
        return URL(string: t)
    }

    static func fetch(_ url: URL, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RMError.malformed("No response") }
        return (data, http)
    }

    /// Parses RSS or Atom; nil when the data isn't a feed.
    static func describe(_ data: Data, url: String, source: String) -> Checked? {
        guard let doc = try? XMLDocument(data: data), let root = doc.rootElement(),
              ["rss", "feed", "RDF"].contains(root.localName ?? "") else { return nil }
        func text(_ xpath: String) -> String {
            NewsFeeds.cleanHTML((try? doc.nodes(forXPath: xpath))?.first?.stringValue ?? "")
        }
        let title = text("/*/*[local-name()='channel']/*[local-name()='title'] | /*[local-name()='feed']/*[local-name()='title']")
        let summary = text("/*/*[local-name()='channel']/*[local-name()='description'] | /*[local-name()='feed']/*[local-name()='subtitle']")
        var items = (try? doc.nodes(forXPath: "//*[local-name()='item']")) ?? []
        if items.isEmpty { items = (try? doc.nodes(forXPath: "//*[local-name()='entry']")) ?? [] }
        let headlines = items.prefix(5).compactMap { item -> String? in
            let t = NewsFeeds.cleanHTML((try? item.nodes(forXPath: "./*[local-name()='title']"))?.first?.stringValue ?? "")
            return t.isEmpty ? nil : t
        }
        return Checked(url: url, title: title.isEmpty ? "RSS Feed" : title, summary: summary, articleCount: items.count, headlines: headlines, source: source)
    }

    /// Fetches a feed and checks it parses.
    public static func validate(_ address: String, session: URLSession = .shared) async throws -> Checked {
        guard let url = normalised(address) else { throw RMError.malformed("Enter a feed address") }
        let (data, http) = try await fetch(url, session: session)
        guard http.statusCode == 200 else { throw RMError.http(http.statusCode, "The feed returned HTTP \(http.statusCode)") }
        guard let checked = describe(data, url: (http.url ?? url).absoluteString, source: "Feed") else {
            throw RMError.malformed("That address isn't an RSS or Atom feed")
        }
        return checked
    }

    /// Finds feeds for a website or feed address: the address itself, `<link rel="alternate">` tags, then the
    /// usual paths (/feed, /rss, /rss.xml, /atom.xml, /feed.xml). Returns up to five working feeds.
    public static func discover(_ target: String, session: URLSession = .shared) async -> [Checked] {
        guard let url = normalised(target), let (data, http) = try? await fetch(url, session: session) else { return [] }
        let base = http.url ?? url
        if let direct = describe(data, url: base.absoluteString, source: "Feed address") { return [direct] }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var candidates: [(String, String)] = []
        for m in html.matches(of: /(?i)<link[^>]+type=["'](?:application\/(?:rss|atom)\+xml|text\/xml)["'][^>]*>/) {
            let tag = String(m.0)
            guard let href = tag.firstMatch(of: /(?i)href=["']([^"'>]+)["']/)?.1,
                  let abs = URL(string: NewsFeeds.decodeEntities(String(href)), relativeTo: base)?.absoluteString,
                  !candidates.contains(where: { $0.0 == abs }) else { continue }
            candidates.append((abs, "Linked from the page"))
        }
        if candidates.isEmpty {
            for path in ["/feed", "/rss", "/rss.xml", "/atom.xml", "/feed.xml"] {
                if let u = URL(string: path, relativeTo: base)?.absoluteString { candidates.append((u, "Standard path \(path)")) }
            }
        }
        var found: [Checked] = []
        for (address, source) in candidates.prefix(5) {
            guard let u = URL(string: address), let (d, h) = try? await fetch(u, session: session), h.statusCode == 200,
                  var c = describe(d, url: (h.url ?? u).absoluteString, source: source) else { continue }
            c.source = source
            found.append(c)
            if source.hasPrefix("Standard path") { break }
        }
        return found
    }
}
