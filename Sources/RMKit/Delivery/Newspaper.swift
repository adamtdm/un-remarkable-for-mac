import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// "The Morning Chronicle": the web app's `DailyNewspaperGenerator` ported to Quartz. Masthead with date and
/// weather, Wikipedia's featured article, a tappable index (8 headlines a page), then each full article on its
/// own pages with a "BACK TO INDEX" link.
public enum Newspaper {
    public struct Options: Sendable, Equatable {
        public var feeds = NewsFeeds.defaults
        public var articlesPerFeed = 2
        public var includeWikipedia = true
        public var includeWeather = true
        public var weatherLocation = ""
        public var includeImages = false
        public var device = DeviceProfile.current
        public init() {}
    }

    public struct Lead: Sendable, Equatable {
        public var title: String
        public var extract: String
    }

    public struct Edition: Sendable {
        public var date: Date
        public var weather: String
        public var lead: Lead?
        public var articles: [NewsArticle]
    }

    /// Fetches everything and renders the PDF. Returns the PDF, a filename and the number of articles.
    public static func generate(_ options: Options, date: Date = .now, session: URLSession = .shared) async -> (pdf: Data, filename: String, articles: Int) {
        let edition = await fetch(options, date: date, session: session)
        return (render(edition, device: options.device), filename(date), edition.articles.count)
    }

