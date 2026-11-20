import Foundation
import Observation
import RMKit
import SwiftUI

/// "Operate as a server": the web server's background features (MCP, daily delivery, full-text indexing,
/// the Tasks notebook). Off, the app is a plain reMarkable sync client with the reader, meetings and writing.
enum ServerMode {
    static let key = "serverMode"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// A server feature runs only when server mode is on and the feature itself is switched on.
    static func enabled(_ featureKey: String, default fallback: Bool = true) -> Bool {
        guard isOn else { return false }
        return UserDefaults.standard.object(forKey: featureKey) as? Bool ?? fallback
    }

    /// Installs from before server mode existed keep running as they did (MCP, indexing, Tasks notebook);
    /// new installs start as a plain sync client.
    @MainActor static func migrate() {
        let d = UserDefaults.standard
        guard d.object(forKey: key) == nil else { return }
        // Any saved preference (window frames, theme, AI settings…) means the app has run before.
        let existing = !(d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.unremarkable.mac") ?? [:]).isEmpty
        d.set(existing, forKey: key)
    }

    /// Applies a change of the master switch or a feature toggle to the running services.
    @MainActor static func apply() {
        MCPService.shared.restart()
        let model = AppModel.shared
        if enabled("indexNotebookText") { Task { await model.indexText(); await model.readHandwriting() } }
        if enabled("tasksNotebookEnabled") { Task { await TasksModel.shared.refresh() } }
        DeliveryService.shared.checkSchedule()
    }
}

/// Daily newspaper and puzzles, delivered once a day after their set time into tablet folders, like the web
/// app's `DeliveryManager`. Checked after each sync, so it catches up when the Mac wakes.
@MainActor @Observable
final class DeliveryService {
    static let shared = DeliveryService()

    enum Kind: String { case news, puzzles }

    private(set) var running: Kind?
    private(set) var status: [Kind: String] = [:]

    @ObservationIgnored @AppStorage("deliveryNewsEnabled") var newsEnabled = false
    @ObservationIgnored @AppStorage("deliveryNewsFolder") var newsFolder = "Daily News"
    @ObservationIgnored @AppStorage("deliveryNewsTime") var newsTime = 6 * 60
    @ObservationIgnored @AppStorage("deliveryNewsFeeds") var newsFeeds = NewsFeeds.defaults.joined(separator: "\n")
    @ObservationIgnored @AppStorage("deliveryArticlesPerFeed") var articlesPerFeed = 2
    @ObservationIgnored @AppStorage("deliveryWikipedia") var wikipedia = true
    @ObservationIgnored @AppStorage("deliveryWeather") var weather = true
    @ObservationIgnored @AppStorage("deliveryWeatherLocation") var weatherLocation = ""
    @ObservationIgnored @AppStorage("deliveryImages") var images = false
    @ObservationIgnored @AppStorage("deliveryPuzzlesEnabled") var puzzlesEnabled = false
    @ObservationIgnored @AppStorage("deliveryPuzzlesFolder") var puzzlesFolder = "Puzzles"
    @ObservationIgnored @AppStorage("deliveryPuzzlesTime") var puzzlesTime = 6 * 60
    @ObservationIgnored @AppStorage("deliveryQuick") var quick = true
    @ObservationIgnored @AppStorage("deliveryCryptic") var cryptic = true
    @ObservationIgnored @AppStorage("deliverySudoku") var sudoku = true
    @ObservationIgnored @AppStorage("deliverySudokuDifficulty") var sudokuDifficulty = "medium"
    @ObservationIgnored @AppStorage("deliveryLastNews") var lastNews = ""
    @ObservationIgnored @AppStorage("deliveryLastPuzzles") var lastPuzzles = ""

    private var model: AppModel { .shared }

    static func dayStamp(_ date: Date = .now) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func minutesNow(_ date: Date = .now) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return c.hour! * 60 + c.minute!
    }

    /// Whether a delivery is due: switched on, not yet delivered today, and the time has come.
    static func isDue(enabled: Bool, last: String, time: Int, now: Date = .now) -> Bool {
        enabled && last != dayStamp(now) && minutesNow(now) >= time
    }

