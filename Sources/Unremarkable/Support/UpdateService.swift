import AppKit
import CryptoKit
import Foundation
import Observation
import RMKit
import Security
import SwiftUI

/// In-app updates from the Un-remarkable download page. `scripts/publish.sh` writes `mac-version.json` next to
/// the zip; the app checks it, downloads the zip, verifies its SHA-256 and that it's signed by the same
/// certificate as this copy, then swaps the app bundle and relaunches.
@MainActor @Observable
final class UpdateService {
    static let shared = UpdateService()
    /// The feed this build was made for (DOWNLOAD_URL in config.local.env at build time); empty turns updates off.
    nonisolated static let defaultFeed = (Bundle.main.object(forInfoDictionaryKey: "UnremarkableUpdateFeed") as? String) ?? ""

    struct Release: Codable, Equatable, Sendable {
        var version: String
        var date: String
        var commit: String
        var size: Int
        var sha256: String
        var notes: String
        var zip: String?
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var latest: Release?
    private(set) var lastChecked: Date?

    @ObservationIgnored @AppStorage("updateFeedURL") var feedURL = UpdateService.defaultFeed
    @ObservationIgnored @AppStorage("updateAutoCheck") var autoCheck = true
    @ObservationIgnored @AppStorage("updateLastCheck") private var lastCheckStamp: Double = 0
    @ObservationIgnored private var timer: Timer?

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var updateAvailable: Bool { latest.map { Self.isNewer($0.version, than: current) } ?? false }

    private init() {
        if lastCheckStamp > 0 { lastChecked = Date(timeIntervalSince1970: lastCheckStamp) }
    }

    /// Starts the background schedule: a check shortly after launch, then every 6 hours.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateService.shared.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            await checkIfDue()
        }
    }

    func checkIfDue() async {
        guard autoCheck, Date.now.timeIntervalSince1970 - lastCheckStamp > 6 * 3600 - 60 else { return }
        await check()
    }

    // MARK: Versions

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool { AppVersion.isNewer(a, than: b) }

    private var base: URL? {
        URL(string: feedURL.trimmingCharacters(in: .whitespaces).trimmingSuffix("/"))
    }

    // MARK: Check

    func check() async {
        guard phase != .downloading, phase != .installing, let base else { return }
        phase = .checking
        do {
            var req = URLRequest(url: base.appending(path: "mac-version.json"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.setValue("Un-remarkable-Mac/\(current)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw RMUpdateError("The download page has no update information yet (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            latest = release
            lastChecked = .now
            lastCheckStamp = Date.now.timeIntervalSince1970
            phase = Self.isNewer(release.version, than: current) ? .available : .upToDate
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Install

    var installLocation: URL { Bundle.main.bundleURL }

    /// Why updating in place can't work from here, if it can't.
    var installBlocker: String? {
        let app = installLocation
        guard app.pathExtension == "app" else { return "This is a development build (not an .app bundle). Use scripts/install.sh instead." }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            return "Can't write to \(app.deletingLastPathComponent().path). Update with the command from the download page."
        }
        guard FileManager.default.isWritableFile(atPath: app.path) else {
            return "This copy was installed by another account on this Mac. Update it with the command from the download page (it asks for your Mac password)."
        }
        if MeetingRecorder.shared.isRecording { return "Stop the meeting recording first." }
        return nil
    }

    func install() async {
        guard let release = latest, let base, installBlocker == nil else { return }
        phase = .downloading
        let work = FileManager.default.temporaryDirectory.appending(path: "unremarkable-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zipURL = URL(string: release.zip ?? "", relativeTo: base) ?? base.appending(path: "Un-remarkable-mac.zip")
            let (file, resp) = try await URLSession.shared.download(for: URLRequest(url: zipURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RMUpdateError("Download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)).") }
            let zip = work.appending(path: "app.zip")
            try FileManager.default.moveItem(at: file, to: zip)
            phase = .installing

            let data = try Data(contentsOf: zip, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == release.sha256.lowercased() else { throw RMUpdateError("The download is damaged (checksum mismatch). Try again later.") }

            let unpacked = work.appending(path: "unpacked")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let newApp = unpacked.appending(path: "Unremarkable.app")
            guard let info = Bundle(url: newApp), info.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw RMUpdateError("The download doesn't contain Un-remarkable.")
            }
            try Self.verifySignature(newApp)
            try launchSwap(newApp: newApp, work: work)
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: work)
            phase = .failed(error.localizedDescription)
        }
    }

    /// The new bundle must satisfy this copy's designated requirement: same signing certificate, same identifier.
    nonisolated static func verifySignature(_ app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw RMUpdateError("Couldn't read the code signatures.")
        }
        let status = SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement)
        guard status == errSecSuccess else {
            throw RMUpdateError("The download isn't signed by the same certificate as this copy (\(status)). Install it with the command from the download page if you trust it.")
        }
    }

    /// A helper script waits for the app to quit, swaps the bundle (restoring the old one on failure) and relaunches.
    private func launchSwap(newApp: URL, work: URL) throws {
        let app = installLocation.path
        let script = work.appending(path: "swap.sh")
        let body = """
        #!/bin/zsh
        APP=\(Self.quote(app)); NEW=\(Self.quote(newApp.path)); PID=\(ProcessInfo.processInfo.processIdentifier)
        for i in {1..150}; do kill -0 $PID 2>/dev/null || break; sleep 0.2; done
        rm -rf "$APP.previous"
        if mv "$APP" "$APP.previous" && ditto "$NEW" "$APP"; then
          rm -rf "$APP.previous"
        else
          rm -rf "$APP"; mv "$APP.previous" "$APP"
        fi
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        open "$APP"
        rm -rf \(Self.quote(work.path))
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    nonisolated static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    nonisolated static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw RMUpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus)).") }
        }.value
    }
}

struct RMUpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension String {
    func trimmingSuffix(_ s: String) -> String { hasSuffix(s) ? String(dropLast(s.count)) : self }
}
