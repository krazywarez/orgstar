import Foundation

/// An entry as the table and kanban views show it.
public struct BoardEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let headingOffset: Int
    /// The heading line, to check the offset still holds before editing.
    public let headingLine: String
    public let title: String
    public let todo: String?
    public let isDone: Bool
    public let priority: String?
    public let tags: [String]
    public let category: String
    /// Planning timestamps without brackets.
    public let scheduled: String?
    public let deadline: String?
    /// Upper-cased keys of the entry's own drawer.
    public let properties: [String: String]

    public var id: String { "\(path)#\(headingOffset)" }
}

public enum Board {
    /// Entries of `sources` that match `match` (a tags/property/TODO match, as for `m` in the
    /// agenda), or every entry with a TODO keyword when `match` is empty.
    public static func entries(_ sources: [AgendaSource], match: String, now: Date = Date(), calendar: Calendar = .current) -> [BoardEntry] {
        let trimmed = match.trimmingCharacters(in: .whitespaces)
        let matcher = trimmed.isEmpty ? nil : TagsMatcher(trimmed)
        var result: [BoardEntry] = []
        for source in sources {
            for heading in source.headings where !heading.skipped {
                if let matcher {
                    guard matcher.matches(heading, in: source, now: now, calendar: calendar) else { continue }
                } else if heading.todo == nil {
                    continue
                }
                result.append(BoardEntry(
                    path: source.path, headingOffset: heading.start, headingLine: heading.line, title: heading.title,
                    todo: heading.todo, isDone: heading.isDone, priority: heading.priority, tags: heading.tags.map(\.name),
                    category: heading.category, scheduled: heading.scheduled?.raw, deadline: heading.deadline?.raw,
                    properties: heading.properties
                ))
            }
        }
        return result
    }

    /// The keywords for kanban columns, in sequence order: each file's keywords, first come
    /// first.
    public static func keywords(_ sources: [AgendaSource]) -> [String] {
        var seen: [String] = []
        for source in sources {
            for keyword in source.keywords where !seen.contains(keyword) { seen.append(keyword) }
        }
        return seen
    }
}
