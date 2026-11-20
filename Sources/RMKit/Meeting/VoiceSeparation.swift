import Accelerate
@preconcurrency import AVFoundation
import Foundation

/// Tells apart the voices in a call's system audio ("Them"), so the transcript can say "Them 1", "Them 2"
/// (or names you give them) instead of one "Them". Works offline on the recorded audio: each transcript
/// segment gets a voice print (mean mel cepstra plus pitch), and similar prints are grouped.
/// No speaker model is involved, so it separates distinct voices well and similar voices less reliably.
public enum VoiceSeparation {
    public struct Result: Sendable, Equatable {
        /// Voice number (1-based, in order of first appearance) per transcript segment id; nil for "can't tell".
        public var voices: [UUID: Int]
        public var count: Int
    }

    /// Where a segment's audio is: a recorded file and the meeting time its first sample belongs to.
    public struct AudioTrack: Sendable {
        public var url: URL
        public var offset: TimeInterval
        public init(url: URL, offset: TimeInterval) {
            self.url = url
            self.offset = offset
        }
    }

    static let sampleRate = 16_000.0
    static let frameSize = 512
    static let hop = 160
    static let melBands = 26
    static let cepstra = 13

    /// Groups the "Them" segments of a meeting by voice. Segments without enough speech inherit the voice of the
    /// nearest segment before them. Returns one voice when everyone sounds alike (no labels needed).
    public static func separate(_ segments: [TranscriptSegment], tracks: [AudioTrack], threshold: Float = 3.8) -> Result {
        let theirs = segments.filter { $0.speaker == .them }.sorted { $0.start < $1.start }
        let prints = voicePrints(theirs, tracks: tracks)
        guard prints.count >= 2 else { return Result(voices: [:], count: prints.isEmpty ? 0 : 1) }

        let labels = cluster(prints.map(\.1), threshold: threshold)
        var byID: [UUID: Int] = [:]
        for (i, p) in prints.enumerated() { byID[p.0] = labels[i] }
        // Number voices in order of first appearance.
        var order: [Int: Int] = [:]
        for s in theirs { if let l = byID[s.id], order[l] == nil { order[l] = order.count + 1 } }
        var voices: [UUID: Int] = [:]
        var last: Int?
        for s in theirs {
            if let l = byID[s.id] { last = order[l] }
            if let v = last { voices[s.id] = v }
        }
        // Short segments before the first voice print take the first voice.
        if let first = theirs.first(where: { voices[$0.id] != nil }).flatMap({ voices[$0.id] }) {
            for s in theirs where voices[s.id] == nil { voices[s.id] = first }
        }
        return Result(voices: order.count > 1 ? voices : [:], count: order.count)
    }

    static func voicePrints(_ theirs: [TranscriptSegment], tracks: [AudioTrack]) -> [(UUID, [Float])] {
        var prints: [(UUID, [Float])] = []
        let extractor = FeatureExtractor()
        for track in tracks {
            guard let file = try? AVAudioFile(forReading: track.url) else { continue }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            for s in theirs where s.start >= track.offset - 0.5 && s.start < track.offset + duration {
                guard prints.contains(where: { $0.0 == s.id }) == false,
                      let samples = read(file, from: s.start - track.offset, to: min(s.end, s.start + 30) - track.offset),
                      let print = extractor.voicePrint(samples) else { continue }
                prints.append((s.id, print))
            }
        }
        return prints
    }

    // MARK: Audio

