@preconcurrency import AVFAudio
import AppKit
import Observation
import RMKit
import SwiftUI

/// Thread-safe audio level shared between a real-time audio callback and the UI timer.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    func set(_ v: Float) { lock.withLock { value = max(v, value * 0.85) } }
    func read() -> Float { lock.withLock { let v = value; value *= 0.6; return v } }
}

/// Records meetings: microphone ("Me") and system audio ("Them"), live on-device transcription,
/// your typed notes, then AI notes and a PDF sent to the tablet.
@MainActor @Observable
final class MeetingRecorder {
    static let shared = MeetingRecorder()

    enum State: Equatable { case idle, starting, recording, stopping }

    let store: MeetingStore
    private(set) var meetings: [Meeting] = []
    private(set) var state: State = .idle
    /// ID of the meeting being recorded.
    private(set) var activeID: String?
    var volatile: [Speaker: String] = [:]
    var levels: [Speaker: Float] = [:]
    var elapsed: TimeInterval = 0
    var error: String?
    /// Per-meeting status of AI notes / sending ("Writing notes…").
    var busy: [String: String] = [:]

    @ObservationIgnored @AppStorage("meetingCaptureSystemAudio") var captureSystemAudio = true
    @ObservationIgnored @AppStorage("meetingAutoNotes") var autoNotes = true
    @ObservationIgnored @AppStorage("meetingFolderName") var folderName = "Meeting Notes"
    /// "notebook" (typed, editable on the tablet) or "pdf".
    @ObservationIgnored @AppStorage("meetingSendFormat") var sendFormat = "notebook"
    /// Add notes as pages after a linked notebook's own pages (e.g. the tablet's calendar meeting page).
    @ObservationIgnored @AppStorage("meetingAppendToLinked") var appendToLinked = true
    @ObservationIgnored @AppStorage("meetingTranscriptOnTablet") var transcriptOnTablet = false

    @ObservationIgnored private var sources: [Speaker: any AudioSource] = [:]
    @ObservationIgnored private var transcribers: [Speaker: AnyObject] = [:]
    @ObservationIgnored private var recordingFiles: [Speaker: String] = [:]
    @ObservationIgnored @AppStorage("meetingSeparateVoices") var separateVoices = true
    @ObservationIgnored private var meters: [Speaker: LevelMeter] = [.me: LevelMeter(), .them: LevelMeter()]
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var startDate = Date()

    private init() {
        store = MeetingStore(root: AppModel.shared.paths.support.appending(path: "Meetings"))
        meetings = store.all()
    }

