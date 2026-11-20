import Foundation
import Testing
@testable import RMKit

/// Writes to the real reMarkable cloud with the app's saved login. Off unless RMKIT_LIVE_CLOUD=1.
/// Creates two clearly named test notebooks, checks them by reading back from the cloud, then trashes them.
@Suite("live cloud", .serialized, .enabled(if: ProcessInfo.processInfo.environment["RMKIT_LIVE_CLOUD"] == "1"))
struct LiveCloudTests {
    @Test func createAppendVerifyAndTrash() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let engine = SyncEngine(client: CloudClient(auth: AuthManager()), blobs: BlobStore(root: tmp.appending(path: "blobs")),
                                db: try LibraryDatabase(url: tmp.appending(path: "lib.sqlite")))
        let before = try await engine.client.root()
        print("LIVE root before: \(before.hash) gen \(before.generation)")

        // 1. Typed notebook from Markdown, two pages.
        let md = "# Un-remarkable test\nCreated by the Mac app's writer test.\n- [ ] A checkbox\n- A bullet\n---\n## Page two\nPlain text."
        let nb = try await engine.createTypedNotebook(title: "Un-remarkable test (safe to delete)", markdown: md)
        print("LIVE created notebook \(nb.id) pages \(nb.pageCount)")

        // 2. Quick notes: first creates the notebook, second appends to it.
        let notesTitle = "Un-remarkable test notes (safe to delete)"
        let n1 = try await engine.appendNote("First note", toNotebookNamed: notesTitle)
        let n2 = try await engine.appendNote("Second note\n[ ] follow up", toNotebookNamed: notesTitle)
        #expect(n1.id == n2.id)

        // 3. Read back from the cloud with a fresh engine and database.
        let tmp2 = tmp.appending(path: "verify")
        try FileManager.default.createDirectory(at: tmp2, withIntermediateDirectories: true)
        let verify = SyncEngine(client: CloudClient(auth: AuthManager()), blobs: BlobStore(root: tmp2.appending(path: "blobs")),
                                db: try LibraryDatabase(url: tmp2.appending(path: "lib.sqlite")))
        _ = try await verify.sync { _ in }
        let docs = verify.db.allDocuments()
        let gotNotebook = try #require(docs.first { $0.id == nb.id })
        #expect(gotNotebook.name == "Un-remarkable test (safe to delete)")
        #expect(gotNotebook.kind == .notebook && gotNotebook.pageCount == 2)
        let page1 = try #require(gotNotebook.rmFile(for: 0))
        let parsed1 = try #require(RmParser.parse(try await verify.blob(page1.hash, filename: page1.name)))
        #expect(parsed1.paragraphs.map(\.style) == [.heading, .plain, .checkbox, .bullet])

        let gotNotes = try #require(docs.first { $0.id == n1.id })
        let notesPage = try #require(gotNotes.rmFile(for: 0))
        let notesText = try #require(RmParser.parse(try await verify.blob(notesPage.hash, filename: notesPage.name))).paragraphs.map(\.text)
        print("LIVE notes text: \(notesText)")
        #expect(notesText.contains("First note") && notesText.contains("Second note") && notesText.contains("follow up"))
        let after = try await verify.client.root()
        print("LIVE root after: \(after.hash) gen \(after.generation), documents \(docs.count)")

        // 4. Append pages after the notebook's pages, then replace them (as meeting notes do).
        let (_, added) = try await engine.appendPages(docID: nb.id, pages: [[.init("AI notes", style: .heading), .init("First")], [.init("Second page")]])
        let (_, replaced) = try await engine.appendPages(docID: nb.id, pages: [[.init("Rewritten notes", style: .heading)]], replacing: added)
        _ = try await verify.sync { _ in }
        let after2 = try #require(verify.db.document(nb.id))
        #expect(after2.pages.map(\.pageID).suffix(1) == replaced)
        #expect(after2.pageCount == 3)
        let lastPage = try #require(after2.rmFile(for: 2))
        let lastText = try #require(RmParser.parse(try await verify.blob(lastPage.hash, filename: lastPage.name))).paragraphs.map(\.text)
        print("LIVE appended pages: \(after2.pages.count), last page text \(lastText)")
        #expect(lastText == ["Rewritten notes"])

        // 5. Edit page 1's typed text as the reader's editor does: read it as Markdown, change it, save.
        let original = TypedNotebook.markdown(from: parsed1)
        print("LIVE page 1 as Markdown:\n\(original)")
        let edited = original.replacingOccurrences(of: "A checkbox", with: "A ticked checkbox")
            .replacingOccurrences(of: "- [ ]", with: "- [x]") + "\n- Added from the Mac editor"
        _ = try await engine.replacePageText(docID: nb.id, page: 0, markdown: edited)
        _ = try await verify.sync { _ in }
        let after3 = try #require(verify.db.document(nb.id))
        let editedFile = try #require(after3.rmFile(for: 0))
        let reread = try #require(RmParser.parse(try await verify.blob(editedFile.hash, filename: editedFile.name)))
        print("LIVE page 1 after edit:\n\(TypedNotebook.markdown(from: reread))")
        #expect(TypedNotebook.markdown(from: reread) == edited)
        #expect(after3.pageCount == 3) // other pages untouched

        // 6. Clean up: move both to the tablet's Trash.
        try await engine.trash(nb.id)
        try await engine.trash(n1.id)
        print("LIVE trashed test notebooks")
    }
}
