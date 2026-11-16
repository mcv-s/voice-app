#if DEBUG
import AVFoundation
import Foundation

// Debug-only deterministic test. Does not request the mic or transmit audio.
@MainActor
extension VoiceStore {
    func runStreamingSmokeTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--streaming-smoke-test") else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let output = documents.appendingPathComponent("streaming-result.json")
        let decoder = StreamingRecognizer()
        var report: [String: Any] = [:]
        busy = true
        defer { busy = false }
        do {
            let formatted = CaptionFormatter.sentenceCase("IT HAS LIVE TRANSCRIPTION. I THINK IT WORKS!\nCAN I USE MY USB MIC ON IPHONE?")
            let formattingOK = formatted == "It has live transcription. I think it works!\nCan I use my USB mic on iPhone?"
            report["sentence_case_passed"] = formattingOK
            let conversionOK = try AudioCapture.conversionSmokeTest()
            report["microphone_conversion_passed"] = conversionOK
            let load = Date()
            try await decoder.start(model: .fastConformer)
            report["load_seconds"] = Date().timeIntervalSince(load)
            let file = try AVAudioFile(forReading: documents.appendingPathComponent("streaming-fixture.wav"))
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw CaptionError.message("Fixture must be 16 kHz mono WAV.")
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw CaptionError.message("No fixture samples") }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let writer = RefinementAudio()
            try await writer.start()
            for offset in stride(from: 0, to: samples.count, by: 1600) {
                try await writer.append(Array(samples[offset..<min(offset + 1600, samples.count)]))
            }
            guard let savedAudio = await writer.close() else { throw CaptionError.message("Audio file wasn't created") }
            defer { try? FileManager.default.removeItem(at: savedAudio) }
            let roundTrip = try AVAudioFile(forReading: savedAudio)
            let player = try AVAudioPlayer(contentsOf: savedAudio)
            let recordingOK = roundTrip.length == AVAudioFramePosition(samples.count) && abs(player.duration - Double(samples.count) / 16000) < 0.01
            report["recording_playback_file_passed"] = recordingOK
            var firstPartialAudio: Double?
            var firstPartialWall: Double?
            var updates = 0
            var processing = 0.0
            let start = Date()
            // Pace the input as a live microphone: one 100-ms buffer per 100 ms.
            for offset in stride(from: 0, to: samples.count, by: 1600) {
                let end = min(offset + 1600, samples.count)
                let target = Double(end) / 16000
                let wait = target - Date().timeIntervalSince(start)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                let result = try await decoder.accept(Array(samples[offset..<end]))
                processing += result.decodeSeconds
                if result.text != text { updates += 1 }
                text = result.text
                if firstPartialAudio == nil && !text.isEmpty {
                    firstPartialAudio = target
                    firstPartialWall = Date().timeIntervalSince(start)
                }
            }
            let final = try await decoder.accept([], final: true)
            text = final.text
            processing += final.decodeSeconds
            report["text"] = text
            report["audio_seconds"] = Double(samples.count) / 16000
            report["decode_seconds"] = processing
            report["real_time_factor"] = processing / (Double(samples.count) / 16000)
            report["partial_updates"] = updates
            report["first_partial_audio_seconds"] = firstPartialAudio
            report["first_partial_wall_seconds"] = firstPartialWall
            // A fresh session must not leak previous captions or hallucinate on silence.
            try await decoder.start(model: .fastConformer)
            let silent = try await decoder.accept([Float](repeating: 0, count: 32000), final: true)
            report["silence_text"] = silent.text
            // Repeat lifecycle and ensure streaming state resets without reloading the model.
            try await decoder.start(model: .fastConformer)
            var repeatText = ""
            for offset in stride(from: 0, to: samples.count, by: 1600) {
                repeatText = try await decoder.accept(Array(samples[offset..<min(offset + 1600, samples.count)])).text
            }
            repeatText = try await decoder.accept([], final: true).text
            report["repeat_matches"] = repeatText == text
            // Two utterances separated by silence exercise endpoint/reset behavior.
            try await decoder.start(model: .fastConformer)
            var endpointText = ""
            let conversation = samples + [Float](repeating: 0, count: 48000) + samples
            for offset in stride(from: 0, to: conversation.count, by: 1600) {
                endpointText = try await decoder.accept(Array(conversation[offset..<min(offset + 1600, conversation.count)])).text
            }
            endpointText = try await decoder.accept([], final: true).text
            report["endpoint_text"] = endpointText
            let lines = endpointText.split(separator: "\n").map(String.init)
            let endpointsOK = lines == [text, text]
            report["endpoints_preserve_both_utterances"] = endpointsOK
            report["passed"] = formattingOK && recordingOK && conversionOK && !text.isEmpty && updates > 1 && silent.text.isEmpty && repeatText == text && endpointsOK
            if ProcessInfo.processInfo.arguments.contains("--test-refinement") {
                let refined = try await TranscriptRefiner().refine(audio: savedAudio, model: documents.appendingPathComponent("refinement-model.bin"))
                report["refined_text"] = refined
                let refinementOK = refined.lowercased().contains("good morning") && refined.lowercased().contains("garden")
                report["refinement_passed"] = refinementOK
                report["passed"] = (report["passed"] as? Bool == true) && refinementOK
            }
            let legacyJSON = "{\"id\":\"A260FF02-02F3-4038-90B0-9B7705357709\",\"date\":0,\"text\":\"Earlier note\",\"duration\":2}"
            let legacy = try JSONDecoder().decode(Transcript.self, from: Data(legacyJSON.utf8))
            report["legacy_history_passed"] = legacy.audioFile == nil && legacy.originalText == nil
            report["passed"] = (report["passed"] as? Bool == true) && legacy.audioFile == nil
            status = "Streaming sample test complete"
        } catch {
            report["passed"] = false
            report["error"] = error.localizedDescription
            self.error = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }
}
#endif
