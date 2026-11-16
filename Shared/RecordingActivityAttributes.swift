import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var elapsed: Double
        var timerAnchor: Date?
        var muted: Bool
        var symbol: String {
            phase == "Saved" ? "checkmark.circle.fill" : phase == "Paused" ? "pause.fill" : phase == "Finishing" ? "waveform" : muted ? "mic.slash.fill" : "mic.fill"
        }
    }
    let recordingID: String
}
