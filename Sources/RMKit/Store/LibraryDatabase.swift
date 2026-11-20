import Foundation
import SQLite3

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String { docID }
    public let docID: String
    public let snippet: String
    public init(docID: String, snippet: String) {
        self.docID = docID
        self.snippet = snippet
    }
}

/// SQLite library index: document records, sync state and an FTS5 full-text index.
/// All access is serialised through one lock, so it is safe to call from any thread.
public final class LibraryDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw RMError.malformed("Cannot open library database at \(url.path)")
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, parent TEXT, deleted INTEGER, json BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS documents_parent ON documents(parent);
            CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS indexed (doc_id TEXT PRIMARY KEY, hash TEXT);
            CREATE TABLE IF NOT EXISTS pending_positions (doc_id TEXT PRIMARY KEY, page INTEGER);
            CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, fingerprint TEXT UNIQUE, json BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS scanned (key TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS ocr (rm_hash TEXT PRIMARY KEY, text TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS snapshots (root_hash TEXT PRIMARY KEY, generation INTEGER, doc_count INTEGER,
                changed INTEGER, created_at REAL);
            CREATE TABLE IF NOT EXISTS snapshot_docs (root_hash TEXT, doc_id TEXT, doc_hash TEXT, PRIMARY KEY (root_hash, doc_id));
            CREATE INDEX IF NOT EXISTS snapshot_docs_doc ON snapshot_docs(doc_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
                doc_id UNINDEXED, title, tags, body, tokenize='unicode61 remove_diacritics 2');
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Documents

    public func upsert(_ docs: [DocumentItem]) {
        lock.withLock {
            _ = rawExec("BEGIN")
            for d in docs {
                guard let json = try? encoder.encode(d) else { continue }
                run("INSERT OR REPLACE INTO documents (id, parent, deleted, json) VALUES (?, ?, ?, ?)",
                    [.text(d.id), .text(d.parent), .int(d.deleted ? 1 : 0), .blob(json)])
                // Keep title/tags searchable immediately; the body is filled in by the indexer.
                let body = scalarText("SELECT body FROM search WHERE doc_id = ?", [.text(d.id)]) ?? ""
                run("DELETE FROM search WHERE doc_id = ?", [.text(d.id)])
                if !d.deleted {
                    run("INSERT INTO search (doc_id, title, tags, body) VALUES (?, ?, ?, ?)",
                        [.text(d.id), .text(d.name), .text(d.tags.joined(separator: " ")), .text(body)])
                }
            }
            _ = rawExec("COMMIT")
        }
    }

    public func remove(ids: [String]) {
        lock.withLock {
            _ = rawExec("BEGIN")
            for id in ids {
                run("DELETE FROM documents WHERE id = ?", [.text(id)])
                run("DELETE FROM search WHERE doc_id = ?", [.text(id)])
                run("DELETE FROM indexed WHERE doc_id = ?", [.text(id)])
            }
            _ = rawExec("COMMIT")
        }
    }

    public func allDocuments() -> [DocumentItem] {
        lock.withLock {
            query("SELECT json FROM documents WHERE deleted = 0", []) { stmt in
                guard let blob = columnData(stmt, 0) else { return nil }
                return try? decoder.decode(DocumentItem.self, from: blob)
            }
        }
    }

    public func document(_ id: String) -> DocumentItem? {
        lock.withLock {
            query("SELECT json FROM documents WHERE id = ?", [.text(id)]) { stmt in
                columnData(stmt, 0).flatMap { try? decoder.decode(DocumentItem.self, from: $0) }
            }.first
        }
    }

    // MARK: Sync state

    public func value(_ key: String) -> String? { lock.withLock { scalarText("SELECT value FROM kv WHERE key = ?", [.text(key)]) } }

    public func setValue(_ value: String?, for key: String) {
        lock.withLock {
            if let value { run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .text(value)]) }
            else { run("DELETE FROM kv WHERE key = ?", [.text(key)]) }
        }
    }

    public func setPendingPosition(_ docID: String, page: Int) {
        lock.withLock { run("INSERT OR REPLACE INTO pending_positions (doc_id, page) VALUES (?, ?)", [.text(docID), .int(Int64(page))]) }
    }

    public func pendingPositions() -> [(String, Int)] {
        lock.withLock {
            query("SELECT doc_id, page FROM pending_positions", []) { stmt in
                (String(cString: sqlite3_column_text(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
            }
        }
    }

    public func clearPendingPosition(_ docID: String) {
        lock.withLock { run("DELETE FROM pending_positions WHERE doc_id = ?", [.text(docID)]) }
    }

    // MARK: Full-text index

    public func indexedHash(_ docID: String) -> String? {
        lock.withLock { scalarText("SELECT hash FROM indexed WHERE doc_id = ?", [.text(docID)]) }
    }

    public func setBody(_ body: String, for doc: DocumentItem) {
        lock.withLock {
            run("DELETE FROM search WHERE doc_id = ?", [.text(doc.id)])
            run("INSERT INTO search (doc_id, title, tags, body) VALUES (?, ?, ?, ?)",
                [.text(doc.id), .text(doc.name), .text(doc.tags.joined(separator: " ")), .text(body)])
            run("INSERT OR REPLACE INTO indexed (doc_id, hash) VALUES (?, ?)", [.text(doc.id), .text(doc.hash)])
        }
    }

    /// Prefix search across titles, tags and extracted text. Titles rank highest.
    public func search(_ text: String, limit: Int = 200) -> [SearchHit] {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " AND ")
        return lock.withLock {
            query("""
                SELECT doc_id, snippet(search, 3, '«', '»', '…', 12)
                FROM search WHERE search MATCH ? ORDER BY bm25(search, 0.0, 10.0, 5.0, 1.0) LIMIT ?
                """, [.text(match), .int(Int64(limit))]) { stmt in
                SearchHit(docID: String(cString: sqlite3_column_text(stmt, 0)),
                          snippet: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "")
            }
        }
    }

    // MARK: SQLite plumbing (call with lock held)

    enum Arg { case text(String), int(Int64), blob(Data) }

    private func exec(_ sql: String) throws {
        guard rawExec(sql) else { throw RMError.malformed(String(cString: sqlite3_errmsg(db))) }
    }

    @discardableResult
    private func rawExec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func prepare(_ sql: String, _ args: [Arg]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), transient) }
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: [Arg]) {
        guard let stmt = prepare(sql, args) else { return }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func query<T>(_ sql: String, _ args: [Arg], _ row: (OpaquePointer) -> T?) -> [T] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let v = row(stmt) { out.append(v) }
        }
        return out
    }

    private func scalarText(_ sql: String, _ args: [Arg]) -> String? {
        query(sql, args) { stmt in sqlite3_column_text(stmt, 0).map { String(cString: $0) } }.first
    }

    private func columnData(_ stmt: OpaquePointer, _ col: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, col)))
    }
}

