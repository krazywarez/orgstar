import OrgApp
import OrgCore
import SwiftUI
import WidgetKit

/// The agenda's habits with org-habit's consistency graphs: the last week (small) or the last
/// three weeks and the next one (medium, large).
struct HabitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sh.krz.orgstar.habits", provider: HabitProvider()) { entry in
            HabitsView(entry: entry)
        }
        .configurationDisplayName("Habits")
        .description("Your habits and how consistently you've kept them.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct HabitEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has written one.
    let snapshot: HabitSnapshot?
}

/// The app's habits, drawn again at each midnight of the next week, when the graphs move on.
struct HabitProvider: TimelineProvider {
    func placeholder(in context: Context) -> HabitEntry {
        HabitEntry(date: .now, snapshot: .sample(.now))
    }

    func getSnapshot(in context: Context, completion: @escaping (HabitEntry) -> Void) {
        let snapshot = HabitSnapshot.read()
        completion(HabitEntry(date: .now, snapshot: snapshot ?? (context.isPreview ? .sample(.now) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HabitEntry>) -> Void) {
        let snapshot = HabitSnapshot.read()
        let midnight = Calendar.current.startOfDay(for: .now)
        let dates = [Date.now] + (1...7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: midnight) }
        completion(Timeline(entries: dates.map { HabitEntry(date: $0, snapshot: snapshot) }, policy: .atEnd))
    }
}

struct HabitsView: View {
    let entry: HabitEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var today: Int { Days.absolute(entry.date, calendar: .current) }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.habits.isEmpty {
                content(snapshot)
            } else {
                Text(entry.snapshot == nil ? "Open orgstar to show your habits here." : "No habits in the agenda. Give an entry STYLE: habit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .widgetURL(AppLink.agenda.url)
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }

    private func content(_ snapshot: HabitSnapshot) -> some View {
        let limit = family == .systemLarge ? 9 : family == .systemMedium ? 4 : 3
        let done = snapshot.habits.filter { $0.habit.doneDates.contains(today) }.count
        return VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Habits").font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(done)/\(snapshot.habits.count) today").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(snapshot.habits.prefix(limit)) { habit in
                Link(destination: habit.link.url) { row(habit, snapshot) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ habit: HabitSnapshot.Entry, _ snapshot: HabitSnapshot) -> some View {
        if family == .systemSmall {
            // The last week, today last.
            let cells = habit.habit.graph(today: today, preceding: 6, following: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(habit.title).font(.caption).lineLimit(1)
                HabitCells(cells: cells, colors: snapshot.colors, width: 12, height: 8)
            }
        } else {
            HStack(spacing: 8) {
                Text(habit.title).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                HabitCells(cells: habit.habit.graph(today: today), colors: snapshot.colors, width: 5, height: 12)
            }
        }
    }
}

/// org-habit's graph: a bar per day in the due-state color, lighter for days to come, a dot
/// where it was done, today outlined.
struct HabitCells: View {
    let cells: [Habit.Cell]
    let colors: [String: AgendaSnapshot.Hex]
    let width: CGFloat
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 1) {
            ForEach(cells, id: \.day) { cell in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(cell.face))
                    .frame(width: width, height: height)
                    .overlay {
                        if cell.glyph == "*" { Circle().fill(.white.opacity(0.9)).frame(width: min(width, height) * 0.6) }
                    }
                    .overlay {
                        if cell.glyph == "!" { RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.primary, lineWidth: 1) }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Done \(cells.filter { $0.glyph == "*" }.count) of \(cells.count) days")
    }

    private func color(_ face: Habit.Face) -> Color {
        func themed(_ key: String, _ fallback: Color) -> Color { colors[key]?.color(scheme) ?? fallback }
        switch face {
        case .clear: return themed("habit-clear", .blue).opacity(0.7)
        case .clearFuture: return themed("habit-clear", .blue).opacity(0.3)
        case .ready: return themed("habit-ready", .green).opacity(0.8)
        case .readyFuture: return themed("habit-ready", .green).opacity(0.3)
        case .alert: return themed("habit-alert", .yellow).opacity(0.85)
        case .alertFuture: return themed("habit-alert", .yellow).opacity(0.35)
        case .overdue: return themed("habit-overdue", .red).opacity(0.8)
        case .overdueFuture: return themed("habit-overdue", .red).opacity(0.3)
        }
    }
}

extension HabitSnapshot {
    /// Habits for the gallery and previews.
    static func sample(_ now: Date) -> HabitSnapshot {
        let today = Days.absolute(now, calendar: .current)
        func habit(_ every: Int, done: [Int]) -> Habit {
            Habit(scheduled: today, scheduledRepeat: every, doneDates: done.map { today - $0 }.sorted())
        }
        return HabitSnapshot(
            habits: [
                Entry(title: "Stretch", path: "", offset: 0, habit: habit(1, done: [1, 2, 3, 5, 6, 7, 9, 10, 12, 13, 14])),
                Entry(title: "Read 20 pages", path: "", offset: 0, habit: habit(1, done: [1, 3, 4, 8, 11, 15])),
                Entry(title: "Water plants", path: "", offset: 0, habit: habit(3, done: [2, 5, 8, 11, 14, 17])),
                Entry(title: "Review the week", path: "", offset: 0, habit: habit(7, done: [6, 13, 20])),
            ],
            colors: [:]
        )
    }
}

#Preview("Small", as: .systemSmall) {
    HabitsWidget()
} timeline: {
    HabitEntry(date: .now, snapshot: .sample(.now))
}

#Preview("Medium", as: .systemMedium) {
    HabitsWidget()
} timeline: {
    HabitEntry(date: .now, snapshot: .sample(.now))
}
