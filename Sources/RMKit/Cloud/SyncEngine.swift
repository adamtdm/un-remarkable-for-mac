import Foundation

public struct SyncProgress: Sendable, Equatable {
    public var stage: String
    public var done: Int
    public var total: Int
    public var message: String

    public init(stage: String, done: Int = 0, total: Int = 0, message: String = "") {
        self.stage = stage
        self.done = done
        self.total = total
        self.message = message
    }

    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

public enum SyncOutcome: Sendable, Equatable {
    case upToDate
    case synced(changed: Int, total: Int)
}

/// Pulls the sync15 tree into the local library and pushes small edits (reading position) back.
///
/// Only `.docSchema`, `.metadata` and `.content` are fetched during sync; page payloads (`.rm`, `.pdf`,
/// `.epub`) are downloaded on demand by the reader and cached in the blob store.
public actor SyncEngine {
    nonisolated public let client: CloudClient
    nonisolated public let blobs: BlobStore
    nonisolated public let db: LibraryDatabase
    private let maxConcurrency: Int
    private var inFlight: [String: Task<Data, Error>] = [:]

    public init(client: CloudClient, blobs: BlobStore, db: LibraryDatabase, maxConcurrency: Int = 6) {
        self.client = client
        self.blobs = blobs
        self.db = db
        self.maxConcurrency = maxConcurrency
    }

    // MARK: Pull

    public func sync(progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }) async throws -> SyncOutcome {
        for (docID, page) in db.pendingPositions() {
            try? await pushPosition(docID: docID, page: page)
        }

        progress(SyncProgress(stage: "Connecting", message: "Checking the cloud for changes…"))
        let root = try await client.root()
        if db.value("rootHash") == root.hash {
            progress(SyncProgress(stage: "Up to date", done: 1, total: 1))
            return .upToDate
        }

        progress(SyncProgress(stage: "Library index", message: "Downloading the library index…"))
        let (entries, _) = try IndexParser.parse(try await blob(root.hash, filename: "root.docSchema"))
        let docEntries = entries.filter(\.isDocument)
        let existing = Dictionary(db.allDocuments().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changed = docEntries.filter { existing[$0.id]?.hash != $0.hash }

        var updated: [DocumentItem] = []
        var done = 0
        try await withThrowingTaskGroup(of: DocumentItem?.self) { group in
            var iterator = changed.makeIterator()
            func addNext() {
                guard let e = iterator.next() else { return }
                group.addTask { try? await self.fetchDocument(id: e.id, hash: e.hash, previous: existing[e.id]) }
            }
            for _ in 0..<maxConcurrency { addNext() }
            while let result = try await group.next() {
                if let item = result { updated.append(item) }
                done += 1
                progress(SyncProgress(stage: "Syncing library", done: done, total: changed.count,
                                      message: "Updated \(done) of \(changed.count) changed items"))
                if updated.count >= 50 { db.upsert(updated); updated.removeAll() }
                addNext()
            }
        }
        db.upsert(updated)

        let remoteIDs = Set(docEntries.map(\.id))
        db.remove(ids: existing.keys.filter { !remoteIDs.contains($0) })
        db.recordSnapshot(rootHash: root.hash, generation: Int(root.generation), documents: docEntries.map { ($0.id, $0.hash) }, changed: changed.count)
        db.setValue(root.hash, for: "rootHash")
        db.setValue(String(root.generation), for: "rootGeneration")
        db.setValue(ISO8601DateFormatter().string(from: .now), for: "lastSync")
        progress(SyncProgress(stage: "Complete", done: 1, total: 1, message: "Library is up to date."))
        return .synced(changed: changed.count, total: docEntries.count)
    }

    private func fetchDocument(id: String, hash: String, previous: DocumentItem?) async throws -> DocumentItem {
        let (subfiles, _) = try IndexParser.parse(try await blob(hash, filename: "\(id).docSchema"))
        let metaEntry = subfiles.first { $0.id.hasSuffix(".metadata") }
        let contentEntry = subfiles.first { $0.id.hasSuffix(".content") }
        var metaData: Data?, contentData: Data?
        if let e = metaEntry { metaData = try await blob(e.hash, filename: e.id) }
        if let e = contentEntry { contentData = try await blob(e.hash, filename: e.id) }
        let meta = DocumentMetadata.parse(metadata: metaData, content: contentData)
        let kind = FileKind(rawFileType: meta.fileType, isFolder: meta.isFolder)
        return DocumentItem(
            id: id,
            name: meta.visibleName.isEmpty ? id : meta.visibleName,
            parent: meta.parent,
            kind: kind,
            pageCount: meta.pageCount,
            pinned: meta.pinned,
            deleted: meta.deleted,
            lastModified: meta.lastModified ?? previous?.lastModified ?? .now,
            lastOpened: meta.lastOpened,
            lastOpenedPage: meta.lastOpenedPage,
            tags: meta.tags,
            hash: hash,
            subfiles: Dictionary(subfiles.map { ($0.id, $0.hash) }, uniquingKeysWith: { a, _ in a }),
            pages: meta.pages
        )
    }

    // MARK: Blobs

    /// Returns a blob from the local store, downloading it once (concurrent callers share the download).
    public func blob(_ hash: String, filename: String) async throws -> Data {
        if let d = blobs.get(hash) { return d }
        if let t = inFlight[hash] { return try await t.value }
        let client = self.client
        let blobs = self.blobs
        let task = Task<Data, Error> {
            let data = try await client.blob(hash, filename: filename)
            try blobs.put(hash, data: data)
            return data
        }
        inFlight[hash] = task
        defer { inFlight[hash] = nil }
        return try await task.value
    }

    // MARK: Push

    /// Records the reading position locally and pushes it to the tablet (best effort, retried on next sync).
    public func setReadingPosition(docID: String, page: Int) async {
        db.setPendingPosition(docID, page: page)
        try? await pushPosition(docID: docID, page: page)
    }

    func pushPosition(docID: String, page: Int) async throws {
        try await mutateDocument(docID) { name, data in
            guard var obj = jsonObject(data) else { return nil }
            let now = String(Int64(Date.now.timeIntervalSince1970 * 1000))
            if name.hasSuffix(".metadata") {
                obj["lastOpenedPage"] = page
                obj["lastOpened"] = now
            } else if name.hasSuffix(".content") {
                guard var cPages = obj["cPages"] as? [String: Any] else { return nil }
                let pages = DocumentMetadata.parsePages(obj)
                guard pages.indices.contains(page) else { return nil }
                cPages["lastOpened"] = ["value": pages[page].pageID, "timestamp": "1:\(page + 1)"]
                obj["cPages"] = cPages
            } else {
                return nil
            }
            return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        }
        db.clearPendingPosition(docID)
        if var doc = db.document(docID) {
            doc.lastOpenedPage = page
            doc.lastOpened = .now
            db.upsert([doc])
        }
    }

    /// Rewrites selected subfiles of one document and publishes a new root, retrying if another
    /// device moves the root generation underneath us.
    func mutateDocument(_ docID: String, _ transform: @Sendable (String, Data) throws -> Data?) async throws {
        for attempt in 1...3 {
            let root = try await client.root()
            let (rootEntries, rootSchema) = try IndexParser.parse(try await blob(root.hash, filename: "root.docSchema"))
            guard let docEntry = rootEntries.first(where: { $0.id == docID }) else {
                throw RMError.notFound("Document \(docID) is no longer in the cloud")
            }
            let (subfiles, docSchema) = try IndexParser.parse(try await blob(docEntry.hash, filename: "\(docID).docSchema"))

            var newSubfiles = subfiles
            for (i, e) in subfiles.enumerated() where e.id.hasSuffix(".metadata") || e.id.hasSuffix(".content") {
                let old = try await blob(e.hash, filename: e.id)
                guard let new = try transform(e.id, old) else { continue }
                let h = sha256Hex(new)
                try await client.putBlob(h, data: new, filename: e.id)
                try blobs.put(h, data: new)
                newSubfiles[i].hash = h
                newSubfiles[i].size = Int64(new.count)
            }
            if newSubfiles == subfiles { return }

            let (docData, docHash) = IndexParser.buildDocSchema(newSubfiles, schema: docSchema, docID: docID)
            try await client.putBlob(docHash, data: docData, filename: "\(docID).docSchema", contentType: "text/plain; charset=UTF-8")
            try blobs.put(docHash, data: docData)

            let newRoot = rootEntries.map { e in
                e.id == docID
                    ? Entry(hash: docHash, type: e.type, id: e.id, subfiles: newSubfiles.count, size: newSubfiles.reduce(0) { $0 + $1.size })
                    : e
            }
            let rootData = IndexParser.format(newRoot, schema: rootSchema, owner: ".")
            let rootHash = sha256Hex(rootData)
            try await client.putBlob(rootHash, data: rootData, filename: "root.docSchema", contentType: "text/plain; charset=UTF-8")
            try blobs.put(rootHash, data: rootData)
            do {
                let gen = try await client.updateRoot(hash: rootHash, generation: root.generation)
                // Only adopt the new root locally if we were already in sync with the previous one.
                if db.value("rootHash") == root.hash {
                    db.setValue(rootHash, for: "rootHash")
                    db.setValue(String(gen), for: "rootGeneration")
                }
                if var doc = db.document(docID) {
                    doc.hash = docHash
                    for e in newSubfiles { doc.subfiles[e.id] = e.hash }
                    db.upsert([doc])
                }
                return
            } catch RMError.http(412, _) where attempt < 3 {
                continue // generation moved; rebuild against the new root
            }
        }
    }

    /// Creates or replaces a whole document in the cloud: uploads its files, writes its index and points
    /// the root at it (retrying if the root moved meanwhile). The document is also added to the local
    /// library straight away. Used for typed notebooks, Quick Notes, Tasks and folders.
    @discardableResult
    public func putDocument(_ docID: String, files: [TypedNotebook.File], keeping kept: [Entry] = []) async throws -> DocumentItem {
        // Files already in the cloud and unchanged are referenced as they are.
        let replaced = Set(files.map(\.name))
        var entries: [Entry] = kept.filter { !replaced.contains($0.id) }
        for f in files {
            let h = sha256Hex(f.data)
            if !blobs.has(h) { try blobs.put(h, data: f.data) }
            try await client.putBlob(h, data: f.data, filename: f.name)
            entries.append(Entry(hash: h, type: Entry.fileType, id: f.name, subfiles: 0, size: Int64(f.data.count)))
        }
        let (docData, docHash) = IndexParser.buildDocSchema(entries, schema: Entry.schemaV4, docID: docID)
        try await client.putBlob(docHash, data: docData, filename: "\(docID).docSchema", contentType: "text/plain; charset=UTF-8")
        try blobs.put(docHash, data: docData)

        for attempt in 1...4 {
            let root = try await client.root()
            let (rootEntries, rootSchema) = try IndexParser.parse(try await blob(root.hash, filename: "root.docSchema"))
            let entry = Entry(hash: docHash, type: Entry.fileType, id: docID, subfiles: entries.count,
                              size: entries.reduce(0) { $0 + $1.size })
            let newRoot = rootEntries.filter { $0.id != docID } + [entry]
            let rootData = IndexParser.format(newRoot, schema: rootSchema, owner: ".")
            let rootHash = sha256Hex(rootData)
            try await client.putBlob(rootHash, data: rootData, filename: "root.docSchema", contentType: "text/plain; charset=UTF-8")
            try blobs.put(rootHash, data: rootData)
            do {
                let gen = try await client.updateRoot(hash: rootHash, generation: root.generation)
                if db.value("rootHash") == root.hash {
                    db.setValue(rootHash, for: "rootHash")
                    db.setValue(String(gen), for: "rootGeneration")
                }
                break
            } catch RMError.http(412, _) where attempt < 4 {
                continue
            }
        }

        let doc = try await fetchDocument(id: docID, hash: docHash, previous: db.document(docID))
        db.upsert([doc])
        return doc
    }

    /// Creates a folder (a "CollectionType" document) and returns it.
    @discardableResult
    public func createFolder(name: String, parentID: String = "") async throws -> DocumentItem {
        let id = UUID().uuidString.lowercased()
        let ms = String(Int64(Date().timeIntervalSince1970 * 1000))
        let meta: [String: Any] = [
            "createdTime": ms, "lastModified": ms, "new": true, "parent": parentID, "pinned": false,
            "source": "", "type": "CollectionType", "visibleName": name,
        ]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        return try await putDocument(id, files: [TypedNotebook.File(name: "\(id).metadata", data: data)])
    }

    /// Uploads a PDF or EPUB into a folder. It appears in the library on the next sync.
    @discardableResult
    public func upload(fileURL: URL, parentID: String = "") async throws -> String? {
        let data = try Data(contentsOf: fileURL)
        return try await client.uploadDocument(data, filename: fileURL.lastPathComponent, parentID: parentID)
    }

    @discardableResult
    public func upload(data: Data, filename: String, parentID: String = "") async throws -> String? {
        try await client.uploadDocument(data, filename: filename, parentID: parentID)
    }
}
