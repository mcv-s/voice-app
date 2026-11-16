import Foundation
import Moonshine

// Native portable C API; one model and stream at a time, off the UI/audio threads.
actor MoonshineRecognizer {
    private var transcriber: Int32 = -1
    private var stream: Int32 = -1
    private var pendingFrames = 0
    private var text = ""
    private var finished = false
    private var lines: [RecognitionLine] = []

    func start(model: CaptionModel) throws {
        guard ModelCatalog.installed(model), let arch = model.spec?.arch else {
            throw CaptionError.message("Download \(model.title) in Settings → Models first.")
        }
        var settings = [("vad_max_segment_duration", "10")]
        if UserDefaults.standard.bool(forKey: "betaSpeakers"), ModelCatalog.installed(.speakers) {
            settings += [("identify_speakers", "true"), ("diarization_model_dir", ModelCatalog.directory(.speakers).path),
                         ("diarization_cluster_window_sec", "30"), ("diarization_cluster_cadence", "3")]
        }
        let strings = settings.flatMap { [strdup($0.0)!, strdup($0.1)!] }
        defer { strings.forEach { free($0) } }
        let options = settings.indices.map { moonshine_option_t(name: UnsafePointer(strings[$0 * 2]), value: UnsafePointer(strings[$0 * 2 + 1])) }
        transcriber = ModelCatalog.directory(model).path.withCString { path in
            options.withUnsafeBufferPointer { moonshine_load_transcriber_from_files(path, arch, $0.baseAddress, UInt64($0.count), MOONSHINE_HEADER_VERSION) }
        }
        guard transcriber >= 0 else { throw failure(transcriber) }
        try resetStream()
    }
    func resetStream() throws {
        if stream >= 0 { moonshine_free_stream(transcriber, stream) }
        stream = moonshine_create_stream(transcriber, 0)
        guard stream >= 0 else { throw failure(stream) }
        try check(moonshine_start_stream(transcriber, stream))
        pendingFrames = 0; text = ""; lines = []; finished = false
    }
    func accept(_ samples: [Float], final: Bool) throws -> CaptionResult {
        guard stream >= 0, !finished else { throw CaptionError.message("No active Moonshine stream.") }
        let start = Date()
        if !samples.isEmpty {
            try samples.withUnsafeBufferPointer {
                try check(moonshine_transcribe_add_audio_to_stream(transcriber, stream, $0.baseAddress, UInt64($0.count), 16000, 0))
            }
            pendingFrames += samples.count
        }
        // Decode every 300 ms of audio. Never repeatedly encode a sliding window.
        if final || pendingFrames >= 4800 {
            if final { try check(moonshine_stop_stream(transcriber, stream)); finished = true }
            var result: UnsafeMutablePointer<transcript_t>?
            try check(moonshine_transcribe_stream(transcriber, stream, 0, &result))
            if let result, let lines = result.pointee.lines {
                self.lines = (0..<Int(result.pointee.line_count)).map { index in
                    let line = lines[index]
                    let speaker: Int?
                    if let spans = line.speaker_spans, line.speaker_span_count > 0 {
                        let all = UnsafeBufferPointer(start: spans, count: Int(line.speaker_span_count))
                        speaker = all.max(by: { $0.duration < $1.duration }).map { Int($0.speaker_index) }
                    } else { speaker = nil }
                    return RecognitionLine(id: "moon-\(line.id)", text: line.text.map { String(cString: $0) } ?? "",
                                           start: Double(line.start_time), end: Double(line.start_time + line.duration),
                                           complete: line.is_complete != 0 || final, speaker: speaker)
                }.filter { !$0.text.isEmpty }
                text = self.lines.map(\.text).joined(separator: "\n")
            }
            pendingFrames = 0
        }
        return CaptionResult(text: text, decodeSeconds: Date().timeIntervalSince(start), lines: lines)
    }
    private func check(_ code: Int32) throws { if code != 0 { throw failure(code) } }
    private func failure(_ code: Int32) -> CaptionError {
        let message = moonshine_error_to_string(code).map { String(cString: $0) } ?? "Error \(code)"
        return .message("Moonshine: \(message)")
    }
    deinit {
        if stream >= 0 { moonshine_free_stream(transcriber, stream) }
        if transcriber >= 0 { moonshine_free_transcriber(transcriber) }
    }
}
