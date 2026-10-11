#if os(watchOS)
import OrgWatchData
import SwiftUI
import WidgetKit

/// Complications: the next agenda entry, and the running clock.
@main
struct OrgstarWatchWidgets: WidgetBundle {
    var body: some Widget {
        NextEntryComplication()
        ClockComplication()
    }
}

struct WatchEntry: TimelineEntry {
    let date: Date
    let agenda: WatchAgenda?
}

/// The agenda the watch app last got, with an entry at each change of what's next.
struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: .now, agenda: nil) }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(WatchEntry(date: .now, agenda: WatchAgenda.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let agenda = WatchAgenda.read()
        let now = Date()
        var dates = [now]
        for row in agenda?.rows ?? [] {
            if let end = row.end ?? row.start, end > now { dates.append(end.addingTimeInterval(60)) }
        }
        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) { dates.append(midnight) }
        let entries = Set(dates).sorted().map { WatchEntry(date: $0, agenda: agenda) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct NextEntryComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sh.krz.orgstar.watch.next", provider: WatchProvider()) { entry in
            NextEntryView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Up Next")
        .description("The next agenda entry, or how many are open today.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .accessoryCorner])
    }
}

struct NextEntryView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    private var next: WatchAgenda.Entry? { entry.agenda?.next(at: entry.date) }
    private var open: Int { entry.agenda?.openCount(at: entry.date) ?? 0 }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(next.map { "\($0.gutter) \($0.title)" } ?? (open == 0 ? "Agenda clear" : "\(open) open today"))
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text("\(open)").font(.title3.weight(.semibold)).widgetAccentable()
                    Text("open").font(.caption2)
                }
            }
        case .accessoryCorner:
            Text("\(open)").font(.title3.weight(.semibold)).widgetLabel { Text(next?.title ?? "Agenda clear") }
        default:
            VStack(alignment: .leading, spacing: 0) {
                Text(next?.gutter ?? "Agenda").font(.headline).widgetAccentable().lineLimit(1)
                Text(next?.title ?? (entry.agenda == nil ? "Open orgstar" : "Nothing left today")).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ClockComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sh.krz.orgstar.watch.clock", provider: WatchProvider()) { entry in
            ClockView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Clock")
        .description("The running clock and its time so far.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct ClockView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let clock = entry.agenda?.clock
        switch family {
        case .accessoryInline:
            if let clock { Text("\(clock.heading) ") + Text(clock.startedAt, style: .timer) } else { Text("Not clocked in") }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if let clock {
                    Text(clock.startedAt, style: .timer).font(.caption.monospacedDigit()).multilineTextAlignment(.center).widgetAccentable()
                } else {
                    Image(systemName: "stopwatch").font(.title3)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                if let clock {
                    Text(clock.startedAt, style: .timer).font(.headline.monospacedDigit()).widgetAccentable()
                    Text(clock.heading).lineLimit(2)
                } else {
                    Text("Clock").font(.headline).widgetAccentable()
                    Text("Not clocked in").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#else
/// The complications build for watchOS only; elsewhere the product does nothing.
@main
enum OrgstarWatchWidgets {
    static func main() {}
}
#endif
