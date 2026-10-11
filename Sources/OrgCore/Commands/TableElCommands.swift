import Foundation

// Editing table.el tables (`+---+` borders) in place: moving between cells as
// `table-forward-cell` does, and lining the borders up again after typing, which table.el
// does as each character goes in. Org itself edits them only in table.el's buffer (C-c ').

/// A table.el table in the text: its lines, without their common indentation.
struct TableElDrawing {
    /// Where each line starts in the text, and the lines.
    let starts: [Int]
    let lines: [[Character]]
    let indent: String

    init?(_ context: EditContext) {
        var node = context.tree.root
        var table: SyntaxNode?
        while let child = node.child(containing: context.caret) {
            if child.kind == .tableEl { table = child }
            node = child
        }
        guard let table else { return nil }
        let ns = context.text as NSString
        var starts: [Int] = []
        var raw: [String] = []
        var at = table.range.lowerBound
        while at < table.range.upperBound {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            let text = ns.substring(with: line).trimmingCharacters(in: .newlines)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { break }
            starts.append(line.location)
            raw.append(text)
            at = NSMaxRange(line)
        }
        let indent = raw.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        self.starts = starts
        self.lines = raw.map { Array($0.dropFirst(indent)) }
        self.indent = String(raw.first?.prefix(indent) ?? "")
    }

    /// The line and character column of a text offset, the column past the indentation.
    func position(_ offset: Int, in text: String) -> (line: Int, column: Int)? {
        guard let line = starts.lastIndex(where: { $0 <= offset }) else { return nil }
        let ns = text as NSString
        let before = ns.substring(with: NSRange(location: starts[line], length: offset - starts[line]))
        return (line, before.count - indent.count)
    }

    /// The text offset of a line and column.
    func offset(line: Int, column: Int) -> Int {
        let prefix = indent + String(lines[line].prefix(max(0, column)))
        return starts[line] + (prefix as NSString).length
    }
}

extension TableEl {
    /// `table-forward-cell`: the cell after the one holding the caret, or before it, wrapping
    /// around; the caret at its first character. Nil when the drawing has no cells.
    static func move(_ drawing: TableElDrawing, from position: (line: Int, column: Int), forward: Bool) -> (line: Int, column: Int)? {
        guard let rects = rects(drawing.lines)?.map(\.rect), !rects.isEmpty else { return nil }
        let ordered = rects.sorted { ($0.top, $0.left) < ($1.top, $1.left) }
        let current = ordered.firstIndex { $0.top < position.line && position.line < $0.bottom && $0.left < position.column && position.column <= $0.right }
        let next: Rect
        if let current {
            next = ordered[(current + (forward ? 1 : ordered.count - 1)) % ordered.count]
        } else {
            // On a border: the first cell after the caret, or the last before it.
            let after = ordered.first { ($0.top + 1, $0.left + 1) > (position.line, position.column) }
            let before = ordered.last { ($0.top + 1, $0.left + 1) < (position.line, position.column) }
            next = (forward ? after ?? ordered.first : before ?? ordered.last)!
        }
        return (next.top + 1, next.left + 1)
    }

    /// The drawing with its borders lined up: each column as wide as its widest cell, and no
    /// narrower than its rules. Nil for tables with merged cells, or lines that aren't rules
    /// or rows of the same number of cells.
    static func aligned(_ lines: [[Character]]) -> [[Character]]? {
        let strings = lines.map { String($0) }
        let rules = strings.map { $0.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\+(?:-+\+)+/) != nil }
        let columns = strings.enumerated().compactMap { rules[$0.offset] ? $0.element.trimmingCharacters(in: .whitespaces).filter { $0 == "+" }.count - 1 : nil }
        guard let count = columns.first, columns.allSatisfy({ $0 == count }) else { return nil }
        var cells: [[String]?] = []
        var widths = [Int](repeating: 0, count: count)
        for (index, line) in strings.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if rules[index] {
                let segments = trimmed.dropFirst().dropLast().split(separator: "+", omittingEmptySubsequences: false)
                for (j, segment) in segments.enumerated() { widths[j] = max(widths[j], segment.count) }
                cells.append(nil)
                continue
            }
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count >= 2 else { return nil }
            let parts = trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == count else { return nil }
            // Text typed into a cell takes up its trailing spaces first.
            let content = parts.map { $0.replacing(/[ \t]+$/, with: "") }
            for (j, cell) in content.enumerated() { widths[j] = max(widths[j], cell.count) }
            cells.append(content)
        }
        return cells.map { row in
            guard let row else { return Array("+" + widths.map { String(repeating: "-", count: $0) }.joined(separator: "+") + "+") }
            return Array("|" + zip(row, widths).map { $0 + String(repeating: " ", count: $1 - $0.count) }.joined(separator: "|") + "|")
        }
    }
}

