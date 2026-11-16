import ActivityKit
import SwiftUI
import WidgetKit

private let mint = Color(red: 0.52, green: 0.89, blue: 0.68)
private let background = Color(red: 0.025, green: 0.075, blue: 0.055)

@main
struct RecordingActivityBundle: WidgetBundle {
    var body: some Widget { RecordingLiveActivity() }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 16) {
                Image(systemName: context.state.symbol).font(.title2).foregroundColor(mint).frame(width: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Murmur").font(.headline)
                    Text(context.state.phase + (context.state.muted && context.state.phase == "Paused" ? " · Mic muted" : "")).font(.subheadline).foregroundColor(mint)
                }
                Spacer()
                ActivityTimer(state: context.state).font(.title2.monospacedDigit()).frame(minWidth: 65, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(mint)
            }.padding(18).activityBackgroundTint(background).activitySystemActionForegroundColor(mint)
                .widgetURL(URL(string: "voiceapp://record"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Murmur", systemImage: context.state.symbol).foregroundColor(mint) }
                DynamicIslandExpandedRegion(.trailing) { ActivityTimer(state: context.state).monospacedDigit().foregroundColor(mint) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack { Text(context.state.phase); Spacer(); Label("Open recording", systemImage: "arrow.up.right") }.font(.caption).padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol).foregroundColor(mint)
            } compactTrailing: {
                ActivityTimer(state: context.state).monospacedDigit().foregroundColor(mint).frame(width: 56)
            } minimal: {
                Image(systemName: context.state.symbol).foregroundColor(mint)
            }.widgetURL(URL(string: "voiceapp://record")).keylineTint(mint)
        }
    }
}

private struct ActivityTimer: View {
    let state: RecordingActivityAttributes.ContentState
    var body: some View {
        if let anchor = state.timerAnchor { Text(anchor, style: .timer).multilineTextAlignment(.trailing) }
        else { Text(String(format: "%02d:%02d", Int(max(0, state.elapsed)) / 60, Int(max(0, state.elapsed)) % 60)) }
    }
}
