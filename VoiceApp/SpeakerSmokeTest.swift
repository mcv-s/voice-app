#if DEBUG
import AVFoundation
import Foundation

@MainActor
extension VoiceStore {
    func runSpeakerSmokeTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--speaker-test") else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [:]
        let previous = UserDefaults.standard.bool(forKey: "betaSpeakers")
        defer { UserDefaults.standard.set(previous, forKey: "betaSpeakers") }
        do {
            if !ModelCatalog.installed(.speakers) { await models.install(.speakers) }
            guard ModelCatalog.installed(.speakers) else { throw CaptionError.message(models.message) }
            UserDefaults.standard.set(true, forKey: "betaSpeakers")
            let engine = MoonshineRecognizer(); try await engine.start(model: .moonshineSmall)
            var all: [Float] = []
            for name in ["streaming-fixture.wav", "speaker-fixture.wav"] {
                let file = try AVAudioFile(forReading: docs.appendingPathComponent(name))
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                all += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) + [Float](repeating: 0, count: 48000)
            }
            for start in stride(from: 0, to: all.count, by: 1600) { _ = try await engine.accept(Array(all[start..<min(start + 1600, all.count)]), final: false) }
            let result = try await engine.accept([], final: true)
            let speakers = Set(result.lines.compactMap(\.speaker))
            report["speaker_labels"] = speakers.sorted()
            report["text"] = result.text
            report["passed"] = !result.text.isEmpty && !speakers.isEmpty
        } catch { report["passed"] = false; report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: docs.appendingPathComponent("speaker-result.json"), options: .atomic) }
    }
}
#endif
