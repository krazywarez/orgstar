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

    /// A cell's borders in the drawing: the lines of its top and bottom rules, and the
    /// columns of its left and right bars.
    struct Rect: Equatable {
        var top: Int, left: Int, right: Int, bottom: Int
    }

    /// The cells' borders in reading order, with the grid rows and columns each spans, or nil
    /// when the drawing isn't a well-formed table.
    static func rects(_ grid: [[Character]]) -> [(rect: Rect, colspan: Int, rowspan: Int)]? {
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
        var found: [(rect: Rect, colspan: Int, rowspan: Int)] = []
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
                found.append((Rect(top: r, left: c, right: x2, bottom: r2), columns.filter { $0 > c && $0 < x2 }.count + 1,
                              rows.filter { $0 > r && $0 < r2 }.count + 1))
            }
        }
        return found.isEmpty ? nil : found
    }

    /// The cells in reading order, or nil when the drawing isn't a well-formed table.
    static func cells(_ text: String) -> [Cell]? {
        let raw = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = raw.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let grid = raw.map { Array($0.dropFirst(indent)) }
        guard let rects = rects(grid) else { return nil }
        return rects.map { found in
            let rect = found.rect
            let lines = (rect.top + 1..<rect.bottom).map { line -> String in
                let row = grid[line]
                let end = min(rect.right, row.count)
                return rect.left + 1 < end ? String(row[(rect.left + 1)..<end]).trimmingCharacters(in: .whitespaces) : ""
            }
            return Cell(row: rect.top, lines: lines, colspan: found.colspan, rowspan: found.rowspan)
        }
    }
}