    public static func filename(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "Morning_Chronicle_%04d-%02d-%02d.pdf", c.year!, c.month!, c.day!)
    }

    // MARK: Fetching

    public static func fetch(_ options: Options, date: Date, session: URLSession) async -> Edition {
        async let weather = options.includeWeather ? fetchWeather(options.weatherLocation, session: session) : ""
        async let lead = options.includeWikipedia ? fetchWikipedia(date, session: session) : nil
        async let articles = fetchArticles(options, session: session)
        return await Edition(date: date, weather: weather, lead: lead, articles: articles)
    }

    static func fetchArticles(_ options: Options, session: URLSession) async -> [NewsArticle] {
        let feeds = options.feeds.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Feed order is kept so the paper reads the same way as the settings list.
        let items: [[FeedItem]] = await withTaskGroup(of: (Int, [FeedItem]).self) { group in
            for (i, feed) in feeds.enumerated() {
                group.addTask {
                    guard let url = URL(string: feed) else { return (i, []) }
                    var req = URLRequest(url: url, timeoutInterval: 8)
                    req.setValue("Un-remarkable-Mac (reMarkable Companion RSS Reader)", forHTTPHeaderField: "User-Agent")
                    guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return (i, []) }
                    return (i, NewsFeeds.parseFeed(data, feedURL: feed, limit: options.articlesPerFeed))
                }
            }
            var out = [[FeedItem]](repeating: [], count: feeds.count)
            for await (i, list) in group { out[i] = list }
            return out
        }
        let flat = items.flatMap { $0 }
        var articles: [NewsArticle?] = await withTaskGroup(of: (Int, NewsArticle?).self) { group in
            for (i, item) in flat.enumerated() {
                group.addTask { (i, await NewsFeeds.article(for: item, session: session)) }
            }
            var out = [NewsArticle?](repeating: nil, count: flat.count)
            for await (i, a) in group { out[i] = a }
            return out
        }
        if options.includeImages {
            for i in articles.indices {
                guard let a = articles[i] else { continue }
                articles[i]?.imageJPEG = await leadImage(a.imageURLs, color: options.device.isColor, session: session)
            }
        }
        return articles.compactMap { $0 }
    }

    /// The first usable image (≥200×100, ≤5 MB), re-encoded as a JPEG for the page.
    static func leadImage(_ urls: [String], color: Bool, session: URLSession) async -> Data? {
        for s in urls.prefix(3) {
            guard let url = URL(string: s), let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000,
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  image.width >= 200, image.height >= 100 else { continue }
            var opts = Converter.Options()
            opts.device = color ? .paperPro : .rm2
            return Converter.encode(image, target: (1200, 1200), options: opts).jpeg
        }
        return nil
    }

    static func fetchWeather(_ location: String, session: URLSession) async -> String {
        let loc = location.trimmingCharacters(in: .whitespaces)
        let path = loc.replacingOccurrences(of: " ", with: "+").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://wttr.in/\(path)?format=j1") else { return "" }
        let req = URLRequest(url: url, timeoutInterval: 5)
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = (json["current_condition"] as? [[String: Any]])?.first else { return "" }
        let temp = current["temp_C"] as? String ?? ""
        let desc = ((current["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let nearest = (((json["nearest_area"] as? [[String: Any]])?.first?["areaName"] as? [[String: Any]])?.first?["value"] as? String) ?? ""
        let label = loc.isEmpty ? nearest : loc
        return label.isEmpty ? "\(temp)°C, \(desc)" : "\(label): \(temp)°C, \(desc)"
    }

    static func fetchWikipedia(_ date: Date, session: URLSession) async -> Lead? {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let url = URL(string: String(format: "https://en.wikipedia.org/api/rest_v1/feed/featured/%04d/%02d/%02d", c.year!, c.month!, c.day!))!
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Un-remarkable-Mac/1.0 (reMarkable companion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tfa = json["tfa"] as? [String: Any] else { return nil }
        let title = (tfa["titles"] as? [String: Any])?["normalized"] as? String ?? (tfa["title"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
        guard let extract = tfa["extract"] as? String, !extract.isEmpty else { return nil }
        return Lead(title: title, extract: extract)
    }

    // MARK: Rendering

    static let margin: CGFloat = 90
    static let perIndexPage = 8

    /// Grouped by section in the web app's order.
    static func sectioned(_ articles: [NewsArticle]) -> [(section: String, articles: [NewsArticle])] {
        var out: [(String, [NewsArticle])] = []
        for s in NewsFeeds.sections {
            let list = articles.filter { (NewsFeeds.sections.contains($0.section) ? $0.section : "General Dispatches") == s }
            if !list.isEmpty { out.append((s, list)) }
        }
        return out
    }

    public static func render(_ e: Edition, device: DeviceProfile) -> Data {
        let size = device.portrait
        let ordered = sectioned(e.articles).flatMap { s in s.articles.map { (s.section, $0) } }
        let indexPages = max(1, (ordered.count + perIndexPage - 1) / perIndexPage)

        // Pass 1 measures how many pages each article takes, so the index can show page numbers.
        let measure = PDFCanvas(width: size.width, height: size.height, measuring: true)
        var starts: [Int] = []
        for (_, a) in ordered {
            starts.append(indexPages + measure.pageCount + 1)
            articlePages(measure, a, index: 0)
        }
        let total = indexPages + measure.pageCount

        let p = PDFCanvas(width: size.width, height: size.height)
        for page in 0..<indexPages {
            p.beginPage()
            var y: CGFloat = 100
            if page == 0 {
                p.destination("index")
                masthead(p, e)
                y = 245
                if let lead = e.lead { y = leadStory(p, lead, top: y) }
            }
            let slice = Array(ordered.enumerated()).dropFirst(page * perIndexPage).prefix(perIndexPage)
            index(p, slice.map { (i, entry) in (entry.0, entry.1, starts[i], i) }, top: y, empty: ordered.isEmpty)
            footer(p, total: total)
        }
        for (i, (_, a)) in ordered.enumerated() {
            articlePages(p, a, index: i, total: total)
        }
        return p.finish()
    }

    static func masthead(_ p: PDFCanvas, _ e: Edition) {
        let w = p.width
        p.line(margin, 80, w - margin, 80, width: 2.5)
        p.line(margin, 86, w - margin, 86, width: 0.8)
        p.text("THE MORNING CHRONICLE", x: margin, y: 155, face: .serifBold, size: 52)
        p.line(margin, 178, w - margin, 178)
        var meta = [e.date.formatted(.dateTime.weekday(.wide).month(.wide).day(.twoDigits).year()).uppercased(), "DAILY E-INK EDITION"]
        if !e.weather.isEmpty { meta.append(e.weather.uppercased()) }
        p.text(meta.joined(separator: "   •   "), x: margin, y: 206, size: 16, gray: 0.25)
        p.line(margin, 222, w - margin, 222, width: 1.8)
    }

    /// Wikipedia's featured article in two columns. Returns the y below it.
    static func leadStory(_ p: PDFCanvas, _ lead: Lead, top y: CGFloat) -> CGFloat {
        let w = p.width
        p.text("TODAY'S FEATURED INSIGHT  •  WIKIPEDIA ESSENTIAL KNOWLEDGE", x: margin, y: y + 18, size: 13, gray: 0.35)
        p.textBox(NSAttributedString(string: lead.title, attributes: PDFCanvas.attributes(.serifBold, 28)),
                  in: CGRect(x: margin, y: y + 28, width: w - 2 * margin, height: 57))
        p.line(margin, y + 92, w - margin, y + 92, width: 0.6, gray: 0.5)
        let gap: CGFloat = 50, colW = (w - 2 * margin - gap) / 2
        let body = NSAttributedString(string: lead.extract, attributes: PDFCanvas.attributes(.serif, 17, lineHeight: 1.35))
        let setter = CTFramesetterCreateWithAttributedString(body)
        let top = y + 105, height: CGFloat = 195
        let shown = p.draw(setter, range: CFRange(location: 0, length: 0), in: CGRect(x: margin, y: top, width: colW, height: height))
        p.draw(setter, range: CFRange(location: shown, length: 0), in: CGRect(x: margin + colW + gap, y: top, width: colW, height: height))
        p.line(margin + colW + gap / 2, top, margin + colW + gap / 2, top + height, width: 0.5, gray: 0.75)
        return top + height + 25
    }

    static func index(_ p: PDFCanvas, _ entries: [(section: String, article: NewsArticle, page: Int, id: Int)], top y: CGFloat, empty: Bool) {
        let w = p.width
        p.line(margin, y, w - margin, y, width: 2)
        p.line(margin, y + 4, w - margin, y + 4, width: 0.8)
        p.text("TODAY'S SECTIONS & READING COMPASS   •   TAP ANY HEADLINE TO READ", x: margin, y: y + 28, size: 15, gray: 0.2)
        p.line(margin, y + 40, w - margin, y + 40)
        if empty {
            p.text("No complete articles available from your selected feeds today.", x: margin, y: y + 80, face: .serifItalic, size: 17, gray: 0.4)
            return
        }
        let gap: CGFloat = 60, colW = (w - 2 * margin - gap) / 2
        let split = (entries.count + 1) / 2
        for (col, part) in [entries.prefix(split), entries.dropFirst(split)].enumerated() {
            let x0 = margin + CGFloat(col) * (colW + gap)
            var cy = y + 65
            var section = ""
            for entry in part {
                if entry.section != section {
                    section = entry.section
                    p.text(section.uppercased(), x: x0, y: cy + 16, face: .serifBold, size: 15)
                    p.line(x0, cy + 22, x0 + colW, cy + 22, width: 0.5, gray: 0.4)
                    cy += 36
                }
                p.textBox(NSAttributedString(string: entry.article.title, attributes: PDFCanvas.attributes(.serifBold, 26)),
                          in: CGRect(x: x0 + 8, y: cy, width: colW - 8, height: 72))
                p.text("\(entry.article.source) | \(entry.article.readingMinutes) min | Page \(entry.page)", x: x0 + 8, y: cy + 100, face: .sans, size: 18, gray: 0.3)
                p.link(CGRect(x: x0, y: cy - 2, width: colW, height: 122), to: "article-\(entry.id)")
                cy += 130
            }
            cy += 18
        }
    }

    /// Lays out one article from a fresh page, flowing its text across as many pages as it needs.
    static func articlePages(_ p: PDFCanvas, _ a: NewsArticle, index: Int, total: Int = 0) {
        let w = p.width, h = p.height
        let body = NSMutableAttributedString()
        for block in a.blocks {
            let heading = block.kind == .heading
            body.append(NSAttributedString(string: block.text + "\n", attributes: heading
                ? PDFCanvas.attributes(.serifBold, 36, lineHeight: 1.2, paragraphSpacing: 22)
                : PDFCanvas.attributes(.serif, 30, lineHeight: 1.3, paragraphSpacing: 22)))
        }
        let setter = CTFramesetterCreateWithAttributedString(body)
        var location = 0
        var first = true
        repeat {
            p.beginPage()
            if first { p.destination("article-\(index)") }
            let back = CGRect(x: margin, y: 70, width: 260, height: 45)
            p.stroke(back, width: 0.8, gray: 0.5)
            p.text("BACK TO INDEX", x: margin + 18, y: 100, size: 22)
            p.link(back, to: "index")
            var top: CGFloat = 150
            if first {
                p.textBox(NSAttributedString(string: a.title, attributes: PDFCanvas.attributes(.serifBold, 42, lineHeight: 1.05)),
                          in: CGRect(x: margin, y: 140, width: w - 2 * margin, height: 120))
                p.text("\(a.source) | \(a.readingMinutes) min read", x: margin, y: 285, face: .serifItalic, size: 22, gray: 0.3)
                top = 310
                if let jpeg = a.imageJPEG {
                    p.jpeg(jpeg, in: CGRect(x: margin, y: 320, width: w - 2 * margin, height: 380))
                    top += 420
                }
            }
            let drawn = p.draw(setter, range: CFRange(location: location, length: 0), in: CGRect(x: margin, y: top, width: w - 2 * margin, height: h - 120 - top))
            location += drawn
            if total > 0 { footer(p, total: total) }
            first = false
            if drawn == 0 { break } // nothing fits (shouldn't happen); avoid looping forever
        } while location < body.length
    }

    static func footer(_ p: PDFCanvas, total: Int) {
        let w = p.width, y = p.height - 55
        p.line(margin, y - 18, w - margin, y - 18, width: 0.8, gray: 0.6)
        p.text("Curated & delivered by Un-remarkable", x: margin, y: y, size: 14, gray: 0.4)
        let label = total > 1 ? "Page \(p.pageCount) of \(total)" : "Page \(p.pageCount)"
        p.text(label, x: w - margin - PDFCanvas.textWidth(label, face: .sans, size: 14), y: y, size: 14, gray: 0.4)
    }
}
