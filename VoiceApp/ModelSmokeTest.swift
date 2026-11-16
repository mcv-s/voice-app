#if DEBUG
import AVFoundation
import Foundation
import UIKit

// Opt-in integration harness. No microphone, no history changes, no network during inference.
@MainActor
extension VoiceStore {
    func runModelSmokeTestIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--model-test"), args.indices.contains(index + 1) else { return }
        let requested = args[index + 1].split(separator: ",").compactMap { CaptionModel(rawValue: String($0)) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent("model-results.json")
        var reports: [[String: Any]] = []
        busy = true; UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        for model in requested {
            var report: [String: Any] = ["model": model.rawValue, "device": UIDevice.current.model, "os": UIDevice.current.systemVersion]
            do {
                if !ModelCatalog.installed(model), args.contains("--download-models") { await models.install(model) }
                guard ModelCatalog.installed(model) else { throw CaptionError.message(models.message.isEmpty ? "Model not installed" : models.message) }
                let fixture = documents.appendingPathComponent("streaming-fixture.wav")
                let file = try AVAudioFile(forReading: fixture)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                status = "Testing " + model.title
                let load = Date()
                if model.isLive {
                    let engine = CaptionEngine()
                    try await engine.start(model: model)
                    report["load_seconds"] = Date().timeIntervalSince(load)
                    let start = Date()
                    var first: Double?; var previous = ""; var updates = 0
                    for offset in stride(from: 0, to: samples.count, by: 1600) {
                        let end = min(offset + 1600, samples.count)
                        let result = try await engine.accept(Array(samples[offset..<end]))
                        if result.text != previous { updates += 1; previous = result.text }
                        if first == nil && !result.text.isEmpty { first = Double(end) / 16000 }
                    }
                    let final = try await engine.accept([], final: true)
                    report["decode_seconds"] = Date().timeIntervalSince(start)
                    report["text"] = final.text
                    report["updates"] = updates; report["first_partial_audio_seconds"] = first
                    await engine.cancel()
                    // A new session must preserve two turns and flush words at Stop.
                    try await engine.start(model: model)
                    let conversation = samples + [Float](repeating: 0, count: 48000) + samples
                    for offset in stride(from: 0, to: conversation.count, by: 1600) {
                        _ = try await engine.accept(Array(conversation[offset..<min(offset + 1600, conversation.count)]))
                    }
                    let two = try await engine.accept([], final: true).text
                    report["two_turn_text"] = two
                    report["two_turns_present"] = two.lowercased().components(separatedBy: "community garden").count == 3
                    await engine.cancel()
                    try await engine.start(model: model)
                    let silent = try await engine.accept([Float](repeating: 0, count: 48000), final: true).text
                    report["silence_text"] = silent
                    report["passed"] = !final.text.isEmpty && updates > 0 && silent.isEmpty && report["two_turns_present"] as? Bool == true
                    await engine.cancel()
                } else {
                    let text = try await OfflineRecognizer().refine(audio: fixture, model: model)
                    report["decode_seconds"] = Date().timeIntervalSince(load)
                    report["text"] = text; report["passed"] = !text.isEmpty
                }
                report["audio_seconds"] = Double(samples.count) / 16000
                if let seconds = report["decode_seconds"] as? Double { report["real_time_factor"] = seconds / (Double(samples.count) / 16000) }
            } catch { report["passed"] = false; report["error"] = error.localizedDescription }
            reports.append(report)
            if let data = try? JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: destination, options: .atomic) }
        }
        // Explicit development-only selection makes the physical test device ready for the user.
        if args.contains("--select-moonshine"), ModelCatalog.installed(.moonshineSmall) { selectedModel = .moonshineSmall }
        status = "Model tests complete"
    }
}
#endif
