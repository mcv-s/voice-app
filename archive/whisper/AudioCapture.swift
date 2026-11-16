import AVFoundation
import Foundation

// The real-time callback only converts and copies samples into a bounded buffer.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var meter: Float = 0
    private var overflow = false
    private var tapped = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw VoiceError.message("No microphone is available. Check the audio input and try again.")
        }
        lock.lock(); samples = []; overflow = false; meter = 0; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let channel = output.floatChannelData?[0] else { return }
            let values = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let rms = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(values.count, 1)))
            self.lock.lock()
            self.meter = min(1, rms * 15)
            if self.samples.count + values.count <= 16000 * 60 { self.samples.append(contentsOf: values) }
            else { self.overflow = true }
            self.lock.unlock()
        }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch { stop(); throw error }
    }

    func take(final: Bool = false) throws -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if overflow { throw VoiceError.message("Whisper can't keep up on this device. Try the faster Tiny model or shorter recordings.") }
        let count = final ? min(samples.count, 80000) : 80000
        guard count > 0, samples.count >= count else { return nil }
        let result = Array(samples.prefix(count))
        samples.removeFirst(count)
        return result
    }
    var level: Float { lock.lock(); defer { lock.unlock() }; return meter }
    func stop() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
