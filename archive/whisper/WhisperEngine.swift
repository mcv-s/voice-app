import Foundation
import whisper

// All inference and context ownership stay on this actor, away from the UI/audio thread.
actor WhisperEngine {
    private var context: OpaquePointer?
    private var loadedPath: String?

    func load(_ url: URL) throws {
        if loadedPath == url.path { return }
        if let context { whisper_free(context) }
        context = nil
        loadedPath = nil
        var params = whisper_context_default_params()
        // CPU works on A11 (iPhone X) and Simulator; avoids requiring newer Metal features.
        params.use_gpu = false
        context = url.path.withCString { whisper_init_from_file_with_params($0, params) }
        guard context != nil else { throw VoiceError.message("Whisper couldn't load this model. Remove it and download again.") }
        loadedPath = url.path
    }

    func transcribe(_ samples: [Float]) throws -> String {
        guard let context else { throw VoiceError.message("Download a model first.") }
        guard samples.count >= 1600 else { return "" }
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        guard energy > 0.00001 else { return "" }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        return try "en".withCString { language in
            params.language = language
            let code = samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
            guard code == 0 else { throw VoiceError.message("Whisper couldn't process this audio (\(code)).") }
            return (0..<whisper_full_n_segments(context)).map { String(cString: whisper_full_get_segment_text(context, $0)) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    deinit { if let context { whisper_free(context) } }
}

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
