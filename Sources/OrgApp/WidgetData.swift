import Foundation
import OrgCore
import OrgPresentation

/// What the widgets and controls show besides the agenda, written by the app into the app
/// group's container as `AgendaSnapshot` is.
public protocol WidgetData: Codable, Equatable, Sendable {
    static var name: String { get }
}

extension WidgetData {
    /// `Widgets/<name>` in the app group's container; nil without the group.
    public static func file(group: String = CaptureInbox.group) -> URL? {
        AgendaSnapshot.file(group: group)?.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func read(from file: URL? = Self.file()) -> Self? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? AgendaSnapshot.decoder.decode(Self.self, from: data)
    }

    /// Writes unless the file holds the same; true when it wrote.
    @discardableResult
    public func write(to file: URL? = Self.file()) throws -> Bool {
        guard let file, Self.read(from: file) != self else { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgendaSnapshot.encoder.encode(self).write(to: file, options: .atomic)
        return true
    }
}

/// The agenda files' habits, whose consistency graphs the widget draws for its own day.
public struct HabitSnapshot: WidgetData {
    public static let name = "habits.json"

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var title: String
        public var path: String
        public var offset: Int
        public var habit: Habit
        public var id: String { "\(path):\(offset)" }

        public init(title: String, path: String, offset: Int, habit: Habit) {
            self.title = title
            self.path = path
            self.offset = offset
            self.habit = habit
        }

        public var link: AppLink { .entry(path: path, offset: offset) }
    }

    public var habits: [Entry]
    /// `habit-clear`, `habit-ready`, `habit-alert` and `habit-overdue`.
    public var colors: [String: AgendaSnapshot.Hex]

    public init(habits: [Entry], colors: [String: AgendaSnapshot.Hex]) {
        self.habits = habits
        self.colors = colors
    }

    /// `habits`, colored by `theme`.
    public init(habits: [Entry], theme: ThemeSpec) {
        var colors: [String: AgendaSnapshot.Hex] = [:]
        for key in ["habit-clear", "habit-ready", "habit-alert", "habit-overdue"] {
            colors[key] = AgendaSnapshot.Hex { theme.color(key, dark: $0) }
        }
        self.init(habits: habits, colors: colors)
    }
}

/// The running clock and the entry Clock In Last would clock into, for the clock control.
public struct ClockSnapshot: WidgetData {
    public static let name = "clock.json"

    public var running: String?
    public var startedAt: Date?
    /// The most recent entry clocked, `org-clock-in-last`'s.
    public var last: String?

    public init(running: String?, startedAt: Date?, last: String?) {
        self.running = running
        self.startedAt = startedAt
        self.last = last
    }
}

/// The capture templates' keys and names, for choosing one in a widget's or control's settings.
public struct TemplateList: WidgetData {
    public static let name = "templates.json"

    public struct Template: Codable, Equatable, Sendable {
        public var key: String
        public var name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    public var templates: [Template]

    public init(templates: [Template]) {
        self.templates = templates
    }
}
