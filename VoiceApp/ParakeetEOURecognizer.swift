import Foundation
import CoreML

actor ParakeetEOURecognizer {
    private var encoder: MLModel?
    private var decoder: RnntDecoder?
    private var tokenizer: Tokenizer?
    private let mel = AudioMelSpectrogram()
    private var caches: [String: MLMultiArray] = [:]
    private var audio: [Float] = []
    private var tokens: [Int] = []
    private var finished = false
    private var lines: [RecognitionLine] = []
    private var processedFrames = 0
    private var lineStartFrame = 0
    private var lineStartToken = 0

    func start(model: CaptionModel) throws {
        guard #available(iOS 17, *), ModelCatalog.installed(model) else { throw CaptionError.message("Parakeet EOU needs iOS 17+ and a model download.") }
        let root = ModelCatalog.directory(model).appendingPathComponent("160ms")
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        // Synchronous Core ML calls stay isolated to this actor's executor.
        encoder = try MLModel(contentsOf: root.appendingPathComponent("streaming_encoder.mlmodelc"), configuration: config)
        let predictor = try MLModel(contentsOf: root.appendingPathComponent("decoder.mlmodelc"), configuration: config)
        let joint = try MLModel(contentsOf: root.appendingPathComponent("joint_decision.mlmodelc"), configuration: config)
        decoder = RnntDecoder(decoderModel: predictor, jointModel: joint)
        tokenizer = try Tokenizer(vocabPath: root.appendingPathComponent("vocab.json"))
        try resetCaches()
        audio = []; tokens = []; finished = false; lines = []; processedFrames = 0; lineStartFrame = 0; lineStartToken = 0
    }
    func resetStream() throws {
        try resetCaches(); decoder?.resetState()
        audio = []; tokens = []; lines = []; processedFrames = 0; lineStartFrame = 0; lineStartToken = 0; finished = false
    }
    private func resetCaches() throws {
        for (name, shape, type) in [
            ("pre_cache", [1, 128, 16], MLMultiArrayDataType.float32),
            ("cache_last_channel", [17, 1, 70, 512], .float32),
            ("cache_last_time", [17, 1, 512, 8], .float32),
            ("cache_last_channel_len", [1], .int32)
        ] {
            let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: type)
            memset(array.dataPointer, 0, array.count * 4)
            caches[name] = array
        }
    }
    func accept(_ samples: [Float], final: Bool) throws -> CaptionResult {
        guard let encoder, let decoder, let tokenizer, !finished else { throw CaptionError.message("No active Parakeet stream.") }
        let start = Date()
        audio.append(contentsOf: samples)
        if final { audio.append(contentsOf: [Float](repeating: 0, count: 16000)); finished = true }
        while audio.count >= 2560 {
            let chunk = Array(audio.prefix(2560))
            // This exported encoder expects 50% audio overlap (80-ms shift).
            audio.removeFirst(1280)
            processedFrames += 1280
            let (values, length, frames) = mel.computeFlat(audio: chunk)
            let features = try MLMultiArray(shape: [1, 128, NSNumber(value: frames)], dataType: .float32)
            values.withUnsafeBufferPointer { features.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count) }
            let lengths = try MLMultiArray(shape: [1], dataType: .int32); lengths[0] = NSNumber(value: length)
            var inputs = caches.mapValues { MLFeatureValue(multiArray: $0) }
            inputs["audio_signal"] = MLFeatureValue(multiArray: features)
            inputs["audio_length"] = MLFeatureValue(multiArray: lengths)
            let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
            for name in Array(caches.keys) {
                guard let next = output.featureValue(for: "new_" + name)?.multiArrayValue else { throw CaptionError.message("Parakeet encoder state missing: \(name)") }
                caches[name] = next
            }
            guard let encoded = output.featureValue(for: "encoded_output")?.multiArrayValue else { throw CaptionError.message("Parakeet encoder output missing.") }
            let result = try decoder.decodeWithEOU(encoderOutput: encoded, validOutLen: 2)
            tokens.append(contentsOf: result.tokenIds)
            if result.eouDetected {
                let line = RecognitionLine(id: "eou-\(lines.count)", text: tokenizer.decode(ids: Array(tokens.dropFirst(lineStartToken))), start: Double(lineStartFrame) / 16000, end: Double(processedFrames) / 16000, complete: true)
                if !line.text.isEmpty { lines.append(line) }
                lineStartFrame = processedFrames; lineStartToken = tokens.count
                // Re-arm for the next speaker turn while retaining pending microphone audio.
                try resetCaches(); decoder.resetState()
            }
        }
        let partial = tokenizer.decode(ids: Array(tokens.dropFirst(lineStartToken)))
        let visible = lines + (partial.isEmpty ? [] : [RecognitionLine(id: "eou-\(lines.count)", text: partial, start: Double(lineStartFrame) / 16000, end: Double(processedFrames) / 16000, complete: final)])
        return CaptionResult(text: visible.map(\.text).joined(separator: "\n"), decodeSeconds: Date().timeIntervalSince(start), lines: visible)
    }
}
