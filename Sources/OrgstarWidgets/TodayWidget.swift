import OrgApp
import SwiftUI
import WidgetKit

/// Today's agenda on the Home Screen: what's next (small), today's list (medium), today and
/// tomorrow (large).
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sh.krz.orgstar.today", provider: AgendaProvider()) { entry in
            TodayView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("What's left of today's agenda.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodayView: View {
    let entry: AgendaEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                Text("Open Orgstar to show your agenda here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .widgetURL(AppLink.agenda.url)
        .containerBackground(for: .widget) {
            entry.snapshot?.color("agenda-background", scheme) ?? Color(uiColor: .systemBackground)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: AgendaSnapshot) -> some View {
        let upcoming = snapshot.upcoming(at: entry.date)
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            header(snapshot)
            switch family {
            case .systemSmall:
                rows(Array(upcoming.prefix(3)), snapshot, compact: true, empty: "Nothing left today")
            case .systemLarge:
                rows(Array(upcoming.prefix(6)), snapshot, compact: false, empty: "Nothing left today")
                if let tomorrow = snapshot.day(after: entry.date) {
                    let next = (tomorrow.rows + tomorrow.overdue).filter { !$0.isDone }
                    Divider()
                    Text("Tomorrow").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    rows(Array(next.prefix(max(2, 9 - min(upcoming.count, 6)))), snapshot, compact: false, empty: "Nothing scheduled")
                }
            default:
                rows(Array(upcoming.prefix(4)), snapshot, compact: false, empty: "Nothing left today")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ snapshot: AgendaSnapshot) -> some View {
        let open = snapshot.openCount(at: entry.date)
        let overdue = snapshot.overdueCount(at: entry.date)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.date, format: family == .systemSmall ? .dateTime.weekday(.abbreviated).day() : .dateTime.weekday(.wide).day().month())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(snapshot.color("agenda-today", scheme) ?? .accentColor)
            Spacer(minLength: 0)
            if overdue > 0, family != .systemSmall {
                Text("\(overdue) overdue")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(snapshot.day(at: entry.date)?.overdue.first?.statusColor?.color(scheme) ?? .red)
            }
            Text(family == .systemSmall ? "\(open)" : "\(open) open")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rows(_ rows: [AgendaSnapshot.Row], _ snapshot: AgendaSnapshot, compact: Bool, empty: String) -> some View {
        if rows.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
            if compact {
                SmallRow(row: row)
            } else if let link = row.link {
                Link(destination: link.url) { WideRow(row: row) }
            } else {
                WideRow(row: row)
            }
        }
    }
}

/// The gutter over the title.
struct SmallRow: View {
    let row: AgendaSnapshot.Row
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.gutter)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(row.statusColor?.color(scheme) ?? .secondary)
            Text(row.title).font(.caption).lineLimit(1)
        }
    }
}

/// The gutter, keyword and priority badges, the title and the category's dot.
struct WideRow: View {
    let row: AgendaSnapshot.Row
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Text(row.gutter)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(row.statusColor?.color(scheme) ?? .secondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            if let todo = row.todo {
                let color = row.todoColor?.color(scheme) ?? .secondary
                Text(todo)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.14), in: Capsule())
            }
            if let priority = row.priority {
                let color = row.priorityColor?.color(scheme) ?? .orange
                Text(priority)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(color, lineWidth: 1))
            }
            Text(row.title).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Circle().fill(row.categoryColor?.color(scheme) ?? .secondary).frame(width: 6, height: 6)
        }
    }
}

#Preview("Small", as: .systemSmall) {
    TodayWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .sample(.now))
}

#Preview("Medium", as: .systemMedium) {
    TodayWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .sample(.now))
}

#Preview("Large", as: .systemLarge) {
    TodayWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .sample(.now))
    AgendaEntry(date: .now, snapshot: nil)
}
