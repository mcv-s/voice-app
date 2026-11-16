import Foundation
import SherpaOnnxC

struct RecognitionLine: Identifiable, Sendable {
    let id: String
    let text: String
    let start: Double
    let end: Double
    let complete: Bool
    var speaker: Int? = nil
}

struct CaptionResult: Sendable {
    let text: String
    let decodeSeconds: Double
    var lines: [RecognitionLine] = []
}

enum CaptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

// Native recognizer and stream are accessed exclusively by this actor.
// Inference never runs on the UI thread or real-time audio callback.
actor StreamingRecognizer {
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private var committed: [RecognitionLine] = []
    private var acceptedFrames = 0
    private var segmentStart = 0
    private var finished = false

    func start(model: CaptionModel = .zipformer) throws {
        if recognizer == nil { try load(model: model) }
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        stream = SherpaOnnxCreateOnlineStream(recognizer)
        guard stream != nil else { throw CaptionError.message("Couldn't create the caption stream.") }
        committed = []; finished = false; acceptedFrames = 0; segmentStart = 0
    }

    private func load(model: CaptionModel) throws {
        let ctc = model.spec?.family == "nemoCTC"
        let roles = ctc ? ["model", "tokens"] : ["encoder", "decoder", "joiner", "tokens"]
        let paths = try roles.map { try ModelCatalog.file(model, role: $0).path }
        let strings = (paths + ["cpu", "greedy_search"]).map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = model.spec?.featureDim ?? 80
        if ctc {
            config.model_config.nemo_ctc.model = UnsafePointer(strings[0])
            config.model_config.tokens = UnsafePointer(strings[1])
        } else {
            config.model_config.transducer.encoder = UnsafePointer(strings[0])
            config.model_config.transducer.decoder = UnsafePointer(strings[1])
            config.model_config.transducer.joiner = UnsafePointer(strings[2])
            config.model_config.tokens = UnsafePointer(strings[3])
        }
        config.model_config.provider = UnsafePointer(strings[paths.count])
        config.model_config.num_threads = 2
        config.decoding_method = UnsafePointer(strings[paths.count + 1])
        config.max_active_paths = 4
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = 0.8
        config.rule3_min_utterance_length = 30
        recognizer = SherpaOnnxCreateOnlineRecognizer(&config)
        guard recognizer != nil else { throw CaptionError.message("Couldn't load the streaming caption model.") }
    }

    func accept(_ samples: [Float], final: Bool = false) throws -> CaptionResult {
        guard let recognizer, let stream, !finished else { throw CaptionError.message("No active caption stream.") }
        let start = Date()
        acceptedFrames += samples.count
        if !samples.isEmpty {
            samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
        }
        if final {
            // Flush the encoder's look-ahead so words at Stop are not lost.
            let padding = [Float](repeating: 0, count: 16000)
            padding.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
            SherpaOnnxOnlineStreamInputFinished(stream)
            finished = true
        }
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { throw CaptionError.message("Couldn't read captions.") }
        let partial = result.pointee.text.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        SherpaOnnxDestroyOnlineRecognizerResult(result)
        let endpoint = !final && SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0
        let line = RecognitionLine(id: "stream-\(committed.count)", text: partial,
                                   start: Double(segmentStart) / 16000, end: Double(acceptedFrames) / 16000,
                                   complete: endpoint || final)
        let lines = committed + (partial.isEmpty ? [] : [line])
        if endpoint {
            if !partial.isEmpty { committed.append(line) }
            segmentStart = acceptedFrames
            SherpaOnnxOnlineStreamReset(recognizer, stream)
        }
        return CaptionResult(text: lines.map(\.text).joined(separator: "\n"), decodeSeconds: Date().timeIntervalSince(start), lines: lines)
    }

    deinit {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        if let recognizer { SherpaOnnxDestroyOnlineRecognizer(recognizer) }
    }
}
