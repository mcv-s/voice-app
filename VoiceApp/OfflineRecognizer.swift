import AVFoundation
import Foundation
import SherpaOnnxC

// Batch models are used after Stop. They are never presented as low-latency engines.
actor OfflineRecognizer {
    func refine(audio url: URL, model: CaptionModel) async throws -> String {
        if model.spec?.family == "whisper" {
            return try await TranscriptRefiner().refine(audio: url, model: ModelCatalog.file(model, role: "model"))
        }
        if model.spec?.family == "moonshine" {
            let decoder = MoonshineRecognizer()
            try await decoder.start(model: model)
            let audio = try AVAudioFile(forReading: url)
            while audio.framePosition < audio.length {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(16000, audio.length - audio.framePosition))
                let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count)!
                try audio.read(into: buffer)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                _ = try await decoder.accept(samples, final: false)
            }
            let text = try await decoder.accept([], final: true).text
            guard !text.isEmpty else { throw CaptionError.message("No refined speech found. Original text kept.") }
            return text
        }
        guard let spec = model.spec else { throw CaptionError.message("Choose a saved-text model.") }
        var strings: [UnsafeMutablePointer<CChar>] = []
        func string(_ value: String) -> UnsafePointer<CChar> { let p = strdup(value)!; strings.append(p); return UnsafePointer(p) }
        func path(_ role: String) throws -> UnsafePointer<CChar> { string(try ModelCatalog.file(model, role: role).path) }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = spec.featureDim
        config.model_config.num_threads = 2; config.model_config.provider = string("cpu")
        config.decoding_method = string("greedy_search")
        switch spec.family {
        case "offlineTransducer":
            config.model_config.transducer.encoder = try path("encoder")
            config.model_config.transducer.decoder = try path("decoder")
            config.model_config.transducer.joiner = try path("joiner")
            config.model_config.tokens = try path("tokens")
            config.model_config.model_type = string("nemo_transducer")
        case "offlineCTC":
            config.model_config.nemo_ctc.model = try path("model")
            config.model_config.tokens = try path("tokens")
        case "senseVoice":
            config.model_config.sense_voice.model = try path("model")
            config.model_config.sense_voice.language = string("en")
            config.model_config.sense_voice.use_itn = 1
            config.model_config.tokens = try path("tokens")
        case "qwen":
            config.model_config.qwen3_asr.conv_frontend = try path("frontend")
            config.model_config.qwen3_asr.encoder = try path("encoder")
            config.model_config.qwen3_asr.decoder = try path("decoder")
            config.model_config.qwen3_asr.tokenizer = string(ModelCatalog.directory(model).appendingPathComponent("tokenizer").path)
            config.model_config.qwen3_asr.max_total_len = 512
            config.model_config.qwen3_asr.max_new_tokens = 256
            config.model_config.qwen3_asr.temperature = 0.000001
            config.model_config.qwen3_asr.top_p = 0.8
            config.model_config.qwen3_asr.seed = 42
        default: throw CaptionError.message("Unsupported saved-text model.")
        }
        try Task.checkCancellation()
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else { throw CaptionError.message("Couldn't load \(model.title). Original text kept.") }
        defer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
        let audio = try AVAudioFile(forReading: url)
        var parts: [String] = []
        // Overlap windows and align recognized words at joins, retaining boundary speech.
        let window: Int64 = 16000 * 25, overlap: Int64 = 16000 * 3
        var offset: Int64 = 0
        while offset < audio.length {
            try Task.checkCancellation()
            audio.framePosition = offset
            let count = AVAudioFrameCount(min(window, audio.length - offset))
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count)!
            try audio.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0], let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw CaptionError.message("Couldn't read recording.") }
            defer { SherpaOnnxDestroyOfflineStream(stream) }
            SherpaOnnxAcceptWaveformOffline(stream, 16000, channel, Int32(buffer.frameLength))
            SherpaOnnxDecodeOfflineStream(recognizer, stream)
            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw CaptionError.message("Couldn't read recognition result.") }
            let text = result.pointee.text.map { String(cString: $0) } ?? ""
            SherpaOnnxDestroyOfflineRecognizerResult(result)
            parts.append(text)
            if offset + Int64(count) >= audio.length { break }
            offset += window - overlap
        }
        try Task.checkCancellation()
        let text = TranscriptJoiner.join(parts)
        guard !text.isEmpty else { throw CaptionError.message("No refined speech found. Original text kept.") }
        return text
    }
}

enum TranscriptJoiner {
    static func join(_ parts: [String]) -> String {
        var words: [String] = []
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        for part in parts {
            let next = part.split(whereSeparator: \.isWhitespace).map(String.init)
            let limit = min(60, min(words.count, next.count))
            var match = 0
            if limit >= 2 {
                for length in stride(from: limit, through: 2, by: -1) {
                    if words.suffix(length).map(normalized) == next.prefix(length).map(normalized) { match = length; break }
                }
            }
            words.append(contentsOf: next.dropFirst(match))
        }
        return words.joined(separator: " ")
    }
}