// MARK: - Tasks

extension LibraryDatabase {
    public func allTasks() -> [TaskItem] {
        lock.withLock {
            query("SELECT json FROM tasks", []) { stmt in
                guard let blob = columnData(stmt, 0) else { return nil }
                return try? decoder.decode(TaskItem.self, from: blob)
            }
        }
    }

    /// Inserts new tasks; for ones already known (same fingerprint) only a source-side completion is applied,
    /// so completing a task on the Mac isn't undone by the next scan.
    public func mergeTasks(_ found: [TaskItem]) {
        lock.withLock {
            _ = rawExec("BEGIN")
            for var t in found {
                if let blob = query("SELECT json FROM tasks WHERE fingerprint = ?", [.text(t.fingerprint)], { columnData($0, 0) }).first,
                   var existing = try? decoder.decode(TaskItem.self, from: blob) {
                    guard t.isDone, !existing.isDone else { continue }
                    existing.completedAt = t.completedAt ?? .now
                    t = existing
                }
                guard let json = try? encoder.encode(t) else { continue }
                run("INSERT OR REPLACE INTO tasks (id, fingerprint, json) VALUES (?, ?, ?)", [.text(t.id), .text(t.fingerprint), .blob(json)])
            }
            _ = rawExec("COMMIT")
        }
    }