/// The table's text and caret after lining up its borders: the caret stays in its cell, at the
/// same place in the cell's text. Nil when the table can't be aligned.
private func alignedTable(_ drawing: TableElDrawing, _ context: EditContext) -> (edit: TextEdit, caretLine: Int, caretColumn: Int)? {
    guard let lines = TableEl.aligned(drawing.lines) else { return nil }
    let position = drawing.position(context.caret, in: context.text) ?? (0, 0)
    // The caret's cell is the number of bars before it on its line; its place in the cell
    // the characters after the last bar.
    let line = drawing.lines[position.line]
    let before = line.prefix(max(0, position.column))
    let bars = before.filter { $0 == "|" || $0 == "+" }.count
    let inCell = before.count - ((before.lastIndex { $0 == "|" || $0 == "+" }).map { $0 + 1 } ?? 0)
    var column = 0
    var seen = 0
    for (index, ch) in lines[position.line].enumerated() where ch == "|" || ch == "+" {
        seen += 1
        if seen == bars { column = index + 1; break }
    }
    let ns = context.text as NSString
    let start = drawing.starts.first!
    let lastLine = ns.lineRange(for: NSRange(location: drawing.starts.last!, length: 0))
    let end = NSMaxRange(lastLine) - (ns.substring(with: lastLine).hasSuffix("\n") ? 1 : 0)
    let text = lines.map { drawing.indent + String($0) }.joined(separator: "\n")
    let cellWidth = (lines[position.line].dropFirst(column).firstIndex { $0 == "|" || $0 == "+" } ?? lines[position.line].count) - column
    return (TextEdit(range: start..<end, replacement: text), position.line, column + min(inCell, max(0, cellWidth)))
}

/// TAB and S-TAB in a table.el table: the borders lined up, then the next or previous cell
/// (`table-forward-cell`, `table-backward-cell`).
public struct TableElMoveCell: OrgCommand {
    public let forward: Bool
    public init(forward: Bool) { self.forward = forward }
    public var id: String { forward ? "org.table-el.next-cell" : "org.table-el.previous-cell" }
    public var title: String { forward ? "Next table.el Cell" : "Previous table.el Cell" }
    public func applies(in context: EditContext) -> Bool { TableElDrawing(context) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard var drawing = TableElDrawing(context) else { return .failed("Not in a table.el table") }
        var edits: [TextEdit] = []
        var position = drawing.position(context.caret, in: context.text) ?? (0, 0)
        var text = context.text
        if let aligned = alignedTable(drawing, context), aligned.edit.replacement != (text as NSString).substring(with: NSRange(aligned.edit.range)) {
            edits = [aligned.edit]
            text = aligned.edit.apply(to: text)
            position = (aligned.caretLine, aligned.caretColumn)
            let tree = OrgParser.parse(text, defaults: context.tree.settings)
            let caret = drawing.offset(line: 0, column: 0)
            guard let again = TableElDrawing(EditContext(revision: context.revision, text: text, tree: tree, selection: [caret..<caret])) else { return .failed("Not in a table.el table") }
            drawing = again
        }
        guard let target = TableEl.move(drawing, from: position, forward: forward) else { return .failed("Not a table.el table with cells") }
        let caret = drawing.offset(line: target.line, column: target.column)
        return .commit(EditResult(baseRevision: context.revision, edits: edits, selection: [caret..<caret]))
    }
}

/// C-c C-c in a table.el table: the borders lined up again.
public struct TableElAlign: OrgCommand {
    public init() {}
    public var id: String { "org.table-el.align" }
    public var title: String { "Align table.el Table" }
    public func applies(in context: EditContext) -> Bool { TableElDrawing(context) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard let drawing = TableElDrawing(context) else { return .failed("Not in a table.el table") }
        guard let aligned = alignedTable(drawing, context) else { return .failed("Can't align a table.el table with merged cells") }
        let text = aligned.edit.apply(to: context.text)
        let tree = OrgParser.parse(text, defaults: context.tree.settings)
        let first = drawing.starts.first!
        guard let again = TableElDrawing(EditContext(revision: context.revision, text: text, tree: tree, selection: [first..<first])) else {
            return .failed("Not in a table.el table")
        }
        let caret = again.offset(line: aligned.caretLine, column: aligned.caretColumn)
        return .commit(EditResult(baseRevision: context.revision, edits: [aligned.edit], selection: [caret..<caret]))
    }
}
