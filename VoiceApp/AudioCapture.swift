import AVFoundation
import Foundation

struct LiveAudioSlice {
    let samples: [Float]
    let startFrame: Int
    let skippedFrames: Int
    var restartStream = false
}

struct MicrophoneSnapshot: Sendable {
    let level: Float
    let decibels: Float
    let receivedBuffers: Int
    let convertedFrames: Int
    let inputName: String
}

// The audio callback measures the actual input before conversion. The held peak
// survives until the UI polls it, so short taps are visible rather than missed.
final class AudioCapture: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var heldPeak: Float = 0
    private var receivedBuffers = 0
    private var convertedFrames = 0
    private var inputName = "Microphone"
    private var captureError: String?
    private var tapped = false
    private var firstBufferedFrame = 0
    private var lastReadFrame = 0
    private var paused = false
    private var muted = false
    private var ambient = false
    private var ambientGain: Float = 1
    private var restartRequested = false
    #if DEBUG
    private var fixtureTask: Task<Void, Never>?
    #endif
    private var audioSink: (@Sendable ([Float]) -> Void)?

    private func reset() {
        lock.lock(); defer { lock.unlock() }
        samples = []; firstBufferedFrame = 0; lastReadFrame = 0; heldPeak = 0; receivedBuffers = 0; convertedFrames = 0; captureError = nil
    }

    func start(audioSink: (@Sendable ([Float]) -> Void)? = nil) throws {
        self.audioSink = audioSink
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--microphone-fixture") {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("streaming-fixture.wav")
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else { throw CaptionError.message("Fixture must be 16-kHz mono.") }
            let data = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: data)
            let values = Array(UnsafeBufferPointer(start: data.floatChannelData![0], count: Int(data.frameLength)))
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let (target, converter) = try Self.makeConverter(format)
            reset(); inputName = "Test audio fixture"
            fixtureTask = Task.detached { [weak self] in
                var offset = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    let count = min(1600, values.count - offset)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                    buffer.frameLength = AVAudioFrameCount(count)
                    for i in 0..<count { buffer.floatChannelData![0][i] = values[offset + i] }
                    self.consume(buffer, target: target, converter: converter)
                    offset = (offset + count) % values.count
                    try? await Task.sleep(nanoseconds: UInt64(Double(count) / 16000 * 1_000_000_000))
                }
            }
            return
        }
        #endif
        let engine = AVAudioEngine(); self.engine = engine
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(false) }
        if ambient, let port = session.currentRoute.inputs.first, port.portType == .builtInMic,
           let source = port.dataSources?.first(where: { $0.supportedPolarPatterns?.contains(.omnidirectional) == true }) {
            try? source.setPreferredPolarPattern(.omnidirectional)
            try? port.setPreferredDataSource(source)
        }
        let format = input.outputFormat(forBus: 0)
        let (target, converter) = try Self.makeConverter(format)
        reset()
        lock.lock()
        inputName = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, target: target, converter: converter)
        }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch { stop(); throw error }
    }

    private static func makeConverter(_ format: AVAudioFormat) throws -> (AVAudioFormat, AVAudioConverter) {
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw CaptionError.message("No microphone is available. Check the audio input and try again.")
        }
        // USB interfaces may carry the microphone only on the right channel.
        converter.downmix = true
        return (target, converter)
    }

    func setControls(paused: Bool, muted: Bool, ambient: Bool) {
        lock.lock(); defer { lock.unlock() }
        if self.paused && !paused { restartRequested = true }
        self.paused = paused; self.muted = muted; self.ambient = ambient
        if paused || muted { heldPeak = 0 }
    }
    private func consume(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat, converter: AVAudioConverter) {
        lock.lock()
        let paused = self.paused, muted = self.muted, ambient = self.ambient
        lock.unlock()
        guard !paused else { return }
        var peak: Float = 0
        if let channels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let stride = buffer.format.isInterleaved ? channelCount : 1
            for channel in 0..<channelCount {
                let data = channels[buffer.format.isInterleaved ? 0 : channel]
                let offset = buffer.format.isInterleaved ? channel : 0
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[frame * stride + offset])) }
            }
        }
        lock.lock(); heldPeak = muted ? 0 : max(heldPeak, peak); receivedBuffers += 1; lock.unlock()
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        lock.lock(); defer { lock.unlock() }
        if let error { captureError = "Microphone audio conversion failed: \(error.localizedDescription)"; return }
        guard let channel = output.floatChannelData?[0] else { return }
        var values = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        if muted { values = [Float](repeating: 0, count: values.count) }
        else if ambient && !values.isEmpty {
            let rms = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
            let desired = min(6, max(1, 0.055 / max(rms, 0.002)))
            ambientGain = ambientGain * 0.8 + desired * 0.2
            values = values.map { max(-0.98, min(0.98, $0 * ambientGain)) }
        } else { ambientGain = 1 }
        convertedFrames += values.count
        // Persist every frame independently, even when recognition is slow.
        audioSink?(values)
        samples.append(contentsOf: values)
        if samples.count > 32000 {
            let discard = samples.count - 16000
            samples.removeFirst(discard); firstBufferedFrame += discard
        }
    }

    func takeLatest(final: Bool = false) throws -> LiveAudioSlice? {
        lock.lock(); defer { lock.unlock() }
        if let captureError { throw CaptionError.message(captureError) }
        let count = final ? min(samples.count, 1600) : 1600
        guard count > 0, samples.count >= count else { return nil }
        let start = firstBufferedFrame
        let result = LiveAudioSlice(samples: Array(samples.prefix(count)), startFrame: start, skippedFrames: max(0, start - lastReadFrame), restartStream: restartRequested)
        samples.removeFirst(count); firstBufferedFrame += count; lastReadFrame = firstBufferedFrame; restartRequested = false
        return result
    }

    func take(final: Bool = false) throws -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if let captureError { throw CaptionError.message(captureError) }
        let count = final ? min(samples.count, 1600) : 1600
        guard count > 0, samples.count >= count else { return nil }
        let result = Array(samples.prefix(count))
        samples.removeFirst(count); firstBufferedFrame += count; lastReadFrame = firstBufferedFrame
        return result
    }

    func microphoneSnapshot() -> MicrophoneSnapshot {
        lock.lock(); defer { lock.unlock() }
        let db = max(-60, min(0, 20 * log10(max(heldPeak, 0.000001))))
        heldPeak = 0
        return MicrophoneSnapshot(level: (db + 60) / 60, decibels: db, receivedBuffers: receivedBuffers,
                                  convertedFrames: convertedFrames, inputName: inputName.isEmpty ? "Microphone" : inputName)
    }

    func stop() {
        #if DEBUG
        fixtureTask?.cancel(); fixtureTask = nil
        #endif
        engine?.stop()
        if tapped { engine?.inputNode.removeTap(onBus: 0); tapped = false }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    #if DEBUG
    static func conversionSmokeTest() throws -> Bool {
        // Exercise the same callback/converter path with common Mac input formats.
        for (rate, channels) in [(48000.0, AVAudioChannelCount(2)), (44100.0, AVAudioChannelCount(1)), (16000.0, AVAudioChannelCount(1))] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
            let (target, converter) = try makeConverter(format)
            let capture = AudioCapture()
            let frames = AVAudioFrameCount(rate / 10)
            for block in 0..<10 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                for ch in 0..<Int(channels) {
                    for i in 0..<Int(frames) {
                        buffer.floatChannelData![ch][i] = (channels == 2 && ch == 0 ? 0 : 0.1) * sin(Float(2 * Double.pi * 440 * Double(block * Int(frames) + i) / rate))
                    }
                }
                capture.consume(buffer, target: target, converter: converter)
            }
            let snapshot = capture.microphoneSnapshot()
            guard snapshot.receivedBuffers == 10, snapshot.convertedFrames > 15000,
                  abs(snapshot.decibels - (-20)) < 0.2, snapshot.level > 0.6 else { return false }
            var output: [Float] = []
            while let block = try capture.take(final: true) { output += block }
            let rms = sqrt(output.reduce(Float(0)) { $0 + $1 * $1 } / Float(output.count))
            guard rms > 0.02, rms < 0.09, capture.microphoneSnapshot().level == 0 else { return false }
        }
        return true
    }
    #endif
}

