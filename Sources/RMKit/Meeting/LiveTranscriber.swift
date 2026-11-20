@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

/// What the transcriber reports while it runs.
public enum TranscriptEvent: Sendable {
    /// Words still being recognised; replaced by the next volatile or final result for this speaker.
    case volatile(Speaker, String)
    case final(TranscriptSegment)
    case failed(Speaker, String)
}

/// On-device live transcription for one audio source (Apple SpeechAnalyzer, macOS 26).
///
/// Audio arrives on a real-time thread through `append(_:)`. Buffers are copied, converted to the
/// analyzer's format and recorded to disk on a private serial queue so the audio thread never blocks.
@available(macOS 26.0, *)
public final class LiveTranscriber: @unchecked Sendable {
    public let speaker: Speaker
    /// Timestamps are seconds from this moment. The source's own timeline starts at its first buffer,
    /// which can be later (a source started mid-meeting, or one that delivers nothing until there's sound).
    public let meetingStart: Date
    private let offsetLock = NSLock()
    private var firstBufferOffset: TimeInterval?

    private let queue: DispatchQueue
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var recorder: AVAudioFile?
    private let recordURL: URL?
    private var stopped = false

    public init(speaker: Speaker, meetingStart: Date = .now, recordTo url: URL? = nil) {
        self.speaker = speaker
        self.meetingStart = meetingStart
        self.recordURL = url
        self.queue = DispatchQueue(label: "unremarkable.transcriber.\(speaker.rawValue)", qos: .userInitiated)
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Meeting time of the recording's first sample (nil before any audio arrived).
    public var timelineOffset: TimeInterval? { offsetLock.withLock { firstBufferOffset } }

    /// Picks the best installed or supported locale for the user's language (e.g. en-GB).
    public static func preferredLocale() async -> Locale {
        let current = Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: current) { return match }
        return Locale(identifier: "en-US")
    }

    /// Downloads the speech model for a locale if it isn't installed yet.
    public static func ensureModel(locale: Locale) async throws {
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }
    }

    public func start(locale: Locale, onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                  reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        try await Self.ensureModel(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw RMError.malformed("No audio format available for speech recognition")
        }
        let analyzer = SpeechAnalyzer(modules: [t])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)

        let speaker = self.speaker
        resultsTask = Task { [self] in
            do {
                for try await r in t.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.isFinal {
                        guard !text.isEmpty else { continue }
                        let offset = offsetLock.withLock { firstBufferOffset ?? 0 }
                        let start = r.range.start.seconds.isFinite ? r.range.start.seconds : 0
                        let dur = r.range.duration.seconds.isFinite ? r.range.duration.seconds : 0
                        onEvent(.final(TranscriptSegment(speaker: speaker, start: offset + start, end: offset + start + dur, text: text)))
                        onEvent(.volatile(speaker, ""))
                    } else {
                        onEvent(.volatile(speaker, text))
                    }
                }
            } catch {
                onEvent(.failed(speaker, error.localizedDescription))
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        queue.sync {
            self.transcriber = t
            self.analyzer = analyzer
            self.analyzerFormat = format
            self.input = continuation
        }
    }

    /// Feed audio from any thread. The buffer is copied before returning.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.deepCopy() else { return }
        offsetLock.withLock {
            if firstBufferOffset == nil {
                // The buffer ends now; its first sample was captured one buffer-duration earlier.
                let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                firstBufferOffset = max(0, Date().timeIntervalSince(meetingStart) - duration)
            }
        }
        let arrival = Date()
        queue.async { [self] in
            guard !stopped else { return }
            guard let input, let target = analyzerFormat else { record(copy); return }
            // System audio only flows while something is playing. Fill the silent gap so timestamps stay on
            // the meeting clock (and the recogniser sees the pause and finishes the sentence).
            let duration = Double(copy.frameLength) / copy.format.sampleRate
            if let first = timelineStart {
                let gap = arrival.timeIntervalSince(first) - duration - Double(fedFrames) / target.sampleRate
                if gap > 0.5, let silence = Self.silence(seconds: min(gap, 600), format: target) {
                    fedFrames += AVAudioFramePosition(silence.frameLength)
                    input.yield(AnalyzerInput(buffer: silence))
                    if let recSilence = Self.silence(seconds: min(gap, 600), format: copy.format) { record(recSilence) }
                }
            } else {
                timelineStart = arrival.addingTimeInterval(-duration)
            }
            record(copy)
            if let converted = convert(copy, to: target) {
                fedFrames += AVAudioFramePosition(converted.frameLength)
                input.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    // Serial queue only.
    private var timelineStart: Date?
    private var fedFrames: AVAudioFramePosition = 0

    static func silence(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard frames > 0, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        b.frameLength = frames
        for buf in UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList) {
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
        return b
    }

    /// Flushes pending audio, waits for the final results and closes the recording.
    public func stop() async {
        let analyzer: SpeechAnalyzer? = queue.sync {
            stopped = true
            input?.finish()
            input = nil
            recorder = nil // closes the file
            return self.analyzer
        }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }

    // MARK: Audio plumbing (serial queue only)

    private func record(_ buffer: AVAudioPCMBuffer) {
        guard let recordURL else { return }
        if recorder == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: min(buffer.format.channelCount, 2),
                // AAC refuses high bit rates at low sample rates (16 kHz mono tops out below 64 kbps).
                AVEncoderBitRateKey: buffer.format.sampleRate < 32_000 ? 32_000 : 64_000,
            ]
            recorder = try? AVAudioFile(forWriting: recordURL, settings: settings,
                                        commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
        }
        try? recorder?.write(from: buffer)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let consumed = Flag()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

/// The converter calls its input block synchronously; this just satisfies the Sendable checker.
private final class Flag: @unchecked Sendable { var value = false }

extension AVAudioPCMBuffer {
    /// An independent copy; audio callbacks reuse their buffers.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { continue }
            memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }
}