    public func saveTask(_ t: TaskItem) {
        lock.withLock {
            guard let json = try? encoder.encode(t) else { return }
            run("INSERT OR REPLACE INTO tasks (id, fingerprint, json) VALUES (?, ?, ?)", [.text(t.id), .text(t.fingerprint), .blob(json)])
        }
    }

    public func deleteTask(_ id: String) {
        lock.withLock { run("DELETE FROM tasks WHERE id = ?", [.text(id)]) }
    }

    public func wasScanned(_ key: String) -> Bool {
        lock.withLock { scalarText("SELECT key FROM scanned WHERE key = ?", [.text(key)]) != nil }
    }

    public func markScanned(_ keys: [String]) {
        lock.withLock {
            _ = rawExec("BEGIN")
            for k in keys { run("INSERT OR IGNORE INTO scanned (key) VALUES (?)", [.text(k)]) }
            _ = rawExec("COMMIT")
        }
    }
}

// MARK: - Search exclusions

extension LibraryDatabase {
    /// Documents and folders explicitly excluded from search body, OCR and tasks (folders apply to everything inside).
    public func explicitExclusions() -> Set<String> {
        guard let s = value("searchExclusions"), let ids = try? JSONDecoder().decode([String].self, from: Data(s.utf8)) else { return [] }
        return Set(ids)
    }

    public func setExcluded(_ id: String, _ excluded: Bool) {
        var ids = explicitExclusions()
        if excluded { ids.insert(id) } else { ids.remove(id) }
        if let d = try? JSONEncoder().encode(ids.sorted()) { setValue(String(decoding: d, as: UTF8.self), for: "searchExclusions") }
    }

    /// Clears everything derived from page contents so it's rebuilt: search bodies and task scan marks.
    public func resetIndexes() {
        lock.withLock {
            _ = rawExec("BEGIN")
            run("DELETE FROM indexed", [])
            run("UPDATE search SET body = ''", [])
            run("DELETE FROM scanned", [])
            _ = rawExec("COMMIT")
        }
    }
}

public enum SearchExclusions {
    /// Every document ID excluded explicitly or through an excluded ancestor folder.
    public static func expand(_ explicit: Set<String>, documents: [DocumentItem]) -> Set<String> {
        guard !explicit.isEmpty else { return [] }
        let parent = Dictionary(documents.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        var out = Set<String>()
        for d in documents {
            var cur: String? = d.id
            var steps = 0
            while let c = cur, !c.isEmpty, steps < 64 {
                if explicit.contains(c) { out.insert(d.id); break }
                cur = parent[c]
                steps += 1
            }
        }
        return out
    }

    /// True when every search token prefixes a word of the title (excluded documents match on title only).
    public static func titleMatches(_ title: String, query: String) -> Bool {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
    }
}

// MARK: - Retrieval for Ask

extension LibraryDatabase {
    /// Documents whose title, tags or text contain ANY of the tokens, best first (for question answering,
    /// where requiring every word would miss most matches).
    public func searchAny(_ tokens: [String], limit: Int = 12) -> [String] {
        let clean = tokens.map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return [] }
        let match = clean.map { "\"\($0)\"*" }.joined(separator: " OR ")
        return lock.withLock {
            query("SELECT doc_id FROM search WHERE search MATCH ? ORDER BY bm25(search, 0.0, 10.0, 5.0, 1.0) LIMIT ?",
                  [.text(match), .int(Int64(limit))]) { stmt in String(cString: sqlite3_column_text(stmt, 0)) }
        }
    }
}

