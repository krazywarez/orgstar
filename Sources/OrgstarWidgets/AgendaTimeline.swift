import OrgApp
import SwiftUI
import WidgetKit

struct AgendaEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has written one.
    let snapshot: AgendaSnapshot?
}

/// The app's agenda snapshot, with an entry for each time what's left of the day changes.
struct AgendaProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaEntry {
        AgendaEntry(date: .now, snapshot: .sample(.now))
    }

    func getSnapshot(in context: Context, completion: @escaping (AgendaEntry) -> Void) {
        let snapshot = Self.load()
        completion(AgendaEntry(date: .now, snapshot: snapshot ?? (context.isPreview ? .sample(.now) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaEntry>) -> Void) {
        completion(Self.timeline(Self.load(), now: .now))
    }

    static func load() -> AgendaSnapshot? {
        AgendaSnapshot.file().flatMap(AgendaSnapshot.read)
    }

    static func timeline(_ snapshot: AgendaSnapshot?, now: Date, calendar: Calendar = .current) -> Timeline<AgendaEntry> {
        let changes = snapshot?.changes(after: now, calendar: calendar)
            ?? [calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!]
        let entries = ([now] + changes).map { AgendaEntry(date: $0, snapshot: snapshot) }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

extension AgendaSnapshot.Hex {
    func color(_ scheme: ColorScheme) -> Color {
        Self.parse(scheme == .dark ? dark : light) ?? .primary
    }

    /// `#rrggbb` or `#rrggbbaa`.
    static func parse(_ hex: String) -> Color? {
        let digits = hex.dropFirst()
        guard hex.first == "#", digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? value << 8 | 0xFF : value
        func part(_ shift: UInt64) -> Double { Double(full >> shift & 0xFF) / 255 }
        return Color(.sRGB, red: part(24), green: part(16), blue: part(8), opacity: part(0))
    }
}

extension AgendaSnapshot {
    /// Nil where the theme leaves `key` to the system in `scheme`.
    func color(_ key: String, _ scheme: ColorScheme) -> Color? {
        colors[key].flatMap { AgendaSnapshot.Hex.parse(scheme == .dark ? $0.dark : $0.light) }
    }

    /// A day for the gallery and previews.
    static func sample(_ now: Date, calendar: Calendar = .current) -> AgendaSnapshot {
        let midnight = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int = 0) -> Date { midnight.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
        let red = Hex(light: "#d70015", dark: "#ff6961")
        let orange = Hex(light: "#c93400", dark: "#ff9f0a")
        let gray = Hex(light: "#6c6c70", dark: "#98989d")
        let blue = Hex(light: "#0a66d8", dark: "#409cff")
        func row(
            _ title: String, _ gutter: String, status: String = "normal", todo: String? = nil, todoColor: Hex? = nil,
            priority: String? = nil, category: String = "work", start: Date? = nil, end: Date? = nil
        ) -> Row {
            Row(
                id: title, gutter: gutter, status: status, title: title, category: category, todo: todo, priority: priority, isDone: false,
                isEvent: false, start: start, end: end, path: nil, offset: nil,
                statusColor: status == "overdue" ? red : status == "due-soon" ? orange : gray, todoColor: todoColor,
                priorityColor: priority == nil ? nil : red, categoryColor: Hex(light: "#2e6b8f", dark: "#7fb8d9")
            )
        }
        let today = Day(
            day: 0, date: midnight, header: "Today",
            overdue: [row("Send the forms", "3d late", status: "overdue", todo: "TODO", todoColor: red, category: "home")],
            rows: [
                row("Standup", "09:30", start: at(9, 30)),
                row("Review the draft", "11:00–12:00", todo: "NEXT", todoColor: blue, priority: "A", start: at(11), end: at(12)),
                row("Dentist", "14:00", category: "home", start: at(14)),
                row("File expenses", "Due today", status: "due-soon", todo: "TODO", todoColor: red),
            ]
        )
        let tomorrow = Day(
            day: 1, date: calendar.date(byAdding: .day, value: 1, to: midnight)!, header: "Tomorrow", overdue: [],
            rows: [row("Plan the week", "Scheduled", todo: "TODO", todoColor: red)]
        )
        return AgendaSnapshot(
            generated: now, days: [today, tomorrow],
            colors: ["agenda-today": Hex(light: "#007aff", dark: "#0a84ff"), "agenda-time": gray, "foreground": Hex(light: "#1f2328", dark: "#e6edf3")]
        )
    }
}
