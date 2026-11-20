import Foundation

/// A source of search results. The Mac app searches its local FTS5 index today; a client for the
/// self-hosted Un-remarkable server (handwriting OCR, Vision task extraction) can conform to this
/// later and be merged in without touching the UI.
public protocol SearchProvider: Sendable {
    var name: String { get }
    func search(_ query: String) async throws -> [SearchHit]
}

public struct LocalSearchProvider: SearchProvider {
    let db: LibraryDatabase
    public init(db: LibraryDatabase) { self.db = db }
    public var name: String { "This Mac" }
    public func search(_ query: String) async throws -> [SearchHit] { db.search(query) }
}

/// Search on the self-hosted Un-remarkable web app (`GET /api/search`), so its handwriting OCR and other
/// indexed text show up next to the Mac's own results. Short timeout: a server that's off never slows search.
public struct CompanionSearchProvider: SearchProvider {
    public let base: URL
    let session: URLSession
    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }
    public var name: String { "Companion server" }

    public func search(_ query: String) async throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var c = URLComponents(url: base.appending(path: "api/search"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "40")]
        guard let url = c?.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RMError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "Companion search failed") }
        return Self.parse(data)
    }

    /// The web app marks matches with `<mark>`; the Mac's snippets use « ».
    static func parse(_ data: Data) -> [SearchHit] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["doc_id"] as? String else { return nil }
            var snippet = (r["snippet"] as? String ?? "")
                .replacingOccurrences(of: "<mark>", with: "«").replacingOccurrences(of: "</mark>", with: "»")
                .replacingOccurrences(of: "...", with: "…")
                .replacingOccurrences(of: "\n", with: " ")
            if (r["source"] as? String)?.contains("ocr") == true || (r["source"] as? String) == "handwriting" { snippet = "✍︎ " + snippet }
            return SearchHit(docID: id, snippet: snippet)
        }
    }
}
