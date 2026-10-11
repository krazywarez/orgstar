import OrgApp
import SwiftUI
import WidgetKit

/// The agenda on the Lock Screen: the next entry (rectangular), the next entry or the count
/// (inline), today's open entries (circular). On the Mac, the next entry in a small widget.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sh.krz.orgstar.up-next", provider: AgendaProvider()) { entry in
            UpNextView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("The next agenda entry, or how many are open today.")
        #if os(macOS)
        .supportedFamilies([.systemSmall])
        #else
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
        #endif
    }
}

struct UpNextView: View {
    let entry: AgendaEntry
    @Environment(\.widgetFamily) private var family

    private var next: AgendaSnapshot.Row? { entry.snapshot?.upcoming(at: entry.date).first }
    private var open: Int { entry.snapshot?.openCount(at: entry.date) ?? 0 }

    var body: some View {
        content
            .widgetURL((next?.link ?? .agenda).url)
            #if os(macOS)
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
            #else
            .containerBackground(for: .widget) { Color.clear }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            if let next {
                Text("\(next.gutter) \(next.title)")
            } else {
                Text(open == 0 ? "Agenda clear" : "\(open) open today")
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text("\(open)").font(.title2.weight(.semibold)).widgetAccentable()
                    Text("open").font(.caption2)
                }
            }
            .accessibilityLabel("\(open) open today")
        default:
            if let next {
                VStack(alignment: .leading, spacing: 0) {
                    Text(next.gutter).font(.headline).widgetAccentable().lineLimit(1)
                    Text(next.title).font(.body).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Agenda").font(.headline).widgetAccentable()
                    Text(entry.snapshot == nil ? "Open orgstar" : "Nothing left today").font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#if os(iOS)
#Preview("Rectangular", as: .accessoryRectangular) {
    UpNextWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .sample(.now))
}

#Preview("Inline", as: .accessoryInline) {
    UpNextWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .sample(.now))
}

#Preview("Circular", as: .accessoryCircular) {
    UpNextWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .sample(.now))
}
#endif
