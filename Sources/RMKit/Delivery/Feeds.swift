import Foundation

/// One article for the newspaper.
public struct NewsArticle: Sendable, Equatable {
    public struct Block: Sendable, Equatable {
        public enum Kind: Sendable { case paragraph, heading }
        public var kind: Kind
        public var text: String
    }

    public var title: String
    public var source: String
    public var section: String
    public var url: String
    public var blocks: [Block]
    public var imageURLs: [String] = []
    public var imageJPEG: Data?

    public var wordCount: Int { blocks.reduce(0) { $0 + $1.text.split(separator: " ").count } }
    public var readingMinutes: Int { max(1, Int((Double(wordCount) / 200).rounded())) }
}

struct FeedItem: Sendable {
    var source: String
    var section: String
    var title: String
    var summary: String
    var link: String
    var contentEncoded: String
}

public enum NewsFeeds {
    public static let defaults = [
        "https://feeds.bbci.co.uk/news/rss.xml",
        "https://www.theguardian.com/world/rss",
        "https://feeds.npr.org/1001/rss.xml",
        "https://news.ycombinator.com/rss",
        "https://www.theverge.com/rss/index.xml",
        "https://feeds.arstechnica.com/arstechnica/index",
        "https://www.nature.com/nature.rss",
    ]

    public static let sections = [
        "World & National News", "Technology & Computing", "Science & Space Exploration",
        "Business & Finance", "Culture & Longform Essays", "Sports & Competition", "General Dispatches",
    ]

    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 (Un-remarkable E-Ink Reader)"

    /// Editorial section for a feed, from keywords in its URL and title (as in the web app).
    public static func section(feedURL: String, title: String) -> String {
        let s = (feedURL + " " + title).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(["tech", "verge", "ars", "wired", "hacker", "ycombinator", "lobste", "code", "cyber", "software"]) { return "Technology & Computing" }
        if has(["science", "nature", "nasa", "space", "quantum", "phys", "astronomy"]) { return "Science & Space Exploration" }
        if has(["economist", "market", "finance", "wsj", "cnbc", "money", "invest"]) { return "Business & Finance" }
        if has(["sport", "athletic", "espn", "football", "soccer", "nba", "cricket"]) { return "Sports & Competition" }
        if has(["culture", "essay", "atlantic", "book", "aeon", "philosophy"]) { return "Culture & Longform Essays" }
        return "World & National News"
    }

    // MARK: Text helpers

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "mdash": "—", "ndash": "–", "hellip": "…", "pound": "£", "euro": "€", "copy": "©",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacing(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/) { m in
            let e = String(m.1)
            if e.hasPrefix("#x") || e.hasPrefix("#X") { return UInt32(e.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map { String($0) } ?? "" }
            if e.hasPrefix("#") { return UInt32(e.dropFirst()).flatMap(UnicodeScalar.init).map { String($0) } ?? "" }
            return entities[e] ?? String(m.0)
        }
    }

