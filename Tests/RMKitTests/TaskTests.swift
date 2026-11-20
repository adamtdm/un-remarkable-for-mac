import Foundation
import Testing
@testable import RMKit

@Suite("tasks")
struct TaskTests {
    @Test func typedRules() {
        let text = """
        Meeting notes
        * Send the deck to Rhys. Then lunch
        - [ ] Book the room
        [x] Draft agenda
        TODO: chase invoices
        Budget * confirm numbers * update e.g. the forecast.
        Just a sentence.
        """
        let found = TaskExtractor.extract(from: text)
        #expect(found == [
            .init(text: "Send the deck to Rhys.", done: false),
            .init(text: "Book the room", done: false),
            .init(text: "Draft agenda", done: true),
            .init(text: "chase invoices", done: false),
            .init(text: "confirm numbers", done: false),
            .init(text: "update e.g. the forecast.", done: false),
        ])
    }

    @Test func pastedMarkdownBulletsAreNotTasks() {
        let pasted = "# Shopping list\n" + (1...10).map { " * Item \($0) for the build." }.joined(separator: "\n") + "\n[ ] Order timber"
        #expect(TaskExtractor.extract(from: pasted, bulletAware: true) == [.init(text: "Order timber", done: false)])
        let indented = "Notes\n * a bullet point here\n* Real task. More text"
        #expect(TaskExtractor.extract(from: indented, bulletAware: true) == [.init(text: "Real task.", done: false)])
        // Without bullet awareness (handwriting OCR output) every * counts.
        #expect(TaskExtractor.extract(from: indented).count == 2)
    }

    @Test func nativeCheckboxParagraphsBecomeTasks() throws {
        let data = RmWriter.page(paragraphs: [.init("Plan", style: .heading), .init("Call Gonzalo", style: .checkbox), .init("Ship it", style: .checkboxChecked)])
        let page = try #require(RmParser.parse(data))
        #expect(TaskExtractor.extract(from: TaskExtractor.text(of: page)) == [.init(text: "Call Gonzalo", done: false), .init(text: "Ship it", done: true)])
    }

    @Test func meetingActionItemsForMeOnly() {
        let md = """
        ## Summary
        - [ ] Me: not an action (wrong section)
        ## Action items
        - [ ] Me: Send the budget to Finance (Friday)
        - [ ] Them: Book the review
        - [x] Me: Share slides
        ## Open questions
        - [ ] Me: ignored
        """
        #expect(TaskExtractor.meetingActions(md) == [.init(text: "Send the budget to Finance (Friday)", done: false), .init(text: "Share slides", done: true)])
    }

    @Test func visionReplyParsing() {
        let reply = "```json\n[{\"text\": \"Email Anje.\", \"status\": \"open\"}, {\"text\": \"Old\", \"status\": \"completed\"}, {\"text\": \" \"}]\n```"
        #expect(TaskExtractor.parseVision(reply) == [.init(text: "Email Anje.", done: false), .init(text: "Old", done: true)])
    }

    @Test func tasksNotebookLayoutAndTicks() throws {
        var tasks = (0..<25).map { TaskItem(text: "Task \($0)", source: .typed, docID: "d\($0 % 2)", docName: $0 % 2 == 0 ? "Alpha" : "Beta", pageIndex: 0) }
        tasks.append(TaskItem(text: "Captured one", source: .captured))
        tasks.append(TaskItem(text: "Done already", source: .captured, done: true))
        let pages = TasksNotebook.pages(title: "Tasks", tasks: tasks)
        #expect(pages.count == 2)
        #expect(pages.allSatisfy { $0.count <= TasksNotebook.linesPerPage + 1 })
        #expect(pages[0][0].text == "Tasks · 26 open · page 1/2")
        #expect(pages[0][1].text == "Captured" && pages[0][1].style == .bold)
        let all = pages.flatMap { $0 }.filter { $0.style == .checkbox }.map(\.text)
        #expect(all.count == 26 && !all.contains("Done already"))

        // Ticking a checkbox on the tablet is read back as done.
        var edited = pages[0]
        edited[2].style = .checkboxChecked
        let page = try #require(RmParser.parse(RmWriter.page(paragraphs: edited)))
        #expect(TasksNotebook.ticked(in: [page]) == [edited[2].text.lowercased()])
    }

    @Test func mergeKeepsMacCompletionAndAppliesSourceCompletion() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tasks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LibraryDatabase(url: dir.appending(path: "db.sqlite"))
        let open = TaskItem(text: "Call Rhys", source: .typed, docID: "d", docName: "N", pageIndex: 1)
        db.mergeTasks([open])
        var done = try #require(db.allTasks().first)
        done.completedAt = .now
        db.saveTask(done)                       // completed on the Mac
        db.mergeTasks([open])                   // rescan still sees it open on the page
        #expect(db.allTasks().first?.isDone == true)
        let other = TaskItem(text: "Email Anje", source: .typed, docID: "d", docName: "N", pageIndex: 1)
        db.mergeTasks([other])
        db.mergeTasks([TaskItem(text: "Email Anje", source: .typed, docID: "d", docName: "N", pageIndex: 1, done: true)])
        #expect(db.allTasks().first { $0.text == "Email Anje" }?.isDone == true)
        #expect(db.allTasks().count == 2)
    }
}

@Suite("search exclusions")
struct ExclusionTests {
    @Test func foldersExcludeEverythingInside() {
        let docs = [
            DocumentItem(id: "comics", name: "COMICS", kind: .folder),
            DocumentItem(id: "marvel", name: "Marvel", parent: "comics", kind: .folder),
            DocumentItem(id: "spidey", name: "Spider-Man", parent: "marvel", kind: .pdf),
            DocumentItem(id: "notes", name: "Notes", kind: .notebook),
            DocumentItem(id: "novel", name: "Neuromancer", kind: .epub),
        ]
        #expect(SearchExclusions.expand(["comics", "novel"], documents: docs) == ["comics", "marvel", "spidey", "novel"])
        #expect(SearchExclusions.expand([], documents: docs).isEmpty)
    }

    @Test func excludedDocumentsMatchOnTitleOnly() {
        #expect(SearchExclusions.titleMatches("The Complete Frank Miller Spider-Man", query: "spider frank"))
        #expect(SearchExclusions.titleMatches("Daily_Sudoku_2026-11-02.pdf", query: "sudo"))
        #expect(!SearchExclusions.titleMatches("Spider-Man", query: "budget"))
    }

    @Test func exclusionsPersist() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "excl-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LibraryDatabase(url: dir.appending(path: "db.sqlite"))
        db.setExcluded("a", true)
        db.setExcluded("b", true)
        db.setExcluded("a", false)
        #expect(db.explicitExclusions() == ["b"])
    }
}
