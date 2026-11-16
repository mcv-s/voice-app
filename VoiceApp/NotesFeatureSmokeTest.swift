#if DEBUG
import AVFoundation
import Foundation

@MainActor
extension VoiceStore {
    func runNotesFeatureSmokeTestIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--notes-feature-test") else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [:]
        busy = true; defer { busy = false }
        do {
            let source = "Alice and Ben met to plan repairs to the front steps. They agreed the work should happen on Friday. The budget is $450. Ben will call the contractor tomorrow. Alice will bring the paperwork. Their next meeting is Monday at 10 AM."
            let start = Date()
            let notes = try await NotesAI().generate(text: source)
            report["ai_seconds"] = Date().timeIntervalSince(start)
            report["title"] = notes.title; report["summary"] = notes.summary
            let summaryOK = !notes.title.isEmpty && notes.summary.contains("450") && notes.summary.lowercased().contains("friday") && notes.summary.lowercased().contains("ben") && notes.summary.lowercased().contains("monday") && notes.summary.contains("10")
            report["important_facts_present"] = summaryOK
            let transcript = Transcript(text: source, generatedTitle: notes.title, summary: notes.summary,
                                        cues: [TranscriptCue(start: 0, end: 6.5, text: "Alice & Ben met."), TranscriptCue(start: 9.25, end: 17.25, text: "The budget is $450.")], duration: 17.25)
            let vtt = TranscriptExports.vtt(transcript)
            report["vtt"] = vtt
            let exportOK = vtt.hasPrefix("WEBVTT\n\n") && vtt.contains("00:00:09.250 --> 00:00:17.250") && vtt.contains("Alice &amp; Ben") && TranscriptExports.markdown(transcript).contains("## Summary")
            report["text_exports_passed"] = exportOK
            let data = try await AudioExporter().m4a(from: documents.appendingPathComponent("streaming-fixture.wav"))
            let url = documents.appendingPathComponent("test-export.m4a"); try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let player = try AVAudioPlayer(contentsOf: url)
            let audioOK = abs(player.duration - Double(try AVAudioFile(forReading: documents.appendingPathComponent("streaming-fixture.wav")).length) / 16000) < 0.3 && data.count > 1000
            report["audio_export_passed"] = audioOK; report["audio_export_bytes"] = data.count
            let encoded = try JSONEncoder().encode(transcript)
            let decoded = try JSONDecoder().decode(Transcript.self, from: encoded)
            report["metadata_round_trip_passed"] = decoded.summary == notes.summary && decoded.cues?.count == 2
            let legacy = try JSONDecoder().decode(Transcript.self, from: Data("{\"id\":\"A260FF02-02F3-4038-90B0-9B7705357709\",\"date\":0,\"text\":\"Old note\",\"duration\":2}".utf8))
            report["legacy_notes_passed"] = legacy.summary == nil && legacy.generatedTitle == nil && legacy.cues == nil
            report["passed"] = summaryOK && exportOK && audioOK && report["metadata_round_trip_passed"] as? Bool == true && report["legacy_notes_passed"] as? Bool == true
        } catch { report["passed"] = false; report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: documents.appendingPathComponent("notes-feature-result.json"), options: .atomic) }
        status = "Notes features test complete"
    }
}
#endif
