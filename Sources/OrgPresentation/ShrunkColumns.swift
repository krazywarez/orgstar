import Foundation
import OrgCore

/// Narrowed table columns (`org-table-shrink`), as the Mac and iOS editors keep them: by table
/// start, each column's segments. Recomputed as the text changes; typing into one widens its
/// column again, as editing org's overlays deletes them, while commands' edits keep columns
/// narrow, as `org-table-align` shrinks them again.
public struct ShrunkColumns: Sendable, Equatable {
    public private(set) var tables: [Int: [Int: [TableShrink.Segment]]] = [:]

    public init() {}

    public var isEmpty: Bool { tables.isEmpty }

    /// Every shrunk field's segments.
    public var segments: [TableShrink.Segment] { tables.values.flatMap { $0.values.joined() } }

    /// The shrunk columns of the table starting at `table`.
    public func columns(in table: Range<Int>) -> [Int] {
        tables[table.lowerBound].map { Array($0.keys).sorted() } ?? []
    }

    /// Narrows `columns` of `table` and widens its others.
    public mutating func set(_ columns: [Int], in table: Range<Int>, text: String) {
        let segments = Dictionary(uniqueKeysWithValues: columns.map { ($0, TableShrink.segments(table, column: $0, in: text)) })
        tables[table.lowerBound] = segments.isEmpty ? nil : segments
    }

    /// `#+STARTUP: shrink`: every table's columns with width cookies start narrow.
    public static func startup(_ tree: OrgTree) -> ShrunkColumns {
        var result = ShrunkColumns()
        guard Presentation.startupOptions(tree).contains(where: { $0.lowercased() == "shrink" }) else { return result }
        let text = tree.text
        let ns = text as NSString
        var offset = 0
        while offset < ns.length {
            let line = ns.lineRange(for: NSRange(location: offset, length: 0))
            defer { offset = max(NSMaxRange(line), offset + 1) }
            guard ns.substring(with: line).range(of: "^[ \\t]*\\|", options: .regularExpression) != nil,
                  let table = TableShrink.table(at: line.location, in: text) else { continue }
            let columns = TableShrink.cookieColumns(table, in: text)
            if !columns.isEmpty { result.set(columns, in: table, text: text) }
            offset = table.upperBound
        }
        return result
    }

    /// Moves the columns through `edit`, `text` being the text after it; columns the edit
    /// touched widen unless `command` made it. Returns the tables to restyle.
    public mutating func map(through edit: TextEdit, in text: String, command: Bool) -> [Range<Int>] {
        guard !tables.isEmpty else { return [] }
        let delta = edit.replacement.utf16.count - edit.range.count
        func touches(_ segment: TableShrink.Segment) -> Bool {
            segment.range.lowerBound <= edit.range.upperBound && edit.range.lowerBound <= segment.range.upperBound
        }
        var mapped: [Int: [Int: [TableShrink.Segment]]] = [:]
        var restyle: [Range<Int>] = []
        for (start, columns) in tables {
            let kept = columns.filter { _, segments in command || !segments.contains(where: touches) }.keys
            let touched = columns.values.joined().contains(where: touches)
            let newStart = start < edit.range.lowerBound ? start : start >= edit.range.upperBound ? start + delta : edit.range.lowerBound
            guard let table = TableShrink.table(at: min(newStart, max(0, text.utf16.count - 1)), in: text) else { continue }
            if touched || kept.count != columns.count { restyle.append(table) }
            guard !kept.isEmpty else { continue }
            mapped[table.lowerBound] = Dictionary(uniqueKeysWithValues: kept.map { ($0, TableShrink.segments(table, column: $0, in: text)) })
        }
        tables = mapped
        return restyle
    }

    /// What a column width command does at `caret`.
    public enum Change: Equatable, Sendable {
        case notInTable
        /// Shrink these columns of the table, expanding the others.
        case set([Int], table: Range<Int>)
        /// Ask for column ranges, then toggle them (`toggled`).
        case ask(table: Range<Int>, current: [Int], max: Int)
    }

    /// `org-table-toggle-column-width` (`org.table.toggle-column-width`), `org-table-shrink`
    /// (`org.table.shrink`) and `org-table-expand` (`org.table.expand`) at `caret`.
    public func change(for id: String, at caret: Int, in text: String) -> Change {
        guard let table = TableShrink.table(at: caret, in: text) else { return .notInTable }
        let current = columns(in: table)
        switch id {
        case "org.table.shrink": return .set(TableShrink.cookieColumns(table, in: text), table: table)
        case "org.table.expand": return .set([], table: table)
        default:
            if let column = TableShrink.column(at: caret, in: text) {
                return .set(Self.toggled(current, [column]), table: table)
            }
            let line = (text as NSString).lineRange(for: NSRange(location: caret, length: 0))
            return .ask(table: table, current: current, max: line.length / 2)
        }
    }

    /// `current` with `columns` toggled.
    public static func toggled(_ current: [Int], _ columns: [Int]) -> [Int] {
        Set(current).symmetricDifference(columns).sorted()
    }
}
