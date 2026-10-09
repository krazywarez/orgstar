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
}

/// A named view: the built-in ones and those in `views.toml`.
public struct AgendaViewDefinition: Hashable, Sendable, Identifiable {
    public let name: String
    public let mode: AgendaMode
    public var id: String { name }

    public init(name: String, mode: AgendaMode) {
        self.name = name
        self.mode = mode
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
/// (`WAIT|HOLD`); a `search` view's `match` is its search string.
@MainActor
public enum AgendaViewLoader {
    public static var userFile: URL { UserConfig.file("views.toml") }

    public static let builtIn = [
        AgendaViewDefinition(name: "Agenda", mode: .agenda(span: nil, startOffset: nil)),
        AgendaViewDefinition(name: "TODO List", mode: .todo(keywords: nil)),
    ]

    /// The built-in views followed by the user's, and the problems found in the file.
    public static func load(userFile: URL = userFile) -> (views: [AgendaViewDefinition], problems: [String]) {
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
            views.append(AgendaViewDefinition(name: name, mode: mode))
        }
        return (views, problems)
    }
}
