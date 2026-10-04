import Foundation

public struct TextEdit: Sendable, Equatable {
    /// UTF-16 range in the old text, on unicode scalar boundaries.
    public let range: Range<Int>
    public let replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// Works on unicode scalars, so an edit between "\r" and "\n" stays exact.
    public func apply(to text: String) -> String {
        let scalars = text.unicodeScalars
        let start = String.Index(utf16Offset: range.lowerBound, in: text)
        let end = String.Index(utf16Offset: range.upperBound, in: text)
        return String(scalars[..<start]) + replacement + String(scalars[end...])
    }
}

enum ReparseStrategy: Equatable {
    /// One element reparsed in place; everything else reused.
    case element
    /// A run of top-level sections reparsed; the sections before and after reused.
    case sections
    case full
}

extension OrgParser {
    /// The tree for `edit.apply(to: oldText)`, reusing as much of `old` as stays valid. Always
    /// equal to a full parse of the new text.
    public static func reparse(_ old: OrgTree, oldText: String, edit: TextEdit, defaults: OrgSettings = .default) -> OrgTree {
        reparseWithStrategy(old, oldText: oldText, edit: edit, defaults: defaults).tree
    }

    static func reparseWithStrategy(
        _ old: OrgTree, oldText: String, edit: TextEdit, defaults: OrgSettings = .default
    ) -> (tree: OrgTree, strategy: ReparseStrategy) {
        let newText = edit.apply(to: oldText)
        let context = EditContext(oldText: oldText, newText: newText, edit: edit)
        if context.touchesSettings() { return (parse(newText, defaults: defaults), .full) }
        if let tree = context.reparseElement(old) { return (tree, .element) }
        if let tree = context.reparseSections(old) { return (tree, .sections) }
        return (parse(newText, defaults: defaults), .full)
    }
}

private struct EditContext {
    let oldText: String
    let newText: String
    let edit: TextEdit
    /// Change in UTF-16 length.
    var delta: Int { edit.replacement.utf16.count - edit.range.count }

    static let settingsKeys: Set<String> = ["TODO", "SEQ_TODO", "TYP_TODO", "PRIORITIES"]

    /// Elements that parse the same in isolation as in place, as long as their lines keep
    /// their classes.
    static let leafKinds: Set<SyntaxKind> = [
        .paragraph, .heading, .tableRow, .planning, .clock, .keyword, .affiliatedKeyword, .horizontalRule,
        .nodeProperty, .block, .comment, .fixedWidth, .footnoteDefinition,
    ]

    /// File settings must be read again when an edited line is a settings keyword, or when it
    /// moves a block or heading boundary in a file that has settings keywords: that can hide or
    /// expose a keyword inside a block.
    func touchesSettings() -> Bool {
        let start = lineStart(oldText, edit.range.lowerBound)
        let oldLines = classes(slice(oldText, start, lineEnd(oldText, edit.range.upperBound)))
        let newLines = classes(slice(newText, start, lineEnd(newText, edit.range.lowerBound + edit.replacement.utf16.count)))
        var movesBoundary = false
        for line in oldLines + newLines {
            switch line.cls {
            case .keyword(let key) where Self.settingsKeys.contains(key):
                return true
            case .blockBegin, .blockEnd, .dynamicBegin, .dynamicEnd, .heading:
                movesBoundary = true
            default:
                break
            }
        }
        return movesBoundary && Self.settingsKeys.contains { newText.range(of: "#+\($0):", options: .caseInsensitive) != nil }
    }

    // MARK: - Element

    func reparseElement(_ old: OrgTree) -> OrgTree? {
        guard let leaf = leaf(in: old.root) else { return nil }
        let start = lineStart(oldText, leaf.range.lowerBound)
        // An element that starts mid-line (an item's paragraph) follows tokens that would absorb
        // whitespace typed at its start.
        guard start == leaf.range.lowerBound || edit.range.lowerBound > leaf.range.lowerBound else { return nil }
        let oldEnd = leaf.range.upperBound
        let newEnd = oldEnd + delta
        let newLength = newText.utf16.count
        guard newEnd > leaf.range.lowerBound, newEnd <= newLength else { return nil }
        // The element must still end at a line end.
        if newEnd < newLength {
            let utf16 = newText.utf16
            guard utf16[utf16.index(utf16.startIndex, offsetBy: newEnd - 1)] == 0x0A else { return nil }
        }
        let oldClasses = classes(slice(oldText, start, oldEnd))
        let newClasses = classes(slice(newText, start, newEnd))
        guard oldClasses.count == newClasses.count,
              zip(oldClasses, newClasses).allSatisfy({ $0.cls == $1.cls && $0.indent == $1.indent }) else { return nil }
        let text = String(slice(newText, leaf.range.lowerBound, newEnd))
        guard let green = Parser.reparseElement(leaf.kind, text: text, settings: old.settings) else { return nil }
        return OrgTree(green: replacing(leaf, with: green), settings: old.settings)
    }

