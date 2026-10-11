import Foundation
import Testing
@testable import OrgCore

/// Typing a space with `auto-fill-mode` on, against Emacs's `self-insert-command`.
struct AutoFillTests {
    static let texts = [
        "one two three four five six",
        "* Heading\nSome words that run well past the fill column here",
        "- an item with several words that need wrapping",
        "  1. numbered item text that is long enough to wrap twice over",
        "# a comment line that goes on and on past the column",
        "#+begin_quote\nquoted text that is long enough to need a break\n#+end_quote",
        "#+begin_src sh\necho one two three four five six seven eight\n#+end_src",
        "| a table row with words that never wraps at all |",
        "* A heading that is long enough to pass the fill column",
        "short",
        "averyveryveryverylongwordwithoutanyspaces then",
        "text with a [[https://example.com/a/long/link][link description]] in it",
        "- [ ] a checkbox item whose words run past the column",
        "  indented paragraph words that keep going past fill",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func typingASpaceMatchesEmacs() throws {
        var options = EditingOptions.org
        options.fillColumn = 20
        options.autoFill = true
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int)] = []
        for text in Self.texts {
            // At the end of each line, and in the middle of the last one.
            let ns = text as NSString
            var carets: [Int] = []
            var at = 0
            while at <= ns.length {
                let line = ns.lineRange(for: NSRange(location: min(at, max(0, ns.length - 1)), length: 0))
                let end = NSMaxRange(line) - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0)
                carets.append(end)
                if NSMaxRange(line) >= ns.length { break }
                at = NSMaxRange(line)
            }
            carets.append(max(0, ns.length - 6))
            for caret in Set(carets).sorted() {
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
                    (progn (setq fill-column 20) (auto-fill-mode 1) (let ((last-command-event ?\\s)) (self-insert-command 1)))
                    """))
                let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], options: options)
                guard case .commit(let result) = AutoFillSpace().run(in: context) else {
                    ours.append(("at \(caret) in \(text.debugDescription)", "failed", caret))
                    continue
                }
                let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
                ours.append(("at \(caret) in \(text.debugDescription)", new, result.selection?.first?.lowerBound ?? -1))
            }
        }
        let results = try EmacsOracle.run(cases)
        var mismatches = 0
        for (mine, theirs) in zip(ours, results) {
            let theirCaret = theirs.text.unicodeScalars.prefix(theirs.point - 1).reduce(0) { $0 + $1.utf16.count }
            if mine.text != theirs.text || mine.caret != theirCaret {
                mismatches += 1
                if mismatches <= 12 { Issue.record("\(mine.label)\n ours:  \(mine.text.debugDescription) @\(mine.caret)\n emacs: \(theirs.text.debugDescription) @\(theirCaret) \(theirs.error)") }
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(cases.count) differ")
    }
}
