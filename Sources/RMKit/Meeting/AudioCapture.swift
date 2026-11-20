@preconcurrency import AVFAudio
import AVFoundation
import CoreAudio
import Foundation

/// A live audio source that delivers PCM buffers on a real-time thread.
public protocol AudioSource: AnyObject, Sendable {
    func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

public enum AudioPermission {
    public enum Status: String, Sendable { case granted, denied, unknown }

    /// System audio recording permission ("Screen & System Audio Recording" › System Audio Recording Only).
    /// There's no public API to check or request it, so this uses the TCC calls macOS's own apps use.
    /// Without it, a process tap starts but never delivers audio.
    public static func systemAudioStatus() -> Status {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let fn: Preflight = tccSymbol("TCCAccessPreflight") else { return .unknown }
        switch fn("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet. Returns whether access is granted.
    public static func requestSystemAudio() async -> Bool {
        switch systemAudioStatus() {
        case .granted: return true
        case .denied: return false
        case .unknown: break
        }
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        guard let fn: Request = tccSymbol("TCCAccessRequest") else { return false }
        return await withCheckedContinuation { cont in
            fn("kTCCServiceAudioCapture" as CFString, nil) { granted in cont.resume(returning: granted) }
        }
    }

    private static func tccSymbol<T>(_ name: String) -> T? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    public static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// Root-mean-square level of a buffer's first channel, 0…1, for a level meter.
public func audioLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    let n = Int(buffer.frameLength)
    for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
    let rms = (sum / Float((n + 3) / 4)).squareRoot()
    // -50 dB…0 dB mapped to 0…1.
    let db = 20 * log10(max(rms, 1e-6))
    return max(0, min(1, (db + 50) / 50))
}

// MARK: - Microphone

/// Captures the default input device directly with a Core Audio IOProc.
///
/// Not AVAudioEngine: on macOS its input node builds a private aggregate of the default input *and output*
/// devices, and running that alongside the system-audio tap (whose aggregate also uses the output device)
/// in the same process stalls the tap: it starts but never delivers audio.
public final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "unremarkable.microphone", qos: .userInitiated)

    public init() {}

    public func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        deviceID = try Self.defaultInputDevice()
        let format = try Self.inputFormat(deviceID)
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            guard let buffer = SystemAudioSource.tapBuffer(input, format: format, firstStream: true) else { return }
            if format.channelCount > 1, let mono, let m = buffer.firstChannel(as: mono) { onBuffer(m) } else { onBuffer(buffer) }
        }
        guard status == noErr else { throw RMError.malformed("Couldn't open the microphone (Core Audio error \(status))") }
        let started = AudioDeviceStart(deviceID, procID)
        guard started == noErr else {
            stop()
            throw RMError.malformed("Couldn't start the microphone (Core Audio error \(started))")
        }
    }

    public func stop() {
        if deviceID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    static func inputFormat(_ device: AudioObjectID) throws -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &asbd) == noErr,
              let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0, format.channelCount > 0 else {
            throw RMError.malformed("No microphone is available")
        }
        return format
    }

    static func defaultInputDevice() throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else {
            throw RMError.malformed("No microphone is available")
        }
        return device
    }
}

// MARK: - System audio (Core Audio process tap, macOS 14.2+)

