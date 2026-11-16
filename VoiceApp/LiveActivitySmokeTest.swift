#if DEBUG
import ActivityKit
import AVFoundation
import Foundation

@MainActor
extension VoiceStore {
    func runLiveActivityTestIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--live-activity-test") || arguments.contains("--live-activity-preview") else { return }
        guard Bundle.main.bundleIdentifier == "com.voiceapp.setupqa" else { return }
        var report: [String: Any] = [:]
        do {
            guard arguments.contains("--microphone-fixture") else { throw CaptionError.message("Live Activity test requires fixture audio.") }
            selectedModel = .fastConformer
            await start()
            guard recording, let id = activeRecordingID else { throw CaptionError.message(error ?? "Recording did not start.") }
            guard let activity = Activity<RecordingActivityAttributes>.activities.first(where: { $0.attributes.recordingID == id.uuidString }) else { throw CaptionError.message(liveActivity.message.isEmpty ? "Live Activity not created." : liveActivity.message) }
            report["activity_started_for_recording"] = activity.content.state.phase == "Recording" && activity.content.state.timerAnchor != nil
            try await Task.sleep(nanoseconds: 1_500_000_000)
            togglePause(); await liveActivity.settle()
            report["pause_freezes_timer"] = activity.content.state.phase == "Paused" && activity.content.state.timerAnchor == nil
            toggleMute(); await liveActivity.settle()
            report["muted_while_paused"] = activity.content.state.muted && activity.content.state.phase == "Paused"
            togglePause(); await liveActivity.settle()
            report["muted_recording_keeps_timer"] = activity.content.state.phase == "Muted" && activity.content.state.timerAnchor != nil
            toggleMute(); await liveActivity.settle()
            report["resume_restores_recording"] = activity.content.state.phase == "Recording"
            if arguments.contains("--live-activity-preview") { return }
            stop()
            for _ in 0..<300 where busy { try await Task.sleep(nanoseconds: 100_000_000) }
            await liveActivity.settle()
            report["activity_ends_after_save"] = activity.activityState == .ended || activity.activityState == .dismissed
            if let transcript = recordings.first(where: { $0.id == id }), let audio = audioURL(for: transcript) {
                report["saved_audio_exists"] = (try AVAudioFile(forReading: audio)).length > 0 && transcript.unfinished == false
            } else { report["saved_audio_exists"] = false }
            report["passed"] = report.values.compactMap { $0 as? Bool }.allSatisfy { $0 }
        } catch { report["passed"] = false; report["error"] = error.localizedDescription; stop() }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: documents.appendingPathComponent("live-activity-result.json")) }
    }
}
#endif