    var isRecording: Bool { state == .recording || state == .starting }
    var active: Meeting? { activeID.flatMap { id in meetings.first { $0.id == id } } }

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return LiveTranscriber.isAvailable }
        return false
    }

    // MARK: Editing

    func update(_ meeting: Meeting) {
        guard let i = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[i] = meeting
        scheduleSave(meeting.id)
    }

    func newMeeting(title: String = "") -> Meeting {
        let m = Meeting(title: title)
        meetings.insert(m, at: 0)
        try? store.save(m)
        return m
    }

    func delete(_ id: String) {
        guard id != activeID else { return }
        meetings.removeAll { $0.id == id }
        try? store.delete(id)
    }

    private func scheduleSave(_ id: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            saveNow(id)
        }
    }

    private func saveNow(_ id: String) {
        if let m = meeting(id) { try? store.save(m) }
    }

    // MARK: Recording

    /// Starts recording into an existing meeting (or a new one).
    func start(_ id: String? = nil) async {
        guard state == .idle else { return }
        guard #available(macOS 26.0, *), LiveTranscriber.isAvailable else {
            error = "Live transcription needs macOS 26 with on-device speech recognition."
            return
        }
        error = nil
        state = .starting
        let meetingID = id ?? newMeeting().id
        activeID = meetingID
        // Development aid: UNREMARKABLE_FAKE_ME / UNREMARKABLE_FAKE_THEM=<audio file> replace the live sources.
        let env = ProcessInfo.processInfo.environment
        let fake: [Speaker: URL] = [.me: env["UNREMARKABLE_FAKE_ME"], .them: env["UNREMARKABLE_FAKE_THEM"]]
            .compactMapValues { $0.map { URL(fileURLWithPath: $0) } }
        let micAllowed = fake[.me] != nil ? true : await AudioPermission.microphone()
        guard micAllowed else {
            fail("Un-remarkable needs microphone access. Allow it in System Settings › Privacy & Security › Microphone.")
            return
        }

        // Resume after an earlier recording: new audio continues the meeting's timeline.
        let base = meeting(meetingID)?.duration ?? 0
        startDate = Date().addingTimeInterval(-base)
        let folder = store.folder(for: meetingID)
        let locale = await LiveTranscriber.preferredLocale()
        let wanted: [Speaker] = captureSystemAudio || fake[.them] != nil ? [.me, .them] : [.me]
        // Live mic + live system audio share one Core Audio device (see SystemAudioSource.microphone):
        // a separate microphone capture alongside the tap stalls the tap.
        let combined = wanted.contains(.them) && fake[.me] == nil && fake[.them] == nil
        var micHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

        for speaker in wanted {
            let file = "\(speaker.rawValue)-\(Int(Date().timeIntervalSince1970)).m4a"
            let transcriber = LiveTranscriber(speaker: speaker, meetingStart: startDate, recordTo: folder.appending(path: file))
            let meter = meters[speaker]!
            let probe = AudioProbe(speaker)
            let handler: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
                probe.observe(buffer)
                meter.set(audioLevel(buffer))
                transcriber.append(buffer)
            }
            do {
                try await transcriber.start(locale: locale) { event in
                    Task { @MainActor in MeetingRecorder.shared.handle(event, meetingID: meetingID) }
                }
                if speaker == .me, combined {
                    // Started below with the system-audio device.
                    micHandler = handler
                } else {
                    let source: any AudioSource
                    if let url = fake[speaker] {
                        source = FileAudioSource(url: url, delay: speaker == .them ? 9 : 0)
                    } else if speaker == .me {
                        source = MicrophoneSource()
                    } else {
                        guard await AudioPermission.requestSystemAudio() else {
                            throw RMError.auth("allow Un-remarkable under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only")
                        }
                        let system = SystemAudioSource()
                        system.microphone = micHandler
                        source = system
                    }
                    // Core Audio setup makes synchronous calls to coreaudiod; keep them off the main thread.
                    try await Task.detached(priority: .userInitiated) { try source.start(handler) }.value
                    sources[speaker] = source
                }
                transcribers[speaker] = transcriber
                recordingFiles[speaker] = file
                if var m = meeting(meetingID) {
                    m.audioFiles[file] = speaker.rawValue
                    update(m)
                }
            } catch {
                await transcriber.stop()
                transcribers[speaker] = nil
                if speaker == .me {
                    fail("Couldn't start recording: \(error.localizedDescription)")
                    await stopSources()
                    return
                }
                // System audio failed: record the microphone on its own instead.
                if let micHandler {
                    let mic = MicrophoneSource()
                    do {
                        try await Task.detached(priority: .userInitiated) { try mic.start(micHandler) }.value
                        sources[.me] = mic
                    } catch {
                        fail("Couldn't start recording: \(error.localizedDescription)")
                        await stopSources()
                        return
                    }
                }
                self.error = "Recording your microphone only. System audio failed: \(error.localizedDescription)"
            }
        }

        state = .recording
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingRecorder.shared.tick() }
        }
        AppModel.shared.addLog("Meeting recording started.")
    }

    func stop() async {
        guard state == .recording, let id = activeID else { return }
        state = .stopping
        ticker?.invalidate()
        ticker = nil
        var offsets: [String: TimeInterval] = [:]
        if #available(macOS 26.0, *) {
            for (speaker, t) in transcribers {
                if let file = recordingFiles[speaker], let offset = (t as? LiveTranscriber)?.timelineOffset { offsets[file] = offset }
            }
        }
        await stopSources()
        if var m = meeting(id) {
            m.duration = Date().timeIntervalSince(startDate)
            m.audioOffsets.merge(offsets) { $1 }
            update(m)
            saveNow(id)
        }
        volatile = [:]
        levels = [:]
        activeID = nil
        state = .idle
        AppModel.shared.addLog("Meeting recording stopped.")
        if separateVoices { await findVoices(id) }
        if autoNotes { await generateNotes(id) }
    }

    private func stopSources() async {
        let running = Array(sources.values)
        await Task.detached { for s in running { s.stop() } }.value
        sources = [:]
        if #available(macOS 26.0, *) {
            for t in transcribers.values { await (t as? LiveTranscriber)?.stop() }
        }
        transcribers = [:]
        recordingFiles = [:]
    }

    /// Splits "Them" into the separate voices on the call (Them 1, Them 2…), from the recorded system audio.
    @discardableResult
    func findVoices(_ id: String) async -> Int {
        guard let m = meeting(id), m.transcript.contains(where: { $0.speaker == .them }), busy[id] == nil else { return 0 }
        busy[id] = "Telling voices apart…"
        defer { busy[id] = nil }
        let folder = store.folder(for: id)
        let (separated, count) = await Task.detached(priority: .userInitiated) { () -> (Meeting, Int) in
            var copy = m
            let n = copy.separateVoices(folder: folder)
            return (copy, n)
        }.value
        guard var latest = meeting(id) else { return 0 }
        let voices = Dictionary(uniqueKeysWithValues: separated.transcript.map { ($0.id, $0.voice) })
        for i in latest.transcript.indices { latest.transcript[i].voice = voices[latest.transcript[i].id] ?? nil }
        // Keep names for voices that still exist.
        latest.voiceNames = latest.voiceNames.filter { k, _ in latest.voices.contains(Int(k) ?? 0) }
        update(latest)
        saveNow(id)
        if count > 1 { AppModel.shared.addLog("Found \(count) voices in \(latest.displayTitle).") }
        return count
    }

    func clearVoices(_ id: String) {
        guard var m = meeting(id) else { return }
        m.clearVoices()
        update(m)
        saveNow(id)
    }

    func nameVoice(_ id: String, voice: Int, as name: String) {
        guard var m = meeting(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        m.voiceNames[String(voice)] = trimmed.isEmpty ? nil : trimmed
        update(m)
    }

    private func fail(_ message: String) {
        error = message
        state = .idle
        if let id = activeID, let m = meeting(id), m.transcript.isEmpty, m.myNotes.isEmpty, m.title.isEmpty { delete(id) }
        activeID = nil
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(startDate)
        for (speaker, meter) in meters where transcribers[speaker] != nil { levels[speaker] = meter.read() }
    }

    private func handle(_ event: TranscriptEvent, meetingID: String) {
        switch event {
        case .volatile(let speaker, let text):
            volatile[speaker] = text
        case .final(let segment):
            guard var m = meeting(meetingID) else { return }
            m.appendSegment(segment)
            update(m)
        case .failed(let speaker, let message):
            error = "\(speaker.label) transcription stopped: \(message)"
        }
    }

    // MARK: AI notes

    func generateNotes(_ id: String) async {
        guard var m = meeting(id), busy[id] == nil else { return }
        let model = AppModel.shared
        busy[id] = "Checking your tablet for handwriting…"
        defer { busy[id] = nil }
        var images: [Data] = []
        var written = ""
        let settings = AISettings.current
        if model.isPaired {
            await model.syncNow(quiet: true)
            if m.linkedDocumentID == nil, let suggestion = suggestedNotebook(for: m) {
                m.linkedDocumentID = suggestion.id
                update(m)
            }
            if let docID = m.linkedDocumentID, let doc = model.byID[docID] {
                // Providers that read images see the pages; others get reMarkable's conversion of them.
                if settings.provider.supportsImages { images = await handwritingImages(doc) } else { written = await handwritingText(doc) }
            }
        }
        let generator = MeetingNotesGenerator(provider: AIProvider(settings: settings))
        do {
            let notes = try await generator.generate(m, handwriting: images, handwritingText: written) { message in
                Task { @MainActor in MeetingRecorder.shared.busy[id] = message }
            }
            guard var latest = meeting(id) else { return }
            latest.aiNotes = notes
            update(latest)
            saveNow(id)
            model.addLog("Wrote notes for \(latest.displayTitle).")
        } catch {
            self.error = "Couldn't write notes: \(error.localizedDescription)"
            model.addLog("Meeting notes failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// The notebook you most likely wrote in during the meeting: modified between its start and a few
    /// minutes after it ended, most recent first.
    func suggestedNotebook(for m: Meeting) -> DocumentItem? {
        let from = m.startedAt.addingTimeInterval(-5 * 60)
        let to = m.startedAt.addingTimeInterval(max(m.duration, 60) + 15 * 60)
        return AppModel.shared.documents
            .filter { !$0.isFolder && !$0.isTrashed && $0.lastModified >= from && $0.lastModified <= to && $0.kind != .epub }
            .max { $0.lastModified < $1.lastModified }
    }

    /// PNGs of up to four pages with ink, nearest the page you last had open.
    private func handwritingImages(_ doc: DocumentItem) async -> [Data] {
        let renderer = AppModel.shared.renderer
        let count = await renderer.pageCount(doc)
        let around = min(max(doc.lastOpenedPage, 0), max(count - 1, 0))
        let order = (0..<count).sorted { abs($0 - around) < abs($1 - around) }
        var out: [Data] = []
        for i in order.prefix(12) where out.count < 4 {
            guard let rm = await renderer.rmPage(doc, i), !rm.layers.allSatisfy({ $0.strokes.isEmpty }) else { continue }
            if let box = try? await renderer.page(doc, index: i, options: RenderOptions(dark: false, pixelWidth: 1100)),
               let png = NSBitmapImageRep(cgImage: box.image).representation(using: .png, properties: [:]) {
                out.append(png)
            }
        }
        return out
    }

    /// The notebook's handwriting as text (reMarkable's conversion), nearest the last-opened page first.
    private func handwritingText(_ doc: DocumentItem) async -> String {
        let model = AppModel.shared
        let around = min(max(doc.lastOpenedPage, 0), max(doc.displayPageCount - 1, 0))
        let order = (0..<doc.displayPageCount).sorted { abs($0 - around) < abs($1 - around) }
        var pages: [(Int, String)] = []
        for i in order.prefix(12) where pages.count < 4 {
            guard let rm = doc.rmFile(for: i), let page = await model.renderer.rmPage(doc, i), HandwritingConversion.hasHandwriting(page) else { continue }
            var text = model.db.ocrText(rm.hash) ?? ""
            if text.isEmpty, let converted = try? await model.sync.client.convertHandwriting(page, language: AppModel.handwritingLanguage) {
                model.db.setOCRText(converted, for: rm.hash)
                text = converted
            }
            if !text.isEmpty { pages.append((i, text)) }
        }
        return pages.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n\n")
    }

    // MARK: Send to tablet

    func sendToTablet(_ id: String) async {
        guard let m = meeting(id), busy[id] == nil else { return }
        let model = AppModel.shared
        guard model.isPaired else {
            error = "Connect your reMarkable first."
            return
        }
        busy[id] = "Sending to your tablet…"
        defer { busy[id] = nil }
        let parent = model.documents.first {
            $0.isFolder && !$0.isTrashed && $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(folderName) == .orderedSame
        }?.id ?? ""
        do {
            let docID: String?
            if appendToLinked, let linked = m.linkedDocumentID, let doc = model.byID[linked], doc.kind == .notebook, !doc.isTrashed {
                // Below the meeting page's handwriting: new pages after the notebook's own (earlier ones replaced).
                let pages = TypedNotebook.pages(fromMarkdown: m.appendedPagesMarkdown(includeTranscript: transcriptOnTablet))
                let (updated, ids) = try await model.sync.appendPages(docID: linked, pages: pages,
                                                                      replacing: m.appendedPageIDs.filter { id in doc.pages.contains { $0.pageID == id } })
                guard var latest = meeting(id) else { return }
                latest.appendedPageIDs = ids
                latest.sentDocumentID = updated.id
                latest.sentAt = .now
                update(latest)
                saveNow(id)
                model.documents = model.db.allDocuments()
                model.addLog("Added the notes for \(m.displayTitle) to \(doc.name) (\(ids.count) page\(ids.count == 1 ? "" : "s")).")
                return
            }
            if sendFormat == "pdf" {
                let filename = m.displayTitle.replacingOccurrences(of: "/", with: "-") + ".pdf"
                docID = try await model.sync.upload(data: MeetingPDF.render(m), filename: filename, parentID: parent)
            } else {
                let pages = TypedNotebook.pages(fromMarkdown: m.tabletMarkdown())
                // Sent before as a notebook that still exists: update it in place instead of adding a copy.
                if let existing = m.sentDocumentID, let doc = model.byID[existing], doc.kind == .notebook, !doc.isTrashed {
                    docID = try await model.sync.replaceTypedNotebook(id: existing, title: m.displayTitle, pages: pages, parentID: doc.parent).id
                } else {
                    let id = UUID().uuidString.lowercased()
                    docID = try await model.sync.replaceTypedNotebook(id: id, title: m.displayTitle, pages: pages, parentID: parent).id
                }
            }
            guard var latest = meeting(id) else { return }
            latest.sentDocumentID = docID
            latest.sentAt = .now
            update(latest)
            saveNow(id)
            model.documents = model.db.allDocuments()
            model.addLog("Sent \(m.displayTitle) to your tablet.")
            if sendFormat == "pdf" { await model.syncNow(quiet: true) }
        } catch {
            self.error = "Couldn't send to the tablet: \(error.localizedDescription)"
        }
    }

    /// The notebook notes will be added to, when sending appends to a linked notebook.
    func appendsToLinked(_ m: Meeting) -> Bool {
        guard appendToLinked, let id = m.linkedDocumentID, let doc = AppModel.shared.byID[id] else { return false }
        return doc.kind == .notebook && !doc.isTrashed
    }

    /// True when sending again would overwrite a notebook already on the tablet.
    func sendWouldReplace(_ m: Meeting) -> Bool {
        if appendsToLinked(m) { return !m.appendedPageIDs.isEmpty }
        guard sendFormat != "pdf", let id = m.sentDocumentID, let doc = AppModel.shared.byID[id] else { return false }
        return doc.kind == .notebook && !doc.isTrashed
    }

    func exportMarkdown(_ m: Meeting) -> String {
        var s = "# \(m.displayTitle)\n\n_\(m.startedAt.formatted(date: .complete, time: .shortened))_\n\n"
        if !m.aiNotes.isEmpty { s += m.aiNotes + "\n\n" }
        if !m.myNotes.isEmpty { s += "## My notes\n\n\(m.myNotes)\n\n" }
        if !m.transcript.isEmpty { s += "## Transcript\n\n" + m.transcriptText.replacingOccurrences(of: "\n", with: "\n\n") + "\n" }
        return s
    }
}

/// Reports what a source actually delivers: its format once, then whether it is silent.
/// The first buffer's format goes to the activity log; with UNREMARKABLE_AUDIO_DEBUG set, levels every second go to stderr.
final class AudioProbe: @unchecked Sendable {
    private let speaker: Speaker
    private let lock = NSLock()
    private var buffers = 0
    private var frames: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var lastReport = Date()
    private let verbose = ProcessInfo.processInfo.environment["UNREMARKABLE_AUDIO_DEBUG"] != nil

    init(_ speaker: Speaker) { self.speaker = speaker }

    func observe(_ buffer: AVAudioPCMBuffer) {
        let level = audioLevel(buffer)
        let (first, report): (Bool, String?) = lock.withLock {
            buffers += 1
            frames += AVAudioFramePosition(buffer.frameLength)
            peak = max(peak, level)
            var report: String?
            if verbose, Date().timeIntervalSince(lastReport) >= 1 {
                report = "\(speaker.label): \(buffers) buffers, peak level \(String(format: "%.2f", peak))"
                peak = 0
                lastReport = Date()
            }
            return (buffers == 1, report)
        }
        if first {
            let f = buffer.format
            let text = "\(speaker == .me ? "Microphone" : "System audio"): \(Int(f.sampleRate)) Hz, \(f.channelCount) ch, \(f.commonFormat == .pcmFormatFloat32 ? "float" : "int"), \(f.isInterleaved ? "interleaved" : "planar")"
            Task { @MainActor in AppModel.shared.addLog(text) }
            if verbose { FileHandle.standardError.write(Data("AUDIO \(text)\n".utf8)) }
        }
        if let report { FileHandle.standardError.write(Data("AUDIO \(report)\n".utf8)) }
    }
}
