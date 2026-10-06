import Foundation
import Testing
@testable import OrgCore

struct SparseTreeTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil
    static let seconds = 1_789_000_000

    static let text = """
        Preamble text
        * TODO Alpha :work:
        alpha body with foo
        ** DONE Beta
        beta body
        ** TODO Gamma :home:
        DEADLINE: <2026-09-15 Tue>
        gamma Foo
        *** Delta
        SCHEDULED: <2026-09-01 Tue>
        delta
        **** Deep
        deep text
        * Epsilon :ARCHIVE:
        ** Zeta foo
        * DONE Eta
        DEADLINE: <2026-08-01 Sat>
        * Theta
        SCHEDULED: <2026-10-01 Thu 10:00>
        theta

        * TODO Iota
        DEADLINE: <2026-11-30 Mon>
        """ + "\n"

    @Test(.enabled(if: oracle))
    func buildsSparseTreesLikeOrg() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: Double(Self.seconds))
        let tree = OrgParser.parse(Self.text)
        let cases: [(String, SparseTree.Matches)] = [
            ("(org-occur \"foo\")", try SparseTree.occur("foo", in: Self.text)),
            ("(org-occur \"^\\\\*+ .*a$\")", try SparseTree.occur("^\\*+ .*a$", in: Self.text)),
            ("(org-show-todo-tree nil)", SparseTree.todo(nil, in: Self.text, settings: tree.settings)),
            ("(org-match-sparse-tree nil \"home|work\")", SparseTree.match("home|work", in: Self.text, now: now, calendar: utc)),
            ("(org-match-sparse-tree nil \"LEVEL>2\")", SparseTree.match("LEVEL>2", in: Self.text, now: now, calendar: utc)),
            ("(org-check-deadlines nil)", SparseTree.deadlines(within: 14, in: Self.text, settings: tree.settings, now: now, calendar: utc)),
            ("(org-check-before-date \"2026-09-20\")", SparseTree.planning(from: nil, to: "2026-09-20", in: Self.text, calendar: utc)),
            ("(org-check-after-date \"2026-09-20\")", SparseTree.planning(from: "2026-09-20", to: nil, in: Self.text, calendar: utc)),
            ("(org-check-dates-range \"2026-09-01\" \"2026-10-01 10:00\")", SparseTree.planning(from: "2026-09-01", to: "2026-10-01 10:00", in: Self.text, calendar: utc)),
        ]
        let forms = cases.map { form, _ in
            frozenClock(Self.seconds, """
                (with-current-buffer (find-file-noselect "oracle.org")
                  (org-fold-show-all) \(form)
                  (list (mapconcat (lambda (o) (format "%d-%d" (1- (overlay-start o)) (1- (overlay-end o))))
                                   (sort (copy-sequence org-occur-highlights) (lambda (a b) (< (overlay-start a) (overlay-start b)))) " ")
                        (let (vis) (goto-char (point-min))
                          (while (not (eobp)) (push (if (if (eolp) (and (not (bobp)) (org-invisible-p (1- (point)))) (org-invisible-p (point))) "0" "1") vis) (forward-line 1))
                          (apply #'concat (nreverse vis)))))
                """)
        }
        let emacs = try EmacsOracle.evaluate(Self.text, "(apply (function append) (list \(forms.joined(separator: " "))))", prelude: "(setenv \"TZ\" \"UTC0\")")
        for (i, (form, matches)) in cases.enumerated() {
            let hidden = SparseTree.hidden(matches.points, in: Self.text, tree: tree)
            let ns = Self.text as NSString
            var visibility = ""
            var offset = 0
            while offset < ns.length {
                visibility += hidden.contains { $0.contains(offset) } ? "0" : "1"
                offset = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
            }
            let highlights = matches.highlights.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: " ")
            #expect(highlights == emacs[2 * i], "\(form) highlights")
            #expect(visibility == emacs[2 * i + 1], "\(form) visibility")
        }
    }
}
