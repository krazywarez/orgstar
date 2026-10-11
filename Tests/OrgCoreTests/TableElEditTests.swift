import Foundation
import Testing
@testable import OrgCore

struct TableElEditTests {
    static let simple = """
        * Notes
          +-----+-----+
          | a   | b   |
          |     | b2  |
          +-----+-----+
          | c   | d   |
          +-----+-----+

        """

    static let merged = """
        +-----+-----+-----+
        | a   | b         |
        +-----+-----+-----+
        | c   | d   | e   |
        |     +-----+-----+
        |     | f   | g   |
        +-----+-----+-----+

        """

    /// Carets inside cells: every character after a bar on a row line, before the next bar.
    static func cellCarets(_ text: String) -> [Int] {
        var carets: [Int] = []
        let ns = text as NSString
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let chars = Array(line)
            var inside = false
            var utf16 = offset
            for ch in chars {
                if ch == "|" || ch == "+" { inside = line.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
                else if inside, ch != "-" { carets.append(utf16) }
                utf16 += String(ch).utf16.count
            }
            offset += (line as NSString).length + 1
            if offset > ns.length { break }
        }
        return carets
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func movingMatchesTableEl() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, caret: Int?)] = []
        for text in [Self.simple, Self.merged] {
            for caret in Self.cellCarets(text) {
                for forward in [true, false] {
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
                        (progn (require 'table) (table-recognize-table) (\(forward ? "table-forward-cell" : "table-backward-cell") 1))
                        """))
                    let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
                    var mine: Int?
                    if case .commit(let result) = TableElMoveCell(forward: forward).run(in: context), result.edits.isEmpty { mine = result.selection?.first?.lowerBound }
                    ours.append(("\(forward ? "forward" : "backward") from \(caret)", mine))
                }
            }
        }
        let results = try EmacsOracle.run(cases)
        var mismatches = 0
        for ((label, mine), theirs) in zip(ours, results) {
            let theirCaret = theirs.text.unicodeScalars.prefix(theirs.point - 1).reduce(0) { $0 + $1.utf16.count }
            if mine != theirCaret || !theirs.error.isEmpty {
                mismatches += 1
                if mismatches <= 10 { Issue.record("\(label): ours \(mine.map(String.init) ?? "none") emacs \(theirCaret) \(theirs.error)") }
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(cases.count) differ")
    }

    @Test func aligningAfterTyping() {
        let typed = "  +-----+-----+\n  | abcXY | d   |\n  +-----+-----+\n  | e| f   |\n  +-----+-----+\n"
        let caret = (typed as NSString).range(of: "XY").location + 2
        let context = EditContext(revision: 0, text: typed, tree: OrgParser.parse(typed), selection: [caret..<caret])
        guard case .commit(let result) = TableElAlign().run(in: context) else { Issue.record("not aligned"); return }
        let new = result.edits.reduce(typed) { $1.apply(to: $0) }
        #expect(new == "  +------+-----+\n  | abcXY| d   |\n  +------+-----+\n  | e    | f   |\n  +------+-----+\n")
        // The caret stays after the typed text.
        #expect(result.selection?.first?.lowerBound == (new as NSString).range(of: "XY").location + 2)
        // TAB lines the borders up first, then goes on to the next cell.
        guard case .commit(let tab) = TableElMoveCell(forward: true).run(in: context) else { Issue.record("no move"); return }
        let tabbed = tab.edits.reduce(typed) { $1.apply(to: $0) }
        #expect(tabbed == new)
        #expect(tab.selection?.first?.lowerBound == (new as NSString).range(of: " d").location)
    }

    @Test func mergedCellsArentAligned() {
        let caret = (Self.merged as NSString).range(of: "d").location
        let context = EditContext(revision: 0, text: Self.merged, tree: OrgParser.parse(Self.merged), selection: [caret..<caret])
        #expect(TableElAlign().run(in: context) == .failed("Can't align a table.el table with merged cells"))
        #expect(KeyContext.holds("table-el", in: context))
    }
}
