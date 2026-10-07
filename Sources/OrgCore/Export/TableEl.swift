import Foundation

/// A table.el table's cells, read from its drawing: each cell's text lines and the grid rows
/// and columns it spans, as `table-generate-source` finds them.
enum TableEl {
    struct Cell: Equatable {
        var row: Int
        var lines: [String]
        var colspan: Int
        var rowspan: Int
    }

    /// The cells in reading order, or nil when the drawing isn't a well-formed table.
    static func cells(_ text: String) -> [Cell]? {
        let raw = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = raw.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let grid = raw.map { Array($0.dropFirst(indent)) }
        guard grid.count >= 3 else { return nil }
        func at(_ r: Int, _ c: Int) -> Character? { r >= 0 && r < grid.count && c >= 0 && c < grid[r].count ? grid[r][c] : nil }
        func vertical(_ r: Int, _ c: Int) -> Bool { at(r, c) == "|" || at(r, c) == "+" }
        func horizontal(_ r: Int, _ c: Int) -> Bool { at(r, c) == "-" || at(r, c) == "+" }
        // Grid lines: rows holding a horizontal border, columns holding a corner.
        var rows: [Int] = []
        var columns: Set<Int> = []
        for (r, line) in grid.enumerated() {
            for (c, ch) in line.enumerated() where ch == "+" {
                columns.insert(c)
                if horizontal(r, c + 1) || horizontal(r, c - 1) { if rows.last != r { rows.append(r) } }
            }
        }
        var cells: [Cell] = []
        for r in rows {
            for c in grid[r].indices where grid[r][c] == "+" && at(r, c + 1) == "-" && vertical(r + 1, c) {
                // Right edge: the next corner along the top with a border below it.
                var x2 = c + 1
                while x2 < grid[r].count, !(grid[r][x2] == "+" && vertical(r + 1, x2)) { x2 += 1 }
                guard x2 < grid[r].count else { return nil }
                // Bottom edge: the next corner down the left side with a border to its right.
                var r2 = r + 1
                while r2 < grid.count, !(at(r2, c) == "+" && horizontal(r2, c + 1)) { r2 += 1 }
                guard r2 < grid.count, r2 > r + 1 else { return nil }
                let lines = (r + 1..<r2).map { line -> String in
                    let row = grid[line]
                    let end = min(x2, row.count)
                    return c + 1 < end ? String(row[(c + 1)..<end]).trimmingCharacters(in: .whitespaces) : ""
                }
                cells.append(Cell(row: r, lines: lines, colspan: columns.filter { $0 > c && $0 < x2 }.count + 1,
                                  rowspan: rows.filter { $0 > r && $0 < r2 }.count + 1))
            }
        }
        return cells.isEmpty ? nil : cells
    }
}