    /// The outermost leaf element containing the edit.
    func leaf(in root: SyntaxNode) -> SyntaxNode? {
        let range = edit.range
        var current = root
        while let child = current.children.first(where: {
            $0.range.lowerBound <= range.lowerBound && range.lowerBound < $0.range.upperBound
                && range.upperBound <= $0.range.upperBound
        }) {
            if Self.leafKinds.contains(child.kind) { return child }
            current = child
        }
        return nil
    }

    /// Copies the path from the root down to `target`, swapping in `green`.
    func replacing(_ target: SyntaxNode, with green: GreenNode) -> GreenNode {
        var node = target
        var replacement = green
        while let parent = node.parent {
            var children = parent.green.children
            let index = children.firstIndex {
                if case .node(let child) = $0 { return child === node.green }
                return false
            }!
            children[index] = .node(replacement)
            replacement = GreenNode(kind: parent.kind, children: children)
            node = parent
        }
        return replacement
    }

    // MARK: - Sections

    /// Reparses from the top-level section before the edit up to the first later top-level
    /// heading that still ends the reparsed run, then reuses the old sections from there.
    /// Top-level sections parse independently: blocks and drawers never cross a heading.
    func reparseSections(_ old: OrgTree) -> OrgTree? {
        let units = old.root.children
        guard !units.isEmpty else { return nil }
        let anchor = max(0, lineStart(oldText, edit.range.lowerBound) - 1)
        guard let startIndex = units.firstIndex(where: { $0.range.contains(anchor) }) else { return nil }
        let start = units[startIndex].range.lowerBound
        var endIndex = units.firstIndex { $0.range.lowerBound > edit.range.upperBound } ?? units.count
        let newLength = newText.utf16.count
        while true {
            let newEnd = endIndex < units.count ? units[endIndex].range.lowerBound + delta : newLength
            var parser = Parser(text: String(slice(newText, start, newEnd)), settings: old.settings)
            let window = parser.run().green
            if endIndex == units.count || endsRun(window, next: units[endIndex].green) {
                let children = units[..<startIndex].map { GreenElement.node($0.green) }
                    + window.children
                    + units[endIndex...].map { GreenElement.node($0.green) }
                return OrgTree(green: GreenNode(kind: .document, children: children), settings: old.settings)
            }
            endIndex += 1
        }
    }

    /// Whether the heading of `next` ends the last section of the reparsed window.
    func endsRun(_ window: GreenNode, next: GreenNode) -> Bool {
        guard case .node(let last)? = window.children.last, last.kind == .section else { return true }
        return headingLevel(next) <= headingLevel(last)
    }

    func headingLevel(_ section: GreenNode) -> Int {
        for case .node(let heading) in section.children where heading.kind == .heading {
            for case .token(let token) in heading.children where token.kind == .stars {
                return token.text.count
            }
        }
        return 0
    }

    // MARK: - Text helpers

    func classes(_ text: Substring) -> [ClassifiedLine] {
        splitRawLines(String(text)).map { classifyLine($0.content) }
    }

    func slice(_ text: String, _ from: Int, _ to: Int) -> Substring {
        text[String.Index(utf16Offset: from, in: text)..<String.Index(utf16Offset: to, in: text)]
    }

    /// UTF-16 offset of the start of the line containing `offset`.
    func lineStart(_ text: String, _ offset: Int) -> Int {
        let utf16 = text.utf16
        var index = utf16.index(utf16.startIndex, offsetBy: offset)
        while index > utf16.startIndex {
            let before = utf16.index(before: index)
            if utf16[before] == 0x0A { break }
            index = before
        }
        return utf16.distance(from: utf16.startIndex, to: index)
    }

    /// UTF-16 offset just past the newline ending the line containing `offset`.
    func lineEnd(_ text: String, _ offset: Int) -> Int {
        let utf16 = text.utf16
        var index = utf16.index(utf16.startIndex, offsetBy: offset)
        while index < utf16.endIndex {
            let current = utf16[index]
            index = utf16.index(after: index)
            if current == 0x0A { break }
        }
        return utf16.distance(from: utf16.startIndex, to: index)
    }
}

extension Parser {
    /// One element of `kind` parsed from exactly `text`, or nil if `text` doesn't parse as a
    /// single element of that kind.
    static func reparseElement(_ kind: SyntaxKind, text: String, settings: OrgSettings) -> GreenNode? {
        var parser = Parser(text: text, settings: settings)
        let count = parser.lines.count
        guard count > 0 else { return nil }
        switch kind {
        case .paragraph:
            parser.paragraph(limit: count, floor: nil)
        case .heading:
            guard count == 1 else { return nil }
            parser.headingLine(parser.lines[0])
            parser.i = 1
        case .tableRow:
            guard count == 1 else { return nil }
            parser.tableRow()
        case .planning, .clock, .keyword, .affiliatedKeyword, .horizontalRule, .nodeProperty:
            guard count == 1 else { return nil }
            parser.single(kind)
        case .block, .comment, .fixedWidth, .footnoteDefinition:
            parser.element(limit: count, floor: nil)
        default:
            return nil
        }
        guard parser.i == count else { return nil }
        let green = parser.builder.build()
        return green.kind == kind ? green : nil
    }
}