    func checkSchedule() {
        guard ServerMode.isOn, model.isPaired, running == nil else { return }
        // Development runs (snapshot hook) never deliver on schedule; "Deliver Now" still works.
        guard ProcessInfo.processInfo.environment["UNREMARKABLE_SNAPSHOT_DIR"] == nil else { return }
        if Self.isDue(enabled: newsEnabled, last: lastNews, time: newsTime) {
            Task { await deliver(.news) }
        } else if Self.isDue(enabled: puzzlesEnabled, last: lastPuzzles, time: puzzlesTime) {
            Task { await deliver(.puzzles) }
        }
    }

    /// Generates and uploads one delivery now (manual "Deliver Now" or the schedule).
    func deliver(_ kind: Kind) async {
        guard model.isPaired, running == nil else { return }
        running = kind
        status[kind] = kind == .news ? "Fetching articles…" : "Fetching puzzles…"
        defer { running = nil }
        do {
            let summary = kind == .news ? try await deliverNews() : try await deliverPuzzles()
            if kind == .news { lastNews = Self.dayStamp() } else { lastPuzzles = Self.dayStamp() }
            status[kind] = "\(summary) at \(Date.now.formatted(date: .omitted, time: .shortened))"
            model.addLog(summary + ".")
        } catch {
            status[kind] = "Failed: \(error.localizedDescription)"
            model.addLog("\(kind == .news ? "Newspaper" : "Puzzles") delivery failed: \(error.localizedDescription)", isError: true)
        }
        await model.syncNow(quiet: true)
        checkSchedule() // the other delivery may be due too
    }

    private func deliverNews() async throws -> String {
        var options = Newspaper.Options()
        options.feeds = newsFeeds.split(whereSeparator: \.isNewline).map(String.init)
        options.articlesPerFeed = max(1, min(articlesPerFeed, 10))
        options.includeWikipedia = wikipedia
        options.includeWeather = weather
        options.weatherLocation = weatherLocation
        options.includeImages = images
        options.device = .current
        let paper = await Newspaper.generate(options)
        status[.news] = "Uploading \(paper.articles) articles…"
        let folder = try await ensureFolder(newsFolder)
        _ = try await model.sync.upload(data: paper.pdf, filename: paper.filename, parentID: folder)
        return "Delivered The Morning Chronicle (\(paper.articles) article\(paper.articles == 1 ? "" : "s")) to \(newsFolder)"
    }

    private func deliverPuzzles() async throws -> String {
        var files: [(Data, String)] = []
        var failures: [String] = []
        for (on, type) in [(quick, "quick"), (cryptic, "cryptic")] where on {
            do { files.append(try await DailyPuzzles.guardianCrossword(type)) } catch { failures.append("\(type) crossword") }
        }
        if sudoku { files.append(DailyPuzzles.sudoku(difficulty: sudokuDifficulty, device: .current)) }
        guard !files.isEmpty else { throw RMError.notFound(failures.isEmpty ? "No puzzles are switched on" : "Couldn't fetch the \(failures.joined(separator: " or "))") }
        status[.puzzles] = "Uploading \(files.count) puzzle\(files.count == 1 ? "" : "s")…"
        let folder = try await ensureFolder(puzzlesFolder)
        for (data, name) in files {
            _ = try await model.sync.upload(data: data, filename: name, parentID: folder)
        }
        return "Delivered \(files.count) puzzle\(files.count == 1 ? "" : "s") to \(puzzlesFolder)" + (failures.isEmpty ? "" : " (no \(failures.joined(separator: ", ")) today)")
    }

    /// A top-level folder with this name (any case), created if missing.
    private func ensureFolder(_ name: String) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Deliveries" : name.trimmingCharacters(in: .whitespaces)
        if let f = model.documents.first(where: { $0.isFolder && !$0.isTrashed && $0.parent.isEmpty && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return f.id
        }
        let folder = try await model.sync.createFolder(name: name, parentID: "")
        model.documents = model.db.allDocuments()
        return folder.id
    }
}
