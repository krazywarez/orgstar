import Foundation

/// `org-stuck-projects` (Org 9.8.7): projects are the entries `match` finds; one is not stuck
/// when its subtree, its own heading included, has a heading with one of `todo` (`*` for any
/// open keyword), a heading with one of `tags` set on it (`*` for any tag), or text matching
/// `regexp`.
public struct StuckProjects: Sendable, Hashable {
    public var match: String
    public var todo: [String]
    public var tags: [String]
    /// In Emacs syntax; empty for none.
    public var regexp: String

    public init(match: String = "+LEVEL=2/-DONE", todo: [String] = ["TODO", "NEXT", "NEXTACTION"], tags: [String] = [], regexp: String = "") {
        self.match = match
        self.todo = todo
        self.tags = tags
        self.regexp = regexp
    }

    /// The `skip-re` of `org-agenda-list-stuck-projects`, compiled; nil when the definition
    /// names nothing that unsticks a project.
    func unstuck(_ sources: [AgendaSource]) -> NSRegularExpression? {
        var parts: [String] = []
        if !todo.isEmpty {
            var words = todo
            if words.contains("*") {
                var open: [String] = []
                for source in sources { for k in source.notDoneKeywords where !open.contains(k) { open.append(k) } }
                words = open
            }
            parts.append("^\\*+[ \\t]+(" + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?:[ \\t]|$)")
        }
        if tags.contains("*") {
            parts.append(SetTags.tagLine)
        } else if !tags.isEmpty {
            let other = "(?:[[:alnum:]_@#%]+:)*"
            parts.append("^\\*+ .*?[ \\t]:" + other + "(" + tags.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + "):" + other + "[ \\t]*$")
        }
        if regexp.contains(where: { !$0.isWhitespace }) { parts.append(EmacsRegex.translate(regexp)) }
        guard !parts.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: parts.map { "(?:" + $0 + ")" }.joined(separator: "|"), options: .anchorsMatchLines)
    }
}

extension Agenda {
    /// `org-agenda-list-stuck-projects`: the tags view of `definition.match`, without the
    /// projects that something in their subtree unsticks. With nothing to unstick them (Org
    /// signals an error), every match is listed.
    public static func stuckProjects(
        _ sources: [AgendaSource], _ definition: StuckProjects, now: Date = Date(), calendar: Calendar = .current, options: AgendaOptions = AgendaOptions()
    ) -> [AgendaItem] {
        let unstuck = definition.unstuck(sources)
        return tagsMatch(sources, match: definition.match, now: now, calendar: calendar, options: options) { source, index in
            guard let unstuck else { return false }
            let heading = source.headings[index]
            let next = source.headings[(index + 1)...].first { $0.level <= heading.level }?.start
            let ns = source.text as NSString
            // `org-end-of-subtree`: before the line break ending the subtree's last line.
            var end = next ?? ns.length
            if end > heading.start, ns.character(at: end - 1) == 10 { end -= 1 }
            return unstuck.firstMatch(in: source.text, range: NSRange(location: heading.start, length: end - heading.start)) != nil
        }
    }
}