#if DEBUG
extension AudioCapture {
    static func backlogRecordingSmokeTest() async throws -> Bool {
        let recorder = RefinementAudio()
        try await recorder.start()
        let capture = AudioCapture()
        capture.audioSink = { recorder.enqueue($0) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let (target, converter) = try makeConverter(format)
        // Simulate a decoder doing no work for twelve seconds. Disk capture
        // must retain the whole recording while live input retains the latest.
        for block in 0..<120 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(block * 1600 + i) * 0.1) }
            capture.consume(buffer, target: target, converter: converter)
        }
        let slice = try capture.takeLatest()
        guard let url = await recorder.close() else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = try AVAudioFile(forReading: url)
        return saved.length == 192000 && slice != nil && slice!.startFrame >= 160000 && slice!.skippedFrames > 0 && slice!.samples.count == 1600
    }
}
#endif

#if DEBUG
extension AudioCapture {
    static func controlSmokeTest() async throws -> Bool {
        let recorder = RefinementAudio(); try await recorder.start()
        let capture = AudioCapture(); capture.audioSink = { recorder.enqueue($0) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let (target, converter) = try makeConverter(format)
        func feed(_ count: Int) {
            for _ in 0..<count {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
                buffer.frameLength = 1600
                for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.002 * sin(Float(i) * 0.1) }
                capture.consume(buffer, target: target, converter: converter)
            }
        }
        func drain() throws -> [Float] {
            var values: [Float] = []
            while let block = try capture.takeLatest(final: true) { values += block.samples }
            return values
        }
        func rms(_ samples: [Float]) -> Float { sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))) }
        feed(10); let normal = rms(try drain())
        capture.setControls(paused: false, muted: false, ambient: true); feed(10)
        let ambient = rms(try drain())
        capture.setControls(paused: false, muted: true, ambient: true); feed(10)
        let muted = rms(try drain()); let before = capture.microphoneSnapshot().convertedFrames
        capture.setControls(paused: true, muted: true, ambient: true); feed(5)
        let paused = capture.microphoneSnapshot().convertedFrames == before
        capture.setControls(paused: false, muted: false, ambient: false); feed(1)
        let resumed = try capture.takeLatest()?.restartStream == true
        guard let url = await recorder.close() else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try AVAudioFile(forReading: url)
        return ambient > normal * 3 && muted == 0 && paused && resumed && audio.length == 49600
    }
}
#endif
