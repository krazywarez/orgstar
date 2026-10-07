import Foundation
import Testing
@testable import OrgCore

/// table.el tables against ox-html: the rows, each cell's spans and text.
struct TableElTests {
    static let tables = [
        "+-----+-----+\n| a   | b   |\n+-----+-----+\n| c d       |\n| more      |\n+-----+-----+\n| e   | f   |\n+-----+-----+\n",
        "+---+---+\n| a | b |\n|   +---+\n|   | c |\n+---+---+\n",
        "  +----+---+----+\n  | x  | y | z  |\n  +----+---+----+\n  | wide row    |\n  +----+--------+\n  | p  | q & <r>|\n  +----+--------+\n",
        "+---+\n| 1 |\n| 2 |\n+---+\n",
    ]

    static func describe(_ cells: [TableEl.Cell]) -> [String] {
        Dictionary(grouping: cells, by: \.row).keys.sorted().map { row in
            cells.filter { $0.row == row }.map { "\($0.colspan)x\($0.rowspan):" + $0.lines.reversed().drop { $0.isEmpty }.reversed().joined(separator: "/") }.joined(separator: " ")
        }
    }

    /// The rows of ox-html's table, in the same terms.
    static func describe(html: String) -> [String] {
        html.components(separatedBy: "<tr>").dropFirst().map { row in
            row.components(separatedBy: "<td").dropFirst().map { cell -> String in
                let colspan = cell.firstMatch(of: /colspan="([0-9]+)"/).map { String($0.1) } ?? "1"
                let rowspan = cell.firstMatch(of: /rowspan="([0-9]+)"/).map { String($0.1) } ?? "1"
                let body = cell[cell.firstIndex(of: ">")!...].dropFirst().components(separatedBy: "</td>")[0]
                let lines = body.components(separatedBy: "<br />").map {
                    $0.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return "\(colspan)x\(rowspan):" + lines.reversed().drop { $0.isEmpty }.reversed().joined(separator: "/")
            }.joined(separator: " ")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func cellsMatchOxHtml() throws {
        for table in Self.tables {
            let html = try EmacsOracle.evaluate(table, "(progn (require 'ox-html) (list (org-export-as 'html nil nil t)))")[0]
            let ours = try #require(TableEl.cells(table))
            #expect(Self.describe(ours) == Self.describe(html: html), "\(table)\n\(html)")
        }
    }

    @Test func exportsATable() {
        let page = HTMLExport.page(Self.tables[0], fallbackTitle: "t")
        #expect(page.contains("<td colspan=\"2\">c d<br>more</td>"))
        #expect(!page.contains("<pre"))
    }
}
