import Foundation

/// `org-emphasize`: wraps the selection in an emphasis marker, replacing one it already has, or
/// with no selection inserts a pair and puts the caret between. A space removes the marker.
/// `marker` set is the command for one marker, as the Mac preset's ⌘B binds it.
public struct Emphasize: OrgCommand {
    let marker: Character?
    public init(marker: Character? = nil) { self.marker = marker }

    /// `org-emphasis-alist`'s markers, and the id and title of each one's own command.
    static let markers: [(marker: Character, name: String, title: String)] = [
        ("*", "bold", "Bold"), ("/", "italic", "Italic"), ("_", "underline", "Underline"),
        ("=", "verbatim", "Verbatim"), ("~", "code", "Code"), ("+", "strike-through", "Strike-Through"),
    ]
    /// `org-emphasis-regexp-components`: what may come before and after a marker.
    static let before: Set<Character> = ["-", "(", "'", "\"", "{", "\n"]
    static let after: Set<Character> = ["-", ".", ",", ":", "!", "?", ";", "'", "\"", ")", "}", "\\", "[", "\n"]

    public var id: String { marker.flatMap { m in Self.markers.first { $0.marker == m } }.map { "org.emphasize.\($0.name)" } ?? "org.emphasize" }
    public var title: String { marker.flatMap { m in Self.markers.first { $0.marker == m } }.map(\.title) ?? "Emphasize…" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        let answer: Character
        if let marker {
            answer = marker
        } else if let given = context.answers["emphasis"]?.first {
            answer = given
        } else {
            let items = Self.markers.map { FastSelection.Item.option(key: $0.marker, name: $0.name) } + [.option(key: " ", name: "remove")]
            let message = "Emphasis marker or tag: [\(String(Self.markers.map(\.marker)))]"
            return .prompt(Prompt(key: "emphasis", message: message, fast: FastSelection(items: items, multiple: false)))
        }
        guard answer == " " || Self.markers.contains(where: { $0.marker == answer }) else {
            return .failed("No such emphasis marker: \"\(answer)\"")
        }
        let text = context.text as NSString
        let selection = context.selection.first ?? context.caret..<context.caret
        let move = selection.isEmpty
        var inner = text.substring(with: NSRange(selection))
        // A selection already emphasized loses its markers first.
        while inner.count > 1, let first = inner.first, inner.last == first, Self.markers.contains(where: { $0.marker == first }) {
            inner = String(inner.dropFirst().dropLast())
        }
        let marker = answer == " " ? "" : String(answer)
        let string = marker + inner + marker
        func char(at offset: Int) -> Character? {
            guard offset >= 0, offset < text.length else { return nil }
            return Character(text.substring(with: text.rangeOfComposedCharacterSequence(at: offset)))
        }
        let previous = char(at: selection.lowerBound - 1)
        let next = char(at: selection.upperBound)
        let lead = previous.map { $0.isWhitespace || Self.before.contains($0) } ?? true ? "" : " "
        let trail = next.map { $0.isWhitespace || Self.after.contains($0) } ?? true ? "" : " "
        let start = selection.lowerBound + lead.utf16.count
        let caret = move && answer != " " ? start + string.utf16.count - 1 : start + string.utf16.count
        return .commit(EditResult(
            baseRevision: context.revision,
            edits: [TextEdit(range: selection, replacement: lead + string + trail)],
            selection: [caret..<caret]
        ))
    }
}