    /// Mono 16 kHz samples between two file times.
    static func read(_ file: AVAudioFile, from start: TimeInterval, to end: TimeInterval) -> [Float]? {
        let format = file.processingFormat
        let first = AVAudioFramePosition(max(0, start) * format.sampleRate)
        let last = min(file.length, AVAudioFramePosition(max(0, end) * format.sampleRate))
        guard last - first > AVAudioFramePosition(format.sampleRate * 0.4) else { return nil }
        file.framePosition = first
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first)),
              (try? file.read(into: buffer, frameCount: AVAudioFrameCount(last - first))) != nil,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let fed = FedOnce()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed.value { inputStatus.pointee = .endOfStream; return nil }
            fed.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = out.floatChannelData?[0], out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    // MARK: Clustering

    /// Average-linkage agglomerative clustering; stops when the closest clusters are further apart than
    /// `threshold` (RMS distance per dimension). Clusters too small to be a person fold into their neighbour.
    static func cluster(_ rows: [[Float]], threshold: Float, maxVoices: Int = 8) -> [Int] {
        let n = rows.count
        let dims = Float(rows.first?.count ?? 1)
        func dist(_ a: [Float], _ b: [Float]) -> Float {
            var s: Float = 0
            for i in a.indices { s += (a[i] - b[i]) * (a[i] - b[i]) }
            return (s / dims).squareRoot()
        }
        var d = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in (i + 1)..<max(i + 1, n) { d[i][j] = dist(rows[i], rows[j]); d[j][i] = d[i][j] } }
        var clusters: [[Int]] = (0..<n).map { [$0] }
        func linkage(_ a: [Int], _ b: [Int]) -> Float {
            var s: Float = 0
            for i in a { for j in b { s += d[i][j] } }
            return s / Float(a.count * b.count)
        }
        func closest() -> (Int, Int, Float)? {
            var best: (Int, Int, Float)?
            for i in clusters.indices { for j in clusters.indices where j > i {
                let l = linkage(clusters[i], clusters[j])
                if best == nil || l < best!.2 { best = (i, j, l) }
            } }
            return best
        }
        while clusters.count > 1, let (i, j, l) = closest(), l < threshold || clusters.count > maxVoices {
            clusters[i] += clusters[j]
            clusters.remove(at: j)
        }
        // A "voice" heard in under 10% of segments (and fewer than 3) is more likely noise than a person.
        let minimum = max(2, Int((Float(n) * 0.1).rounded(.down)))
        while clusters.count > 1, let small = clusters.indices.min(by: { clusters[$0].count < clusters[$1].count }),
              clusters[small].count < min(minimum, 3) {
            let target = clusters.indices.filter { $0 != small }.min { linkage(clusters[small], clusters[$0]) < linkage(clusters[small], clusters[$1]) }!
            clusters[target] += clusters[small]
            clusters.remove(at: small)
        }
        var labels = [Int](repeating: 0, count: n)
        for (c, members) in clusters.enumerated() { for m in members { labels[m] = c } }
        return labels
    }
}

/// The converter calls its input block synchronously; this satisfies the Sendable checker.
private final class FedOnce: @unchecked Sendable { var value = false }

/// Mel-frequency cepstra and pitch from 16 kHz mono speech.
final class FeatureExtractor {
    private let n = VoiceSeparation.frameSize
    private let window: [Float]
    private let filters: [[Float]]
    private let dft: vDSP_DFT_Setup
    private let idft: vDSP_DFT_Setup

    init() {
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        idft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
        filters = Self.melFilters(bands: VoiceSeparation.melBands, bins: n / 2 + 1, sampleRate: Float(VoiceSeparation.sampleRate), low: 100, high: 7_600)
    }

    deinit {
        vDSP_DFT_DestroySetup(dft)
        vDSP_DFT_DestroySetup(idft)
    }

    /// Mean cepstra 2–12 over the louder (voiced) frames, plus median log pitch. Nil under ~0.5 s of speech.
    func voicePrint(_ samples: [Float]) -> [Float]? {
        guard samples.count > n else { return nil }
        var frames: [(energy: Float, cep: [Float], pitch: Float?)] = []
        var start = 0
        while start + n <= samples.count {
            let (power, energy) = spectrum(Array(samples[start..<start + n]))
            frames.append((energy, cepstra(power), pitch(power)))
            start += VoiceSeparation.hop
        }
        // Keep frames within 25 dB of the loudest 5%: speech, not the silence between words.
        let sorted = frames.map(\.energy).sorted()
        guard let loud = sorted.dropFirst(Int(Double(sorted.count) * 0.95)).first else { return nil }
        let kept = frames.filter { $0.energy > loud - 2.5 && $0.energy > -9 }
        guard kept.count >= 40 else { return nil }
        // Cepstra 2–12: c1 mostly follows loudness and spectral tilt, which change with what's being said.
        var mean = [Float](repeating: 0, count: VoiceSeparation.cepstra - 2)
        for f in kept { for i in mean.indices { mean[i] += f.cep[i + 2] } }
        mean = mean.map { $0 / Float(kept.count) }
        let pitches = kept.compactMap(\.pitch).sorted()
        // Pitch on a log scale: 10% higher is about 3.5 units, comparable to a clear difference in timbre.
        let pitch = pitches.isEmpty ? nil : log(pitches[pitches.count / 2]) * 35
        return mean + [pitch ?? Float(log(150.0) * 35)]
    }

