import ActivityKit
import SwiftUI

@MainActor
final class RecordingActivityController: ObservableObject {
    @Published private(set) var message = ""
    private var activity: Activity<RecordingActivityAttributes>?
    private var lastPhase = ""
    private var lastMuted = false
    private var pending: Task<Void, Never>?
    var enabled: Bool { UserDefaults.standard.object(forKey: "recordingLiveActivity") as? Bool ?? true }

    func start(id: UUID) async {
        await pending?.value
        // End orphaned activities from an interrupted or terminated app session.
        for old in Activity<RecordingActivityAttributes>.activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil; lastPhase = ""; message = ""
        guard enabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = "Live Activities are disabled in iOS Settings. Recording still works."; return
        }
        do {
            let state = Self.state(paused: false, muted: false, elapsed: 0)
            activity = try Activity.request(attributes: RecordingActivityAttributes(recordingID: id.uuidString), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            lastPhase = state.phase; lastMuted = false
        } catch { message = "Live Activity couldn't start: " + error.localizedDescription }
    }
    static func state(paused: Bool, muted: Bool, elapsed: Double, phase: String? = nil) -> RecordingActivityAttributes.ContentState {
        let phase = phase ?? (paused ? "Paused" : muted ? "Muted" : "Recording")
        let running = phase == "Recording" || phase == "Muted"
        return .init(phase: phase, elapsed: elapsed, timerAnchor: running ? Date().addingTimeInterval(-elapsed) : nil, muted: muted)
    }
    func update(paused: Bool, muted: Bool, elapsed: Double, phase: String? = nil) {
        guard let activity else { return }
        let state = Self.state(paused: paused, muted: muted, elapsed: elapsed, phase: phase)
        guard state.phase != lastPhase || muted != lastMuted else { return }
        lastPhase = state.phase; lastMuted = muted
        let previous = pending
        pending = Task { await previous?.value; await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }
    func end(elapsed: Double, saved: Bool = true) {
        guard let activity else { return }
        self.activity = nil
        let state = Self.state(paused: true, muted: false, elapsed: elapsed, phase: saved ? "Saved" : "Stopped")
        let previous = pending
        pending = Task { await previous?.value; await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(10))) }
    }
    func clearOrphans() async {
        guard activity == nil else { return }
        for old in Activity<RecordingActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
    }
    #if DEBUG
    func settle() async { await pending?.value }
    var currentState: RecordingActivityAttributes.ContentState? { activity?.content.state }
    #endif
}

struct LiveActivityOption: View {
    @ObservedObject var controller: RecordingActivityController
    @AppStorage("recordingLiveActivity") private var enabled = true
    var body: some View {
        Section {
            Toggle("Recording Live Activity", isOn: $enabled)
            if !controller.message.isEmpty { Text(controller.message).font(.footnote).foregroundColor(.secondary) }
        } footer: { Text("Shows recording status on the Lock Screen and supported Dynamic Islands. Tap it to open Record. Changes apply to the next recording.") }
    }
}
