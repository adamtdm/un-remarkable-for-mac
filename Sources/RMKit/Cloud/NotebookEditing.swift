import Foundation

/// Writing typed notebooks to the tablet, like the web app's `NotebookEditor`.
extension SyncEngine {
    /// Creates a typed notebook from Markdown (`---` separates pages) and returns it.
    @discardableResult
    public func createTypedNotebook(title: String, markdown: String, parentID: String = "") async throws -> DocumentItem {
        let id = UUID().uuidString.lowercased()
        let pages = TypedNotebook.pages(fromMarkdown: markdown)
        return try await putDocument(id, files: TypedNotebook.files(docID: id, title: title, parentID: parentID, pages: pages))
    }

    /// Rebuilds a notebook in place under the same ID (for generated notebooks such as Tasks).
    @discardableResult
    public func replaceTypedNotebook(id: String, title: String, pages: [[RmWriter.Paragraph]], parentID: String = "") async throws -> DocumentItem {
        try await putDocument(id, files: TypedNotebook.files(docID: id, title: title, parentID: parentID, pages: pages))
    }

    /// Appends a dated entry to the first page of a notebook, creating the notebook if needed.
    /// Only the page's typed text is rewritten; handwriting on it and the other pages are kept.
    @discardableResult
    public func appendNote(_ text: String, toNotebookNamed title: String, parentID: String = "", now: Date = .now) async throws -> DocumentItem {
        let stamp = now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let entry: [RmWriter.Paragraph] = [RmWriter.Paragraph("", style: .plain), .init(stamp, style: .bold)]
            + TypedNotebook.pages(fromMarkdown: text).flatMap { $0 }

        let existing = db.allDocuments().first { !$0.isTrashed && $0.kind == .notebook && $0.name == title }
        guard let doc = existing else {
            let id = UUID().uuidString.lowercased()
            let page = [RmWriter.Paragraph(title, style: .heading)] + entry
            return try await putDocument(id, files: TypedNotebook.files(docID: id, title: title, parentID: parentID, pages: [page]))
        }

        // Current cloud state of the document, so edits made on the tablet since the last sync are kept.
        let root = try await client.root()
        let (rootEntries, _) = try IndexParser.parse(try await blob(root.hash, filename: "root.docSchema"))
        guard let docEntry = rootEntries.first(where: { $0.id == doc.id }) else {
            throw RMError.notFound("\(title) is no longer in the cloud")
        }
        let (subfiles, _) = try IndexParser.parse(try await blob(docEntry.hash, filename: "\(doc.id).docSchema"))
        let contentEntry = subfiles.first { $0.id.hasSuffix(".content") }
        var content: Data?
        if let e = contentEntry { content = try await blob(e.hash, filename: e.id) }
        let firstPageID = DocumentMetadata.parsePages(content.flatMap { jsonObject($0) } ?? [:]).first?.pageID

        var files: [TypedNotebook.File] = []
        if let pageID = firstPageID, let rmEntry = subfiles.first(where: { $0.id == "\(doc.id)/\(pageID).rm" }) {
            let old = try await blob(rmEntry.hash, filename: rmEntry.id)
            // Append like the tablet does (existing text keeps its IDs, so handwriting anchored to it stays put);
            // pages with no typed text yet get a text block.
            let data = RmWriter.appendingText(to: old, paragraphs: entry) ?? {
                let current = RmParser.parse(old).map(TypedNotebook.paragraphs(from:)) ?? []
                return RmWriter.replacingText(in: old, paragraphs: current + entry)
            }()
            files.append(.init(name: rmEntry.id, data: data))
        } else if let pageID = firstPageID {
            // Page without a file yet (never written on): create it.
            files.append(.init(name: "\(doc.id)/\(pageID).rm", data: RmWriter.page(paragraphs: [.init(title, style: .heading)] + entry)))
        } else {
            throw RMError.malformed("\(title) has no pages")
        }
        if let metaEntry = subfiles.first(where: { $0.id.hasSuffix(".metadata") }),
           var meta = jsonObject(try await blob(metaEntry.hash, filename: metaEntry.id)) {
            meta["lastModified"] = String(Int64(now.timeIntervalSince1970 * 1000))
            files.append(.init(name: metaEntry.id, data: try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])))
        }
        return try await putDocument(doc.id, files: files, keeping: subfiles)
    }
}

