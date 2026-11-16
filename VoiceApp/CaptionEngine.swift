import AVFoundation
import Speech

actor CaptionEngine {
    private var sherpa: StreamingRecognizer?
    private var moonshine: MoonshineRecognizer?
    private var eou: ParakeetEOURecognizer?
    private let apple = AppleCaptionEngine()
    private var model: CaptionModel = .zipformer
    private var history: [RecognitionLine] = []
    private var epochLines: [RecognitionLine] = []
    private var epoch = 0
    private var offset = 0.0
    private var acceptedEnd = 0.0

    func start(model: CaptionModel) async throws {
        await cancel()
        self.model = model
        history = []; epochLines = []; epoch = 0; offset = 0; acceptedEnd = 0
        guard model.isLive else { throw CaptionError.message("Choose a streaming model for live captions.") }
        if model == .apple { try await apple.start() }
        else if model.spec?.family == "moonshine" {
            let engine = MoonshineRecognizer(); moonshine = engine
            try await engine.start(model: model)
        } else if model == .parakeetEOU {
            let engine = ParakeetEOURecognizer(); eou = engine
            try await engine.start(model: model)
        } else {
            let engine = StreamingRecognizer(); sherpa = engine
            try await engine.start(model: model)
        }
    }
    func accept(_ samples: [Float], final: Bool = false) async throws -> CaptionResult {
        acceptedEnd += Double(samples.count) / 16000
        let result: CaptionResult
        if let moonshine { result = try await moonshine.accept(samples, final: final) }
        else if let eou { result = try await eou.accept(samples, final: final) }
        else if let sherpa { result = try await sherpa.accept(samples, final: final) }
        else { result = try await apple.accept(samples, final: final) }
        return wrap(result)
    }
    private func wrap(_ result: CaptionResult) -> CaptionResult {
        epochLines = result.lines.map { RecognitionLine(id: "\(epoch)-" + $0.id, text: $0.text, start: offset + $0.start, end: offset + $0.end, complete: $0.complete, speaker: $0.speaker) }
        let lines = history + epochLines
        return CaptionResult(text: lines.isEmpty ? result.text : lines.map(\.text).joined(separator: "\n"), decodeSeconds: result.decodeSeconds, lines: lines)
    }
    func skip(to seconds: Double) async throws -> CaptionResult {
        history += epochLines.map { RecognitionLine(id: $0.id, text: $0.text, start: $0.start, end: $0.end, complete: true, speaker: $0.speaker) }
        let coveredEnd = epochLines.map(\.end).max() ?? offset
        if seconds > coveredEnd {
            history.append(RecognitionLine(id: "catchup-\(epoch)", text: "…", start: coveredEnd, end: seconds, complete: true))
        }
        epoch += 1; offset = seconds; acceptedEnd = seconds; epochLines = []
        if let moonshine { try await moonshine.resetStream() }
        else if let sherpa { try await sherpa.start(model: model) }
        else if let eou { try await eou.resetStream() }
        else { try await apple.start() }
        return CaptionResult(text: history.map(\.text).joined(separator: "\n"), decodeSeconds: 0, lines: history)
    }
    func poll() async throws -> CaptionResult? {
        if model == .apple { return wrap(try await apple.currentResult()) }
        return nil
    }
    func cancel() async {
        sherpa = nil; moonshine = nil; eou = nil
        await apple.cancel()
    }
}

private actor AppleCaptionEngine {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var text = ""
    private var committed = ""
    private var failure: String?
    private var completedLines: [RecognitionLine] = []
    private var acceptedFrames = 0
    private var segmentStart = 0
    private var currentWords = ""
    private var finished = false
    private var stopping = false
    private var generation = UUID()

    func start() throws {
        cancel()
        guard let recognizer, recognizer.isAvailable else { throw CaptionError.message("Apple Speech is unavailable. Try Zipformer in Settings.") }
        guard recognizer.supportsOnDeviceRecognition else {
            throw CaptionError.message("Apple's on-device English recognition isn't available here. Choose another offline model in Settings.")
        }
        text = ""; committed = ""; failure = nil; stopping = false
        completedLines = []; acceptedFrames = 0; segmentStart = 0; currentWords = ""
        beginRequest()
    }
    private func beginRequest() {
        generation = UUID()
        let token = generation
        finished = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.request = request
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let message = error?.localizedDescription
            Task { await self?.update(words: words, final: final, message: message, token: token) }
        }
    }
    private func update(words: String?, final: Bool, message: String?, token: UUID) {
        guard generation == token else { return }
        if let words { currentWords = words; text = committed + (committed.isEmpty || words.isEmpty ? "" : "\n") + words }
        if let message, !stopping { failure = "Apple Speech stopped: \(message). Your text will be saved."; finished = true }
        else if final {
            finished = true
            if !stopping {
                completedLines.append(RecognitionLine(id: "apple-\(completedLines.count)", text: currentWords, start: Double(segmentStart) / 16000, end: Double(acceptedFrames) / 16000, complete: true))
                segmentStart = acceptedFrames; currentWords = ""
                committed = text
                request?.endAudio(); task = nil
                beginRequest()
            }
        }
    }
    func currentResult(final: Bool = false) throws -> CaptionResult {
        if let failure { throw CaptionError.message(failure) }
        let pending = currentWords.isEmpty ? [] : [RecognitionLine(id: "apple-\(completedLines.count)", text: currentWords, start: Double(segmentStart) / 16000, end: Double(acceptedFrames) / 16000, complete: final)]
        return CaptionResult(text: text, decodeSeconds: 0, lines: completedLines + pending)
    }
    func accept(_ samples: [Float], final: Bool) async throws -> CaptionResult {
        if let failure { throw CaptionError.message(failure) }
        let start = Date()
        acceptedFrames += samples.count
        if !samples.isEmpty {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let data = buffer.floatChannelData?[0] else { throw CaptionError.message("Couldn't prepare audio for Apple Speech.") }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: samples.count) }
            request?.append(buffer)
        }
        if final {
            stopping = true
            request?.endAudio()
            let deadline = Date().addingTimeInterval(2)
            while !finished && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            var result = try currentResult(final: true)
            result = CaptionResult(text: result.text, decodeSeconds: Date().timeIntervalSince(start), lines: result.lines)
            cancel()
            return result
        }
        let result = try currentResult()
        return CaptionResult(text: result.text, decodeSeconds: Date().timeIntervalSince(start), lines: result.lines)
    }
    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil; request = nil
    }
}
