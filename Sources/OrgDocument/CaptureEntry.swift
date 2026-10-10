import Foundation
import OrgCore

/// The first heading of a capture's text, as the capture sheet shows and changes it: its
/// keyword, priority, tags and planning, set by running the editor's own commands on the text.
public struct CaptureEntry: Sendable, Equatable {
    public var todo: String?
    public var priority: String?
    public var tags: [String]
    public var scheduled: Timestamp?
    public var deadline: Timestamp?
    /// The keywords of the text's settings, as sequences list them, active before done.
    public var keywords: [String]
    /// The priorities from highest to lowest: `A`, `B`, `C`, or numbers.
    public var priorities: [String]

    /// Nil when the text has no heading.
    public init?(text: String, defaults: OrgSettings = .default) {
        let tree = OrgParser.parse(text, defaults: defaults)
        guard let heading = DocumentModel(tree: tree).headings.first else { return nil }
        todo = heading.todo
        priority = heading.priority
        tags = heading.localTags
        scheduled = heading.scheduled
        deadline = heading.deadline
        keywords = tree.settings.todoSequences.flatMap { $0.active.map(\.name) + $0.done.map(\.name) }
        let range = tree.settings.priorities
        if let high = Int(range.highest), let low = Int(range.lowest), high <= low {
            priorities = (high...low).map(String.init)
        } else if let high = range.highest.unicodeScalars.first?.value, let low = range.lowest.unicodeScalars.first?.value, high <= low {
            priorities = (high...low).compactMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else {
            priorities = []
        }
    }

    /// `text` after `command` runs on its first heading with `answers`, or nil when the command
    /// asks something else, fails, or changes nothing.
    public static func applying(
        _ command: any OrgCommand, answers: [String: String], to text: String, defaults: OrgSettings = .default,
        options: EditingOptions = .org, now: Date = Date()
    ) -> String? {
        var state = DocumentState(bytes: Array(text.utf8), defaults: defaults)
        guard let start = DocumentModel(tree: state.tree).headings.first?.headingRange.lowerBound,
              case .commit = try? state.run(command, selection: [start..<start], now: now, answers: answers, options: options),
              state.text != text else { return nil }
        return state.text
    }
}