    /// Strips tags, decodes entities (twice: feeds often double-encode) and collapses whitespace.
    static func cleanHTML(_ raw: String) -> String {
        let text = decodeEntities(decodeEntities(raw.replacing(/<[^>]+>/, with: " ")))
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: RSS / Atom

    static func parseFeed(_ data: Data, feedURL: String, limit: Int) -> [FeedItem] {
        guard let doc = (try? XMLDocument(data: data)) ?? (try? XMLDocument(data: data, options: [.documentTidyXML])) else { return [] }
        func first(_ node: XMLNode, _ names: [String]) -> XMLElement? {
            for n in names {
                if let e = (try? node.nodes(forXPath: "./*[local-name()='\(n)']"))?.first as? XMLElement { return e }
            }
            return nil
        }
        let channelTitle = ((try? doc.nodes(forXPath: "/*/*[local-name()='channel']/*[local-name()='title'] | /*[local-name()='feed']/*[local-name()='title']"))?.first?.stringValue)
            .map(cleanHTML) ?? "News Dispatch"
        let section = section(feedURL: feedURL, title: channelTitle)
        var items = (try? doc.nodes(forXPath: "//*[local-name()='item']")) ?? []
        if items.isEmpty { items = (try? doc.nodes(forXPath: "//*[local-name()='entry']")) ?? [] }
        var out: [FeedItem] = []
        for item in items.prefix(limit) {
            let title = cleanHTML(first(item, ["title"])?.stringValue ?? "")
            guard !title.isEmpty else { continue }
            let linkEl = first(item, ["link"])
            let link = (linkEl?.stringValue?.isEmpty == false ? linkEl?.stringValue : linkEl?.attribute(forName: "href")?.stringValue) ?? ""
            out.append(FeedItem(source: channelTitle, section: section, title: title,
                                summary: cleanHTML(first(item, ["description", "summary"])?.stringValue ?? ""),
                                link: link.trimmingCharacters(in: .whitespacesAndNewlines),
                                contentEncoded: first(item, ["encoded", "content"])?.stringValue ?? ""))
        }
        return out
    }

    // MARK: Article extraction

    static let skipTags: Set<String> = ["script", "style", "nav", "header", "footer", "aside", "form", "noscript", "svg", "iframe", "button", "dialog", "figure", "figcaption"]
    static let skipWords = ["sidebar", "comment", "related-posts", "cookie-banner", "newsletter-signup", "advert"]
    nonisolated(unsafe) static let boilerplate: [Regex<Substring>] = [
        /(?i)^(?:sign up|subscribe|newsletter|follow us|join our|download the app|read more:)/,
        /(?i)^(?:cookies policy|privacy policy|terms of service|all rights reserved|©\s*\d{4})/,
        /(?i)^(?:share this story|share on twitter|share on facebook|comment on this)/,
        /(?i)^(?:advertisement|sponsored content|promoted stories)/,
    ]

    /// Article paragraphs and sub-headings from a page's HTML, skipping navigation, adverts and boilerplate.
    static func extract(html: String) -> (blocks: [NewsArticle.Block], images: [String]) {
        // Tidy predates HTML5: it drops <nav>, <header>, <footer> and <aside> but keeps their text, so remove them first.
        let cleaned = html.replacing(/(?is)<(nav|header|footer|aside|script|style|noscript|svg|form)\b.*?<\/\1\s*>/, with: "")
        guard let doc = try? XMLDocument(xmlString: cleaned, options: [.documentTidyHTML]), let root = doc.rootElement() else { return ([], []) }
        var blocks: [NewsArticle.Block] = []
        var images: [String] = []
        func add(_ el: XMLElement, _ kind: NewsArticle.Block.Kind) {
            let text = (el.stringValue ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard text.count >= 25, !boilerplate.contains(where: { text.firstMatch(of: $0) != nil }) else { return }
            blocks.append(.init(kind: kind, text: text))
        }
        func walk(_ el: XMLElement) {
            let tag = (el.name ?? "").lowercased()
            if skipTags.contains(tag) { return }
            let classID = ((el.attribute(forName: "class")?.stringValue ?? "") + " " + (el.attribute(forName: "id")?.stringValue ?? "")).lowercased()
            if skipWords.contains(where: classID.contains) { return }
            switch tag {
            case "img":
                if let src = el.attribute(forName: "data-src")?.stringValue ?? el.attribute(forName: "src")?.stringValue { images.append(src) }
                return
            case "p": add(el, .paragraph); collectImages(el); return
            case "h2", "h3": add(el, .heading); return
            case "blockquote":
                if ((try? el.nodes(forXPath: ".//p"))?.isEmpty ?? true) { add(el, .paragraph); return }
            default: break
            }
            for case let child as XMLElement in el.children ?? [] { walk(child) }
        }
        func collectImages(_ el: XMLElement) {
            for case let img as XMLElement in (try? el.nodes(forXPath: ".//img")) ?? [] {
                if let src = img.attribute(forName: "data-src")?.stringValue ?? img.attribute(forName: "src")?.stringValue { images.append(src) }
            }
        }
        walk(root)
        return (blocks, images)
    }

    /// The full article for a feed item: from the feed's own content when it's long enough, otherwise from
    /// the web page. Returns nil when no complete article can be read (summary-only posts are skipped).
    static func article(for item: FeedItem, session: URLSession) async -> NewsArticle? {
        func build(_ html: String) -> NewsArticle? {
            let (blocks, images) = extract(html: html)
            let words = blocks.reduce(0) { $0 + $1.text.split(separator: " ").count }
            guard words >= 180, blocks.count >= 2 else { return nil }
            let base = URL(string: item.link)
            let abs = images.compactMap { URL(string: $0, relativeTo: base)?.absoluteString }.filter { $0.hasPrefix("http") }
            return NewsArticle(title: item.title, source: item.source, section: item.section, url: item.link, blocks: blocks, imageURLs: abs)
        }
        if item.contentEncoded.split(separator: " ").count > 180, let a = build(item.contentEncoded) { return a }
        guard let url = URL(string: item.link), url.scheme?.hasPrefix("http") == true else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(browserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return build(html)
    }
}