extension SyncEngine {
    /// Replaces the typed text of one page (Markdown), keeping its handwriting. Works on notebooks.
    @discardableResult
    public func replacePageText(docID: String, page: Int, markdown: String) async throws -> DocumentItem {
        guard let doc = db.document(docID), doc.kind == .notebook else { throw RMError.notFound("No notebook \(docID)") }
        guard doc.pages.indices.contains(page) else { throw RMError.notFound("\(doc.name) has no page \(page + 1)") }
        let root = try await client.root()
        let (rootEntries, _) = try IndexParser.parse(try await blob(root.hash, filename: "root.docSchema"))
        guard let docEntry = rootEntries.first(where: { $0.id == docID }) else { throw RMError.notFound("\(doc.name) is no longer in the cloud") }
        let (subfiles, _) = try IndexParser.parse(try await blob(docEntry.hash, filename: "\(docID).docSchema"))
        let name = "\(docID)/\(doc.pages[page].pageID).rm"
        let paragraphs = TypedNotebook.pages(fromMarkdown: markdown).flatMap { $0 }
        let data: Data
        if let e = subfiles.first(where: { $0.id == name }) {
            data = RmWriter.replacingText(in: try await blob(e.hash, filename: e.id), paragraphs: paragraphs)
        } else {
            data = RmWriter.page(paragraphs: paragraphs)
        }
        var files = [TypedNotebook.File(name: name, data: data)]
        if let metaEntry = subfiles.first(where: { $0.id.hasSuffix(".metadata") }),
           var meta = jsonObject(try await blob(metaEntry.hash, filename: metaEntry.id)) {
            meta["lastModified"] = String(Int64(Date().timeIntervalSince1970 * 1000))
            files.append(.init(name: metaEntry.id, data: try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])))
        }
        return try await putDocument(docID, files: files, keeping: subfiles)
    }
}

extension SyncEngine {
    /// Adds typed pages after the last page of an existing notebook (e.g. AI meeting notes below the
    /// meeting page's handwriting). Pages from an earlier call can be replaced by passing their IDs.
    /// Returns the updated document and the new page IDs.
    public func appendPages(docID: String, pages: [[RmWriter.Paragraph]], replacing old: [String] = []) async throws -> (DocumentItem, [String]) {
        let root = try await client.root()
        let (rootEntries, _) = try IndexParser.parse(try await blob(root.hash, filename: "root.docSchema"))
        guard let docEntry = rootEntries.first(where: { $0.id == docID }) else { throw RMError.notFound("That notebook is no longer in the cloud") }
        let (subfiles, _) = try IndexParser.parse(try await blob(docEntry.hash, filename: "\(docID).docSchema"))
        guard let contentEntry = subfiles.first(where: { $0.id.hasSuffix(".content") }) else { throw RMError.malformed("Notebook has no content file") }
        let ids = pages.map { _ in UUID().uuidString.lowercased() }
        var files = [TypedNotebook.File(name: contentEntry.id, data: try TypedNotebook.appendingPages(
            to: try await blob(contentEntry.hash, filename: contentEntry.id), newPageIDs: ids, removing: old))]
        for (id, paragraphs) in zip(ids, pages) {
            files.append(.init(name: "\(docID)/\(id).rm", data: RmWriter.page(paragraphs: paragraphs)))
        }
        if let metaEntry = subfiles.first(where: { $0.id.hasSuffix(".metadata") }),
           var meta = jsonObject(try await blob(metaEntry.hash, filename: metaEntry.id)) {
            meta["lastModified"] = String(Int64(Date().timeIntervalSince1970 * 1000))
            files.append(.init(name: metaEntry.id, data: try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])))
        }
        // Drop the .rm files of replaced pages; the page list marks them deleted.
        let removedFiles = Set(old.map { "\(docID)/\($0).rm" })
        let doc = try await putDocument(docID, files: files, keeping: subfiles.filter { !removedFiles.contains($0.id) })
        return (doc, ids)
    }
}

/// Library organisation: move, rename, trash and restore, by editing the document's `.metadata`.
extension SyncEngine {
    public func move(_ docID: String, to parentID: String) async throws {
        try await editMetadata(docID) { $0["parent"] = parentID }
    }

    public func rename(_ docID: String, to name: String) async throws {
        try await editMetadata(docID) { $0["visibleName"] = name }
    }

    /// Moves to the tablet's Trash (recoverable there, like deleting on the tablet).
    public func trash(_ docID: String) async throws {
        try await editMetadata(docID) { $0["parent"] = "trash" }
    }

    public func setPinned(_ docID: String, _ pinned: Bool) async throws {
        try await editMetadata(docID) { $0["pinned"] = pinned }
    }

    func editMetadata(_ docID: String, _ change: @escaping @Sendable (inout [String: Any]) -> Void) async throws {
        try await mutateDocument(docID) { name, data in
            guard name.hasSuffix(".metadata"), var obj = jsonObject(data) else { return nil }
            change(&obj)
            obj["lastModified"] = String(Int64(Date().timeIntervalSince1970 * 1000))
            obj["metadatamodified"] = true
            return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        }
        // Refresh the local record from what was just written.
        if let doc = db.document(docID), let metaHash = doc.subfiles["\(docID).metadata"],
           let meta = try? await blob(metaHash, filename: "\(docID).metadata") {
            var updated = doc
            let parsed = DocumentMetadata.parse(metadata: meta, content: nil)
            updated.name = parsed.visibleName
            updated.parent = parsed.parent
            updated.pinned = parsed.pinned
            updated.lastModified = parsed.lastModified ?? .now
            db.upsert([updated])
        }
    }
}