extension LibraryDatabase {
    /// Indexed text of a document (typed notebook text or PDF text), if indexed.
    public func body(_ docID: String) -> String? {
        lock.withLock { scalarText("SELECT body FROM search WHERE doc_id = ?", [.text(docID)]) }
    }
}

// MARK: - Snapshots

/// A point-in-time version of the library: the cloud root after a sync (the web app's `snapshots`).
public struct LibrarySnapshot: Sendable, Identifiable, Equatable {
    public var id: String { rootHash }
    public let rootHash: String
    public let generation: Int
    public let documentCount: Int
    public let changed: Int
    public let date: Date
}

extension LibraryDatabase {
    /// Records the root and every document's hash. Only documents whose hash differs from the previous
    /// snapshot are stored again, so each snapshot costs about as many rows as it changed.
    public func recordSnapshot(rootHash: String, generation: Int, documents: [(id: String, hash: String)], changed: Int, at date: Date = .now) {
        lock.withLock {
            _ = rawExec("BEGIN")
            run("INSERT OR REPLACE INTO snapshots (root_hash, generation, doc_count, changed, created_at) VALUES (?, ?, ?, ?, ?)",
                [.text(rootHash), .int(Int64(generation)), .int(Int64(documents.count)), .int(Int64(changed)), .text(String(date.timeIntervalSince1970))])
            for d in documents {
                let last = scalarText("SELECT doc_hash FROM snapshot_docs WHERE doc_id = ? ORDER BY rowid DESC LIMIT 1", [.text(d.id)])
                if last != d.hash {
                    run("INSERT OR REPLACE INTO snapshot_docs (root_hash, doc_id, doc_hash) VALUES (?, ?, ?)", [.text(rootHash), .text(d.id), .text(d.hash)])
                }
            }
            _ = rawExec("COMMIT")
        }
    }

    public func snapshots(limit: Int = 50) -> [LibrarySnapshot] {
        lock.withLock {
            query("SELECT root_hash, generation, doc_count, changed, created_at FROM snapshots ORDER BY created_at DESC LIMIT ?", [.int(Int64(limit))]) { stmt in
                guard let hash = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return nil }
                let created = sqlite3_column_text(stmt, 4).flatMap { Double(String(cString: $0)) } ?? 0
                return LibrarySnapshot(rootHash: hash, generation: Int(sqlite3_column_int64(stmt, 1)), documentCount: Int(sqlite3_column_int64(stmt, 2)),
                                       changed: Int(sqlite3_column_int64(stmt, 3)), date: Date(timeIntervalSince1970: created))
            }
        }
    }

    /// When a document changed: (date, its hash then), newest first.
    public func versions(of docID: String) -> [(date: Date, hash: String)] {
        lock.withLock {
            query("SELECT s.created_at, d.doc_hash FROM snapshot_docs d JOIN snapshots s ON s.root_hash = d.root_hash WHERE d.doc_id = ? ORDER BY s.created_at DESC", [.text(docID)]) { stmt in
                guard let c = sqlite3_column_text(stmt, 0).flatMap({ Double(String(cString: $0)) }),
                      let h = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) else { return nil }
                return (Date(timeIntervalSince1970: c), h)
            }
        }
    }
}

// MARK: - Handwriting OCR

extension LibraryDatabase {
    /// Transcribed handwriting of one page version (keyed by its `.rm` hash); "" means read, nothing found.
    public func ocrText(_ rmHash: String) -> String? {
        lock.withLock { scalarText("SELECT text FROM ocr WHERE rm_hash = ?", [.text(rmHash)]) }
    }

    public func setOCRText(_ text: String, for rmHash: String) {
        lock.withLock { run("INSERT OR REPLACE INTO ocr (rm_hash, text) VALUES (?, ?)", [.text(rmHash), .text(text)]) }
    }

    public func ocrPageCount() -> Int {
        lock.withLock { Int(scalarText("SELECT COUNT(*) FROM ocr WHERE text != ''", []) ?? "0") ?? 0 }
    }
}
