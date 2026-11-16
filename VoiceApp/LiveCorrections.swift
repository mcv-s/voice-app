import AVFoundation
import Foundation
import whisper

struct LiveCaptionBlock: Identifiable, Equatable {
    let id: String
    var original: String
    var text: String
    var start: Double
    var end: Double
    var complete: Bool
    var corrected = false
    var speaker: Int? = nil
}

struct CaptionTimeline {
    private(set) var blocks: [LiveCaptionBlock] = []
    private var queued: Set<String> = []
    var text: String { blocks.map(\.text).joined(separator: "\n") }
    var original: String { blocks.map(\.original).joined(separator: "\n") }
    mutating func update(_ lines: [RecognitionLine], sentenceCase: Bool) -> [RecognitionLine] {
        var ready: [RecognitionLine] = []
        for line in lines {
            let raw = sentenceCase ? CaptionFormatter.sentenceCase(line.text) : line.text
            if let index = blocks.firstIndex(where: { $0.id == line.id }) {
                // Completed paragraphs never revert when another partial hypothesis arrives.
                if !blocks[index].complete {
                    blocks[index].original = raw; blocks[index].text = raw
                    blocks[index].complete = line.complete; blocks[index].end = line.end
                    blocks[index].speaker = line.speaker
                }
            } else { blocks.append(LiveCaptionBlock(id: line.id, original: raw, text: raw, start: line.start, end: line.end, complete: line.complete, speaker: line.speaker)) }
            if let index = blocks.firstIndex(where: { $0.id == line.id }) { blocks[index].speaker = line.speaker }
            if line.complete, !queued.contains(line.id) { queued.insert(line.id); ready.append(line) }
        }
        return ready
    }
    mutating func correct(id: String, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = blocks.firstIndex(where: { $0.id == id }), blocks[index].complete else { return }
        blocks[index].text = cleaned; blocks[index].corrected = true
    }
}

// The decoder keeps one context for the session. It never runs on the microphone
// or main thread. Only completed paragraphs enter the serial correction queue.
actor WhisperCorrectionWorker {
    private var context: OpaquePointer?
    func start(model: CaptionModel) throws {
        stop()
        guard model.spec?.family == "whisper" else { throw CaptionError.message("Choose a Whisper model for live corrections.") }
        let url = try ModelCatalog.file(model, role: "model")
        var params = whisper_context_default_params(); params.use_gpu = false
        context = url.path.withCString { whisper_init_from_file_with_params($0, params) }
        guard context != nil else { throw CaptionError.message("Couldn't load Whisper for live corrections.") }
    }
    func correct(audio url: URL) throws -> String {
        guard let context else { throw CaptionError.message("Whisper corrections aren't running.") }
        let audio = try AVAudioFile(forReading: url)
        var parts: [String] = []
        var offset: Int64 = 0
        while offset < audio.length {
            try Task.checkCancellation()
            audio.framePosition = offset
            let count = AVAudioFrameCount(min(16000 * 30, audio.length - offset))
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count)!
            try audio.read(into: buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = 2
            params.no_context = true; params.no_timestamps = true
            params.print_realtime = false; params.print_progress = false
            params.print_timestamps = false; params.print_special = false
            let text = try "en".withCString { language -> String in
                params.language = language
                guard whisper_full(context, params, samples, Int32(buffer.frameLength)) == 0 else { throw CaptionError.message("Whisper correction failed; original captions kept.") }
                return (0..<whisper_full_n_segments(context)).map { String(cString: whisper_full_get_segment_text(context, $0)) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !text.isEmpty { parts.append(text) }
            if offset + Int64(count) >= audio.length { break }
            offset += 16000 * 27
        }
        return TranscriptJoiner.join(parts)
    }
    func stop() { if let context { whisper_free(context) }; context = nil }
    deinit { if let context { whisper_free(context) } }
}

struct CorrectionJob: Sendable {
    let id: String
    let audio: URL
}
