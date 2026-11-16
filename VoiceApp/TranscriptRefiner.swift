import AVFoundation
import CryptoKit
import Foundation
import whisper

// Disk writes are independent of decoding. Every converted microphone frame is
// queued here before the live-caption buffer is allowed to discard stale audio.
final class RefinementAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voice-app.audio-files", qos: .userInitiated)
    private var file: AVAudioFile?
    private var url: URL?
    private var failure: String?
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceAppRefinement", isDirectory: true)
    func start(at destination: URL? = nil) async throws {
        try await perform {
            self.file = nil; self.failure = nil
            let url = destination ?? Self.directory.appendingPathComponent(UUID().uuidString + ".caf")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            self.file = try AVAudioFile(forWriting: url, settings: format.settings); self.url = url
        }
    }
    func enqueue(_ samples: [Float]) {
        queue.async { do { try self.write(samples) } catch { self.failure = error.localizedDescription } }
    }
    func append(_ samples: [Float]) async throws { try await perform { try self.write(samples) } }
    private func write(_ samples: [Float]) throws {
        if let failure { throw CaptionError.message(failure) }
        guard let file, !samples.isEmpty else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
    func recordingError() async -> String? { await withCheckedContinuation { c in queue.async { c.resume(returning: self.failure) } } }
    func snapshot(start: Double, end: Double) async throws -> URL? {
        try await perform {
            guard let url = self.url, let file = self.file else { return nil }
            let first = max(0, Int64(start * 16000)), last = min(file.length, Int64(end * 16000))
            guard last > first else { return nil }
            let reader = try AVAudioFile(forReading: url); reader.framePosition = first
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let destination = Self.directory.appendingPathComponent("correction-" + UUID().uuidString + ".caf")
            do {
                let writer = try AVAudioFile(forWriting: destination, settings: file.processingFormat.settings)
                var remaining = last - first
                while remaining > 0 {
                    let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(min(remaining, 80000)))!
                    try reader.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw CaptionError.message("Couldn't read correction audio.") }
                    try writer.write(from: buffer); remaining -= Int64(buffer.frameLength)
                }
                return destination
            } catch { try? FileManager.default.removeItem(at: destination); throw error }
        }
    }
    func close() async -> URL? {
        await withCheckedContinuation { c in queue.async { self.file = nil; let url = self.url; self.url = nil; c.resume(returning: url) } }
    }
    private func perform<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async { do { c.resume(returning: try operation()) } catch { c.resume(throwing: error) } } }
    }
}

@MainActor
final class RefinementSettings: ObservableObject {
    @Published var enabled = UserDefaults.standard.bool(forKey: "betaSavedTextPass") {
        didSet { UserDefaults.standard.set(enabled, forKey: "betaSavedTextPass") }
    }
    @Published var selectedModel = CaptionModel(rawValue: UserDefaults.standard.string(forKey: "refinementModel") ?? "") ?? .whisperBase {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "refinementModel") }
    }
    @Published var liveEnabled = UserDefaults.standard.object(forKey: "liveWhisperCorrections") as? Bool ?? false {
        didSet { UserDefaults.standard.set(liveEnabled, forKey: "liveWhisperCorrections") }
    }
    @Published var liveModel = CaptionModel(rawValue: UserDefaults.standard.string(forKey: "liveWhisperModel") ?? "") ?? .whisperBase {
        didSet { UserDefaults.standard.set(liveModel.rawValue, forKey: "liveWhisperModel") }
    }
    var installed: Bool { ModelCatalog.installed(selectedModel) }
    init() {
        // Earlier versions enabled correction implicitly. Require a fresh opt-in.
        if !UserDefaults.standard.bool(forKey: "correctionOptInV2") {
            liveEnabled = false; enabled = false
            UserDefaults.standard.set(true, forKey: "correctionOptInV2")
        }
        if UserDefaults.standard.string(forKey: "refinementModel") == nil, ModelCatalog.installed(.whisperBaseFull) { selectedModel = .whisperBaseFull }
    }
}

actor TranscriptRefiner {
    // Context exists only while refining and is released when done or cancelled.
    func refine(audio url: URL, model: URL) throws -> String {
        try Task.checkCancellation()
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = false
        guard let context = model.path.withCString({ whisper_init_from_file_with_params($0, contextParams) }) else {
            throw CaptionError.message("Couldn't load Whisper. Live captions are preserved.")
        }
        defer { whisper_free(context) }
        let audio = try AVAudioFile(forReading: url)
        var parts: [String] = []
        var offset: Int64 = 0
        // Longer windows provide more context than the live streaming recognizer.
        while offset < audio.length {
            audio.framePosition = offset
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(16000 * 30, audio.length - audio.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count) else { break }
            try audio.read(into: buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            let n = Int(buffer.frameLength)
            let energy = (0..<n).reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(n)
            let lastWindow = offset + Int64(count) >= audio.length
            offset += 16000 * 27
            if energy <= 0.0000001 { if lastWindow { break }; continue }
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = 2
            params.no_context = true
            params.no_timestamps = true
            params.print_realtime = false; params.print_progress = false
            params.print_timestamps = false; params.print_special = false
            let part: String = try "en".withCString { language in
                params.language = language
                guard whisper_full(context, params, samples, Int32(n)) == 0 else { throw CaptionError.message("Refinement failed. Live captions are preserved.") }
                return (0..<whisper_full_n_segments(context)).map { String(cString: whisper_full_get_segment_text(context, $0)) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !part.isEmpty { parts.append(part) }
            if lastWindow { break }
        }
        try Task.checkCancellation()
        let text = TranscriptJoiner.join(parts)
        guard !text.isEmpty else { throw CaptionError.message("No refined speech found. Live captions are preserved.") }
        return text
    }
}