    /// Power spectrum (bins 0…n/2) and log10 frame energy.
    private func spectrum(_ frame: [Float]) -> ([Float], Float) {
        var x = vDSP.multiply(frame, window)
        let mean = vDSP.mean(x)
        x = vDSP.add(-mean, x)
        let half = n / 2
        var evenIn = [Float](repeating: 0, count: half), oddIn = evenIn, re = evenIn, im = evenIn
        for i in 0..<half { evenIn[i] = x[2 * i]; oddIn[i] = x[2 * i + 1] }
        vDSP_DFT_Execute(dft, evenIn, oddIn, &re, &im)
        var power = [Float](repeating: 0, count: half + 1)
        power[0] = re[0] * re[0]
        power[half] = im[0] * im[0]
        for k in 1..<half { power[k] = re[k] * re[k] + im[k] * im[k] }
        let energy = log10(max(vDSP.sum(power), 1e-10))
        return (power, energy)
    }

    private func cepstra(_ power: [Float]) -> [Float] {
        let logMel = filters.map { f -> Float in
            var s: Float = 0
            for k in f.indices where f[k] > 0 { s += f[k] * power[k] }
            return log(max(s, 1e-8))
        }
        let m = Float(logMel.count)
        return (0..<VoiceSeparation.cepstra).map { c in
            var s: Float = 0
            for (j, v) in logMel.enumerated() { s += v * cos(Float.pi * Float(c) * (Float(j) + 0.5) / m) }
            return s
        }
    }

    /// Fundamental frequency from the autocorrelation (inverse DFT of the power spectrum), 70–400 Hz; nil if unvoiced.
    private func pitch(_ power: [Float]) -> Float? {
        let half = n / 2
        var re = [Float](repeating: 0, count: half), im = re, outRe = re, outIm = re
        for k in 0..<half { re[k] = power[k] }
        im[0] = power[half]
        vDSP_DFT_Execute(idft, re, im, &outRe, &outIm)
        // Output interleaves even and odd lags.
        var ac = [Float](repeating: 0, count: n)
        for i in 0..<half { ac[2 * i] = outRe[i]; ac[2 * i + 1] = outIm[i] }
        guard ac[0] > 0 else { return nil }
        let sr = Float(VoiceSeparation.sampleRate)
        let minLag = Int(sr / 400), maxLag = min(Int(sr / 70), half - 1)
        var best = minLag
        for lag in minLag...maxLag where ac[lag] > ac[best] { best = lag }
        guard ac[best] / ac[0] > 0.35 else { return nil }
        return sr / Float(best)
    }

    static func melFilters(bands: Int, bins: Int, sampleRate: Float, low: Float, high: Float) -> [[Float]] {
        func mel(_ f: Float) -> Float { 2595 * log10(1 + f / 700) }
        func hz(_ m: Float) -> Float { 700 * (pow(10, m / 2595) - 1) }
        let points = (0...(bands + 1)).map { hz(mel(low) + (mel(high) - mel(low)) * Float($0) / Float(bands + 1)) }
        let bin = points.map { $0 / (sampleRate / 2) * Float(bins - 1) }
        return (0..<bands).map { b in
            (0..<bins).map { k in
                let x = Float(k)
                if x < bin[b] || x > bin[b + 2] { return 0 }
                return x <= bin[b + 1] ? (x - bin[b]) / max(bin[b + 1] - bin[b], 1e-3) : (bin[b + 2] - x) / max(bin[b + 2] - bin[b + 1], 1e-3)
            }
        }
    }
}
