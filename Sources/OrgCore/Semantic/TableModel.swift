import Foundation

public struct TableModel: Sendable, Equatable {
    public enum Row: Sendable, Equatable {
        case rule
        /// Cell text with surrounding blanks trimmed.
        case cells([String])
    }

    public let range: Range<Int>
    public let heading: Int?
    public let rows: [Row]
    /// `#+TBLFM:` values in order.
    public let formulas: [String]
    /// Widest cell per column, in display columns.
    public let columnWidths: [Int]

    public var columnCount: Int { columnWidths.count }

    init(node: SyntaxNode, heading: Int?) {
        range = node.range
        self.heading = heading
        rows = node.children.filter { $0.kind == .tableRow }.map { row in
            let cells = row.children.filter { $0.kind == .tableCell }
            if cells.isEmpty, row.text.trimmingCharacters(in: .whitespaces).hasPrefix("|-") { return .rule }
            return .cells(cells.map { $0.text.trimmingCharacters(in: .whitespaces) })
        }
        formulas = node.children.filter { $0.kind == .tableFormula }.map {
            SettingsScanner.keywordValue($0.text.trimmingCharacters(in: .whitespacesAndNewlines)[...])
                .trimmingCharacters(in: .whitespaces)
        }
        var widths: [Int] = []
        for case .cells(let cells) in rows {
            for (column, cell) in cells.enumerated() {
                if column == widths.count { widths.append(0) }
                widths[column] = max(widths[column], displayWidth(cell))
            }
        }
        columnWidths = widths
    }
}
