import Foundation
import Testing
@testable import OrgCore

struct TableShrinkTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    @Test(.enabled(if: oracle))
    func placesOverlaysLikeOrg() throws {
        let tables = [
            "| <5>   | <r3> | x      | <c6>     |\n|--------+------+--------+----------|\n| abcdefghij | ab | long text | mid |\n|  | abcd | y | abcdefghi |\n|   lead |    z |        |        q |\n",
            "| a | b |\n|---+---|\n| hello world | 1 |\n",
        ]
        for text in tables {
            let table = try #require(TableShrink.table(at: 2, in: text))
            let columns = TableShrink.cookieColumns(table, in: text)
            var ours: [String] = []
            for c in columns.isEmpty ? [1, 2] : columns {
                ours += TableShrink.segments(table, column: c, in: text).map { "\($0.range.lowerBound + 1) \($0.range.upperBound + 1) \($0.display)" }
            }
            let shrink = columns.isEmpty ? "(org-table--shrink-columns '(1 2) (org-table-begin) (org-table-end))" : "(org-table-shrink)"
            let emacs = try EmacsOracle.evaluate(text, """
                (with-current-buffer (find-file-noselect "oracle.org") (goto-char 3) \(shrink)
                  (mapcar (lambda (o) (format "%d %d %s" (overlay-start o) (overlay-end o) (substring-no-properties (overlay-get o 'display))))
                          (sort (seq-filter (lambda (o) (eq (overlay-get o 'org-overlay-type) 'table-column-hide)) (overlays-in (point-min) (point-max)))
                                (lambda (a b) (< (overlay-start a) (overlay-start b))))))
                """)
            #expect(emacs.count > 4)
            #expect(ours.sorted { Int($0.split(separator: " ")[0])! < Int($1.split(separator: " ")[0])! } == emacs)
        }
        #expect(TableShrink.columns("2-4 6- 1", max: 7) == [1, 2, 3, 4, 6, 7])
    }
}
