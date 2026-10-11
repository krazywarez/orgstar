import Foundation
import Testing
@testable import OrgCore

/// Rows marked `#` recalculated by TAB, S-TAB and RET, and C-u C-u C-c * iterating, against
/// Emacs.
struct TableAutoRecalcTests {
    static let marked = """
        | # | 1 | 2 |   |
        | * | 3 | 4 |   |
        |   | 5 | 6 |   |
        | # | 7 | 8 |   |
        #+TBLFM: $4=$2+$3

        """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func navigationRecalculatesMarkedRows() throws {
        let carets = EmacsOracle.positions(Self.marked).filter { $0 < (Self.marked as NSString).range(of: "#+TBLFM").location }
        try compareWithEmacs([(Self.marked, carets)], [
            (TableCommand(.nextField), "(org-table-next-field)", false),
            (TableCommand(.previousField), "(org-table-previous-field)", false),
            (TableCommand(.nextRow), "(org-table-next-row)", false),
        ])
    }

    /// The table after iterating and the message, or the error.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func iteratingMatchesEmacs() throws {
        let tables = [
            // A chain each pass moves one step along.
            "| 0 |\n| 0 |\n| 0 |\n#+TBLFM: @1$1=@2$1+1::@2$1=@3$1+1::@3$1=1\n",
            "| 1 | 2 |\n#+TBLFM: $2=$1*2\n",
            "| 0 |\n#+TBLFM: @1$1=@1$1+1\n",
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for text in tables {
            cases.append(EmacsOracle.Case(text: text, point: 3, form: """
                (let ((msg "")) (cl-letf (((symbol-function 'message) (lambda (f &rest a) (setq msg (if f (apply #'format f a) "")))))
                  (condition-case e (org-table-iterate) (user-error (setq msg (error-message-string e)))))
                  (goto-char (point-max)) (insert msg))
                """))
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
            switch TableIterate().run(in: context) {
            case .commit(let result):
                let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
                let message = result.effects.compactMap { if case .message(let m) = $0 { m } else { nil } }.last ?? ""
                ours.append(new + message)
            case .failed(let message): ours.append("failed: " + message)
            default: ours.append("other")
            }
        }
        let results = try EmacsOracle.run(cases)
        for (mine, theirs) in zip(ours, results) {
            #expect(mine == theirs.text, "\(theirs.error)")
        }
    }
}
