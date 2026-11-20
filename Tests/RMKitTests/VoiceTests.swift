import AVFoundation
import Foundation
import Testing
@testable import RMKit

/// Builds a fake call from macOS voices (`say`) taking turns, then checks the voices are told apart.
@Suite("voice separation", .serialized)
struct VoiceTests {
    static let lines = [
        "Thanks everyone for joining, let's start with the budget review for next quarter.",
        "Sure, I have the numbers here and the marketing spend came in under plan.",
        "That's good news. What about the hiring plan for the engineering team?",
        "We have two open roles and interviews are scheduled for next week.",
        "Can we move the product launch to the end of the month instead?",
        "I think that works, but we need to check with the design team first.",
        "Let's also make sure the support documentation is ready before launch.",
        "I'll take that action and send an update by Friday afternoon.",
        "Great, and who is following up with the legal review of the contract?",
        "I can do that, I already spoke to them about the terms on Monday.",
        "Perfect. Any other business before we wrap up the meeting today?",
        "Just one thing, the office will be closed on the public holiday.",
    ]

    static func speak(_ text: String, voice: String, dir: URL) throws -> [Float] {
        let out = dir.appending(path: "\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", out.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        try p.run()
        p.waitUntilExit()
        let file = try AVAudioFile(forReading: out)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    /// Writes the turns into one AAC file (as meetings record) and returns segments with their true voice.
    static func call(voices: [String], order: [Int], dir: URL) throws -> (URL, [TranscriptSegment], [UUID: Int]) {
        var samples: [Float] = []
        var segments: [TranscriptSegment] = []
        var truth: [UUID: Int] = [:]
        let rate = 16_000.0
        samples += [Float](repeating: 0, count: Int(rate * 1.2)) // offset before the first speech
        for (i, v) in order.enumerated() {
            let line = lines[i % lines.count]
            let speech = try speak(line, voice: voices[v], dir: dir)
            let start = Double(samples.count) / rate
            samples += speech
            let seg = TranscriptSegment(speaker: .them, start: start + 2, end: Double(samples.count) / rate + 2, text: line)
            segments.append(seg)
            truth[seg.id] = v
            samples += [Float](repeating: 0, count: Int(rate * 0.6))
        }
        let url = dir.appending(path: "them.m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
        return (url, segments, truth)
    }

    /// Fraction of segments whose voice matches the truth under the best one-to-one relabelling.
    static func accuracy(_ result: VoiceSeparation.Result, _ truth: [UUID: Int]) -> Double {
        var pairs: [Int: [Int: Int]] = [:]
        for (id, t) in truth { pairs[result.voices[id] ?? 0, default: [:]][t, default: 0] += 1 }
        let correct = pairs.values.map { $0.values.max() ?? 0 }.reduce(0, +)
        return Double(correct) / Double(truth.count)
    }

    func run(_ voices: [String], order: [Int]) throws -> (VoiceSeparation.Result, Double) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "voices-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, segments, truth) = try Self.call(voices: voices, order: order, dir: dir)
        // The file starts 2 s into the meeting.
        let result = VoiceSeparation.separate(segments, tracks: [.init(url: url, offset: 2)])
        let acc = Self.accuracy(result, truth)
        print("VOICES \(voices): found \(result.count), accuracy \(String(format: "%.0f", acc * 100))%")
        return (result, acc)
    }

    @Test func twoVoices() throws {
        let (r, acc) = try run(["Daniel", "Samantha"], order: [0, 1, 0, 1, 1, 0, 0, 1, 0, 1])
        #expect(r.count == 2)
        #expect(acc >= 0.9)
    }

    @Test func threeVoices() throws {
        let (r, acc) = try run(["Daniel", "Samantha", "Karen"], order: [0, 1, 2, 0, 2, 1, 1, 0, 2, 0, 1, 2])
        // Similar voices may be split in two (renaming both the same merges them) but are never merged.
        #expect((3...4).contains(r.count))
        #expect(acc >= 0.9)
    }

    @Test func oneVoiceStaysOne() throws {
        let (r, _) = try run(["Daniel"], order: [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(r.count == 1 && r.voices.isEmpty)
    }
}

extension VoiceTests {
    /// Calibration: within-voice and between-voice distances of raw prints, per dimension group.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RMKIT_VOICE_DEBUG"] == "1")) func distances() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "voices-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["Daniel", "Samantha", "Karen", "Moira", "Rishi", "Tessa", "Fred", "Albert"]
        let order = (0..<24).map { $0 % names.count }
        let (url, segments, truth) = try Self.call(voices: names, order: order, dir: dir)
        let prints = VoiceSeparation.voicePrints(segments, tracks: [.init(url: url, offset: 2)])
        var within: [Float] = [], between: [Float] = []
        for i in prints.indices { for j in prints.indices where j > i {
            let a = prints[i].1, b = prints[j].1
            let d = (zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Float(a.count)).squareRoot()
            if truth[prints[i].0] == truth[prints[j].0] { within.append(d) } else { between.append(d) }
        } }
        within.sort(); between.sort()
        print("DIST within: max \(within.last!) p90 \(within[within.count * 9 / 10]) median \(within[within.count / 2])")
        print("DIST between: min \(between.first!) p10 \(between[between.count / 10]) median \(between[between.count / 2])")
        for v in names.indices {
            let mine = prints.filter { truth[$0.0] == v }
            let others = prints.filter { truth[$0.0] != v }
            let nearestOther = mine.map { a in others.map { b in (zip(a.1, b.1).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Float(a.1.count)).squareRoot() }.min()! }.min()!
            print("DIST \(names[v]): nearest other voice \(nearestOther), pitch \(mine.first.map { exp($0.1.last! / 35) } ?? 0)")
        }
    }
}

extension VoiceTests {
    /// Writes a two-voice fake call for app runs: `RMKIT_VOICE_CALL=/path/them.m4a`, then UNREMARKABLE_FAKE_THEM=that file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RMKIT_VOICE_CALL"] != nil)) func writeFakeCall() throws {
        let dest = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RMKIT_VOICE_CALL"]!)
        let dir = FileManager.default.temporaryDirectory.appending(path: "voices-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, _, _) = try Self.call(voices: ["Daniel", "Samantha"], order: [0, 1, 0, 1, 1, 0, 1, 0], dir: dir)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
    }
}

extension VoiceTests {
    /// Runs separation on a recorded meeting folder: `RMKIT_MEETING_DIR=<folder>`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RMKIT_MEETING_DIR"] != nil)) func separateRecordedMeeting() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RMKIT_MEETING_DIR"]!)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var m = try (try? dec.decode(Meeting.self, from: Data(contentsOf: dir.appending(path: "meeting.json"))))
            ?? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: dir.appending(path: "meeting.json")))
        let theirs = m.transcript.filter { $0.speaker == .them }
        let tracks = m.audioFiles.filter { $0.value == "them" }.keys.map { VoiceSeparation.AudioTrack(url: dir.appending(path: $0), offset: m.audioOffsets[$0] ?? 0) }
        let prints = VoiceSeparation.voicePrints(theirs, tracks: tracks)
        print("MEETING prints \(prints.count) of \(theirs.count)")
        for p in prints { print("MEETING " + p.1.map { String(format: "%5.1f", $0) }.joined(separator: " ")) }
        let n = m.separateVoices(folder: dir)
        print("MEETING voices \(n): " + m.transcript.filter { $0.speaker == .them }.map { "\($0.voice ?? 0)" }.joined(separator: ","))
    }
}
