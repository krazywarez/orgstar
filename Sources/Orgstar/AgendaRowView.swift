import AppKit
import OrgApp
import OrgDocument
import OrgCore
import OrgPresentation
import SwiftUI

/// One agenda line: the time or status over an icon, the category above the title, progress
/// and tags after it, and the TODO keyword and priority at the end.
struct AgendaRowView: View {
    let row: AgendaRow
    /// The agenda day the row is on, for habit graphs.
    var day: Int
    var showsGutter = true
    var selected = false
    var hovered = false
    /// Marked for a bulk action.
    var marked = false
    @Environment(\.orgTheme) private var theme

    static let gutterWidth: CGFloat = 92

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsGutter { gutter }
            VStack(alignment: .leading, spacing: 2) {
                if !row.category.isEmpty { categoryLine }
                titleLine
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let habit = row.item?.habit {
                HabitGraph(cells: habit.graph(today: day), theme: theme)
            }
            if let todo = row.todo {
                let color = theme.dynamic(row.isDone ? .systemGreen : .systemRed) { [theme, row] in theme.todoColor(todo, isDone: row.isDone, dark: $0) }
                Text(todo)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .fixedSize()
            }
            priorityBadge
                .frame(width: 18)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        // `org-agenda-dim-blocked-tasks`.
        .opacity(row.isBlocked ? 0.5 : 1)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? theme.color("selection") ?? Color.accentColor.opacity(0.2) : hovered ? Color.primary.opacity(0.05) : .clear)
                .padding(.horizontal, 6)
        }
        .overlay(alignment: .leading) {
            if marked {
                Capsule().fill(theme.color("agenda-today") ?? .accentColor).frame(width: 3).padding(.vertical, 8).padding(.leading, 8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        theme.dynamic(.secondaryLabelColor) { [theme, row] in theme.statusColor(row.status, dark: $0) }
    }

    private var gutter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.gutter)
                .font(.system(size: 12, weight: row.status == .overdue || row.status == .dueSoon ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: row.icon == .event ? 8 : 10, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(height: 12)
            }
        }
        .frame(width: Self.gutterWidth, alignment: .leading)
    }

    /// Overdue entries show a warning, done ones a check, as the status says first.
    private var symbol: String? {
        guard let icon = row.icon else { return nil }
        if row.status == .overdue { return "exclamationmark.circle.fill" }
        if row.status == .done { return "checkmark.circle.fill" }
        switch icon {
        case .scheduled: return "calendar"
        case .deadline: return "flag.fill"
        case .habit: return "repeat"
        case .event: return "circle.fill"
        case .timestamp: return row.start == nil ? "calendar" : "clock"
        }
    }

    private var iconColor: Color {
        if let event = row.event { return theme.dynamic(.systemPurple) { [theme] in theme.eventColor(event, dark: $0) } }
        return row.status == .normal ? Color.secondary.opacity(0.8) : statusColor
    }

    private var categoryLine: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(row.event.map { event in theme.dynamic(.systemPurple) { [theme] in theme.eventColor(event, dark: $0) } }
                    ?? theme.dynamic { [theme, row] in theme.categoryColor(row.category, dark: $0) })
                .frame(width: 6, height: 6)
            Text(row.category)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("agenda-category") ?? .secondary)
                .lineLimit(1)
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(row.title.isEmpty ? " " : row.title)
                .font(.system(size: 13))
                .strikethrough(row.isDone)
                .foregroundStyle(row.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.color("foreground") ?? .primary))
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach([row.progress, row.detail].compactMap { $0 }, id: \.self) { progress in
                Text(progress)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .fixedSize()
            }
            ForEach(row.tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.color("tags") ?? .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().strokeBorder((theme.color("tags") ?? .secondary).opacity(0.35), lineWidth: 0.5))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var priorityBadge: some View {
        if let priority = row.priority {
            let color = theme.dynamic(.systemOrange) { [theme] in theme.priorityColor(priority, dark: $0) }
            Text(priority)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(color.opacity(0.14)))
                .overlay(Circle().strokeBorder(color.opacity(0.6), lineWidth: 1))
                .help("Priority \(priority)")
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
    }
}

/// org-habit's consistency graph: a cell per day, `*` where the habit was done, `!` today.
struct HabitGraph: View {
    let cells: [Habit.Cell]
    var theme: ThemeSpec = .default

    var body: some View {
        HStack(spacing: 1) {
            ForEach(cells, id: \.day) { cell in
                Text(String(cell.glyph))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 8, height: 14)
                    .background(color(cell.face))
                    .help(Self.label(cell))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Done \(cells.filter { $0.glyph == "*" }.count) of the last \(Habit.precedingDays) days")
    }

    /// Due-state colors, lighter for days to come, as org-habit's faces.
    func color(_ face: Habit.Face) -> Color {
        func themed(_ key: String, _ fallback: Color) -> Color { theme.color(key) ?? fallback }
        switch face {
        case .clear: return themed("habit-clear", .blue).opacity(0.7)
        case .clearFuture: return themed("habit-clear", .blue).opacity(0.35)
        case .ready: return themed("habit-ready", .green).opacity(0.75)
        case .readyFuture: return themed("habit-ready", .green).opacity(0.35)
        case .alert: return themed("habit-alert", .yellow).opacity(0.85)
        case .alertFuture: return themed("habit-alert", .yellow).opacity(0.4)
        case .overdue: return themed("habit-overdue", .red).opacity(0.75)
        case .overdueFuture: return themed("habit-overdue", .red).opacity(0.35)
        }
    }

    static func label(_ cell: Habit.Cell) -> String {
        let date = Days.date(cell.day)
        return String(format: "%04d-%02d-%02d", date.year, date.month, date.day) + (cell.glyph == "*" ? " DONE" : "")
    }
}
