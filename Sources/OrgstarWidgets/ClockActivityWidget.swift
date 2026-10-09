import ActivityKit
import AppIntents
import OrgApp
import SwiftUI
import WidgetKit

/// The running clock on the Lock Screen and in the Dynamic Island: the heading and the time
/// so far, which ticks by itself.
struct ClockActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClockActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "stopwatch").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clocked in").font(.caption).foregroundStyle(.secondary)
                    Text(context.state.heading).font(.headline).lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    ElapsedText(state: context.state).font(.title3.weight(.semibold))
                    ClockOutButton()
                }
            }
            .padding()
            .widgetURL(AppLink.clock.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "stopwatch").font(.title2).foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state).font(.title3.weight(.semibold)).frame(width: 84, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.heading).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ClockOutButton()
                }
            } compactLeading: {
                Image(systemName: "stopwatch").foregroundStyle(.orange)
            } compactTrailing: {
                ElapsedText(state: context.state).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "stopwatch").foregroundStyle(.orange)
            }
            .widgetURL(AppLink.clock.url)
        }
    }
}

/// Time since the clock started, `1:05:09`.
struct ElapsedText: View {
    let state: ClockActivityAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.trailing)
    }
}

struct ClockOutButton: View {
    var body: some View {
        Button(intent: ClockOutIntent()) {
            Label("Clock Out", systemImage: "stop.fill").font(.caption.weight(.semibold))
        }
        .tint(.orange)
    }
}

#Preview("Lock Screen", as: .content, using: ClockActivityAttributes(path: "/notes/work.org", start: "2026-10-09 Fri 09:00")) {
    ClockActivityWidget()
} contentStates: {
    ClockActivityAttributes.ContentState(heading: "Review the draft", startedAt: .now.addingTimeInterval(-3725))
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: ClockActivityAttributes(path: "/notes/work.org", start: "2026-10-09 Fri 09:00")) {
    ClockActivityWidget()
} contentStates: {
    ClockActivityAttributes.ContentState(heading: "Review the draft", startedAt: .now.addingTimeInterval(-3725))
}
