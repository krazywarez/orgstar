import AppIntents
import OrgApp
import SwiftUI
import WidgetKit

/// Capture from Control Center, the Lock Screen or the Action button, with a chosen template.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "sh.krz.orgstar.capture-control", intent: CaptureControlConfiguration.self) { configuration in
            ControlWidgetButton(action: OpenCaptureIntent(template: configuration.template)) {
                Label(configuration.template?.name ?? "Capture", systemImage: "square.and.pencil")
            }
        }
        .displayName("Capture")
        .description("Opens orgstar's capture sheet, with the template you choose.")
    }
}

/// The clock: on while one runs, showing its entry; off shows the entry clocked last, which
/// turning it on clocks in to.
struct ClockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "sh.krz.orgstar.clock-control", provider: ClockValueProvider()) { clock in
            ControlWidgetToggle("Clock", isOn: clock.running != nil, action: ClockToggleIntent()) { isOn in
                Label(isOn ? clock.running ?? "Clocked in" : clock.last.map { "In: \($0)" } ?? "No recent clock",
                      systemImage: isOn ? "stopwatch.fill" : "stopwatch")
            }
            .tint(.orange)
        }
        .displayName("Clock")
        .description("Clocks out of the running clock, or back in to the entry clocked last.")
    }
}

struct ClockValueProvider: ControlValueProvider {
    var previewValue: ClockSnapshot { ClockSnapshot(running: nil, startedAt: nil, last: "Review the draft") }

    func currentValue() async throws -> ClockSnapshot {
        ClockSnapshot.read() ?? ClockSnapshot(running: nil, startedAt: nil, last: nil)
    }
}

/// Capture on the Lock Screen: a button that opens the capture sheet with a chosen template.
struct CaptureWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "sh.krz.orgstar.capture", intent: CaptureWidgetConfiguration.self, provider: CaptureProvider()) { entry in
            CaptureView(entry: entry)
        }
        .configurationDisplayName("Capture")
        .description("Opens orgstar's capture sheet, with the template you choose.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct CaptureEntry: TimelineEntry {
    let date: Date
    let template: CaptureTemplateEntity?
}

struct CaptureProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry {
        CaptureEntry(date: .now, template: nil)
    }

    func snapshot(for configuration: CaptureWidgetConfiguration, in context: Context) async -> CaptureEntry {
        CaptureEntry(date: .now, template: configuration.template)
    }

    func timeline(for configuration: CaptureWidgetConfiguration, in context: Context) async -> Timeline<CaptureEntry> {
        Timeline(entries: [CaptureEntry(date: .now, template: configuration.template)], policy: .never)
    }
}

struct CaptureView: View {
    let entry: CaptureEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "square.and.pencil").font(.title2)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").font(.title3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Capture").font(.headline)
                        Text(entry.template?.name ?? "First template").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .widgetURL(AppLink.capture(template: entry.template?.id).url)
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel("Capture" + (entry.template.map { " with \($0.name)" } ?? ""))
    }
}
