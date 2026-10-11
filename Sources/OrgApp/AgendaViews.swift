import Foundation
import OrgCore

/// What the agenda window shows.
public enum AgendaMode: Hashable, Sendable {
    /// `org-agenda-list`; nil span and start use the settings.
    case agenda(span: Int?, startOffset: Int?)
    /// `org-todo-list`, optionally for `KWD1|KWD2`.
    case todo(keywords: String?)
    /// `org-tags-view`.
    case match(String, todoOnly: Bool)
    /// `org-search-view`.
    case search(String, todoOnly: Bool)

    /// The key `org-agenda-prefix-format` and `org-agenda-sorting-strategy` use for this kind
    /// of view.
    public var viewKey: String {
        switch self {
        case .agenda: "agenda"
        case .todo: "todo"
        case .match: "tags"
        case .search: "search"
        }
    }
}

/// A view's own `org-agenda-prefix-format` and `org-agenda-sorting-strategy`, as an
/// `org-agenda-custom-commands` entry's settings give them.
public struct AgendaViewSettings: Hashable, Sendable {
    public var prefixFormat: String?
    public var sortingStrategy: [String]?

    public init(prefixFormat: String? = nil, sortingStrategy: [String]? = nil) {
        self.prefixFormat = prefixFormat
        self.sortingStrategy = sortingStrategy
    }

    public func apply(to options: AgendaOptions, view: String) -> AgendaOptions {
        var options = options
        if let prefixFormat { options.prefixFormat[view] = prefixFormat }
        if let sortingStrategy { options.sortingStrategy[view] = sortingStrategy }
        return options
    }
}

/// A named view: the built-in ones and those in `views.toml`.
public struct AgendaViewDefinition: Hashable, Sendable, Identifiable {
    public let name: String
    public let mode: AgendaMode
    public var settings: AgendaViewSettings
    public var id: String { name }

    public init(name: String, mode: AgendaMode, settings: AgendaViewSettings = AgendaViewSettings()) {
        self.name = name
        self.mode = mode
        self.settings = settings
    }
}

/// Reads `views.toml`:
///
/// ```toml
/// [[view]]
/// name = "Work"
/// type = "match"        # agenda, todo, match, todo-match, search or todo-search
/// match = "+work-boss"
/// ```
///
/// `agenda` views take `span` and `start` (days from today), `todo` views `keywords`
/// (`WAIT|HOLD`); a `search` view's `match` is its search string. Any view can set
/// `prefix-format` and `sorting-strategy` (keys separated by spaces) for itself.
@MainActor
public enum AgendaViewLoader {
    public static var userFile: URL { UserConfig.file("views.toml") }

    public static let builtIn = [
        AgendaViewDefinition(name: "Agenda", mode: .agenda(span: nil, startOffset: nil)),
        AgendaViewDefinition(name: "TODO List", mode: .todo(keywords: nil)),
    ]

    /// The views' settings by mode; the first view with a mode wins.
    public static func settings(_ views: [AgendaViewDefinition]) -> [AgendaMode: AgendaViewSettings] {
        var settings: [AgendaMode: AgendaViewSettings] = [:]
        for view in views where settings[view.mode] == nil && view.settings != AgendaViewSettings() { settings[view.mode] = view.settings }
        return settings
    }

    /// The built-in views followed by the user's, and the problems found in the file.
    public static func load(userFile: URL = userFile) -> (views: [AgendaViewDefinition], problems: [String]) {
        let interval = Perf.begin("views.load")
        defer { interval.end() }
        guard let text = try? String(contentsOf: userFile, encoding: .utf8) else { return (builtIn, []) }
        let tables: [TOML.Table]
        do {
            tables = try TOML.parse(text)
        } catch {
            return (builtIn, ["views.toml: \(error)"])
        }
        var views = builtIn
        var problems: [String] = []
        for table in tables where !(table.name.isEmpty && table.values.isEmpty) {
            guard table.name == "view", table.isArrayElement else {
                problems.append("views.toml line \(table.line): expected [[view]]")
                continue
            }
            guard let name = table.values["name"]?.string else {
                problems.append("views.toml line \(table.line): a view needs a name")
                continue
            }
            let match = table.values["match"]?.string
            let mode: AgendaMode
            switch table.values["type"]?.string ?? "agenda" {
            case "agenda":
                mode = .agenda(span: table.values["span"]?.integer, startOffset: table.values["start"]?.integer)
            case "todo":
                mode = .todo(keywords: table.values["keywords"]?.string)
            case "match", "todo-match":
                guard let match else {
                    problems.append("views.toml line \(table.line): \(name) needs a match")
                    continue
                }
                mode = .match(match, todoOnly: table.values["type"]?.string == "todo-match")
            case "search", "todo-search":
                guard let match else {
                    problems.append("views.toml line \(table.line): \(name) needs a match")
                    continue
                }
                mode = .search(match, todoOnly: table.values["type"]?.string == "todo-search")
            case let other:
                problems.append("views.toml line \(table.line): unknown type \(other)")
                continue
            }
            var settings = AgendaViewSettings(prefixFormat: table.values["prefix-format"]?.string)
            if let strategy = table.values["sorting-strategy"]?.string {
                let keys = strategy.split(whereSeparator: \.isWhitespace).map(String.init)
                if let bad = keys.first(where: { !AgendaSort.keys.contains($0) }) {
                    problems.append("views.toml line \(table.line): unknown sorting key \(bad)")
                }
                settings.sortingStrategy = keys.filter(AgendaSort.keys.contains)
            }
            views.append(AgendaViewDefinition(name: name, mode: mode, settings: settings))
        }
        return (views, problems)
    }
}