/// Captures everything the Mac plays (the other people on a call) except this app's own audio.
///
/// - Needs the System Audio Recording permission (`AudioPermission.requestSystemAudio()`); without it the
///   tap starts but never delivers.
/// - A tap alone only delivers while something is playing. With `microphone` set, the aggregate is clocked
///   by the mic and runs continuously, delivering both sides in sync. Meetings always use it that way.
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "unremarkable.systemaudio", qos: .userInitiated)

    /// When set, the microphone is captured by the same aggregate device as the tap, clocked by the mic.
    /// Running a separate microphone capture alongside the tap in one process stalls the tap on macOS 26,
    /// so meetings record both sides through this one device.
    public var microphone: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public init() {}

    public func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let debug = ProcessInfo.processInfo.environment["UNREMARKABLE_AUDIO_DEBUG"] != nil
        let ownProcess = try Self.processObject(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Un-remarkable meeting audio"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        let outputUID = try Self.defaultOutputUID()
        var config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Un-remarkable Meeting Tap",
            kAudioAggregateDeviceUIDKey: "com.unremarkable.mac.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var micFormat: AVAudioFormat?
        if microphone != nil {
            let input = try MicrophoneSource.defaultInputDevice()
            let inputUID = try Self.deviceUID(input)
            config[kAudioAggregateDeviceMainSubDeviceKey] = inputUID
            config[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: inputUID]]
            micFormat = try MicrophoneSource.inputFormat(input)
        } else {
            config[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            config[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "create the capture device")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read the tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw RMError.malformed("Unsupported system audio format") }
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)

        if debug { FileHandle.standardError.write(Data("AUDIO tap format: \(format), permission \(AudioPermission.systemAudioStatus())\n".utf8)) }
        let calls = Counter()
        let micHandler = microphone
        let micMono = micFormat.flatMap { AVAudioFormat(standardFormatWithSampleRate: $0.sampleRate, channels: 1) }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            if debug, calls.increment() == 1 {
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let desc = list.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",")
                FileHandle.standardError.write(Data("AUDIO tap first callback: \(list.count) buffers [\(desc)]\n".utf8))
            }
            if let micHandler, let micFormat, UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).count > 1,
               let mic = Self.tapBuffer(input, format: micFormat, firstStream: true) {
                if micFormat.channelCount > 1, let micMono, let m = mic.firstChannel(as: micMono) { micHandler(m) } else { micHandler(mic) }
            }
            guard let buffer = Self.tapBuffer(input, format: format) else { return }
            if format.channelCount > 1, let mono, let m = buffer.firstChannel(as: mono) { onBuffer(m) } else { onBuffer(buffer) }
        }, "start capturing")
        try check(AudioDeviceStart(aggregateID, procID), "start the capture device")
        if debug {
            FileHandle.standardError.write(Data("AUDIO aggregate: input channels \(Self.inputChannels(aggregateID)), running \(Self.isRunning(aggregateID)), output device \(outputUID)\n".utf8))
        }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw RMError.malformed("Couldn't \(what) (Core Audio error \(status))") }
    }

    private static func processObject(for pid: pid_t) throws -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Copies the tap's audio out of the aggregate's input. The aggregate lists its sub-device streams first
    /// and the tap last; other streams can appear (voice processing adds one to the output device), so
    /// take the last stream that matches the tap format.
    static func tapBuffer(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat, firstStream: Bool = false) -> AVAudioPCMBuffer? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let channels = format.isInterleaved ? format.channelCount : 1
        let match: (AudioBuffer) -> Bool = { $0.mNumberChannels == channels && $0.mData != nil }
        guard let stream = firstStream ? list.first(where: match) : list.last(where: match), let src = stream.mData else { return nil }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(Int(stream.mDataByteSize) / bytesPerFrame)
        guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        out.frameLength = frames
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        if format.isInterleaved, let d = dst[0].mData {
            memcpy(d, src, Int(frames) * bytesPerFrame)
        } else {
            // Planar: one stream per channel (the tap's are last, a device's first).
            let streams = firstStream ? Array(list.prefix(Int(format.channelCount))) : Array(list.suffix(Int(format.channelCount)))
            for (i, s) in streams.enumerated() where i < dst.count {
                if let d = dst[i].mData, let sp = s.mData { memcpy(d, sp, Int(min(s.mDataByteSize, dst[i].mDataByteSize))) }
            }
        }
        return out
    }

    static func inputChannels(_ device: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return -1 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return -1 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func isRunning(_ device: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
        return running != 0
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let uid else {
            throw RMError.malformed("Audio device has no identifier")
        }
        return uid.takeRetainedValue() as String
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else {
            throw RMError.malformed("No audio output device")
        }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let uid else {
            throw RMError.malformed("No audio output device")
        }
        return uid.takeRetainedValue() as String
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.withLock { n += 1; return n } }
}

extension AVAudioPCMBuffer {
    /// Copies the first channel into a new mono buffer (non-interleaved float input only).
    func firstChannel(as mono: AVAudioFormat, average: Bool = true) -> AVAudioPCMBuffer? {
        guard let src = floatChannelData, !format.isInterleaved,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frameLength), let dst = out.floatChannelData else {
            // Interleaved stereo: average the channels.
            guard format.isInterleaved, let raw = audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self),
                  format.commonFormat == .pcmFormatFloat32,
                  let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frameLength), let dst = out.floatChannelData else { return nil }
            let ch = Int(format.channelCount)
            for i in 0..<Int(frameLength) {
                var s: Float = 0
                for c in 0..<ch { s += raw[i * ch + c] }
                dst[0][i] = s / Float(ch)
            }
            out.frameLength = frameLength
            return out
        }
        // Average the channels: a call may be panned or on one side only.
        let ch = Int(format.channelCount), n = Int(frameLength)
        memcpy(dst[0], src[0], n * MemoryLayout<Float>.size)
        if ch > 1, average {
            for c in 1..<ch { for i in 0..<n { dst[0][i] += src[c][i] } }
            let scale = 1 / Float(ch)
            for i in 0..<n { dst[0][i] *= scale }
        }
        out.frameLength = frameLength
        return out
    }
}

// MARK: - File (development and tests)

/// Plays an audio file into the pipeline in real time, standing in for a microphone or call audio.
public final class FileAudioSource: AudioSource, @unchecked Sendable {
    private let url: URL
    private let delay: TimeInterval
    private var thread: Thread?

    public init(url: URL, delay: TimeInterval = 0) {
        self.url = url
        self.delay = delay
    }

    public func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        let delay = self.delay
        let t = Thread {
            Thread.sleep(forTimeInterval: delay)
            while !Thread.current.isCancelled, file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk), (try? file.read(into: buf, frameCount: chunk)) != nil else { break }
                onBuffer(buf)
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread = t
        t.start()
    }

    public func stop() { thread?.cancel() }
}
