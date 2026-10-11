import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MotoLinkLiveActivityBundle: WidgetBundle {
    var body: some Widget { MotoLinkLiveActivity() }
}

struct MotoLinkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenCard(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color(red: 0.06, green: 0.065, blue: 0.08))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Moto Link", systemImage: "speedometer")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.recording {
                        Text(context.state.durationText).font(.system(.headline, design: .rounded)).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.motorcycleName).font(.system(.headline, design: .rounded))
                        Text(context.state.statusText(stale: context.isStale))
                            .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.isStale ? "arrow.clockwise" : "speedometer")
                    .foregroundStyle(context.isStale ? Color.secondary : Color.red)
            } compactTrailing: {
                Text(context.isStale ? "—" : context.state.recording ? context.state.durationText : "ML")
                    .font(.system(.caption2, design: .rounded).weight(.semibold)).monospacedDigit()
            } minimal: {
                Image(systemName: context.isStale ? "arrow.clockwise" : "speedometer")
                    .foregroundStyle(context.isStale ? Color.secondary : Color.red)
            }
            .keylineTint(.red)
        }
    }
}

