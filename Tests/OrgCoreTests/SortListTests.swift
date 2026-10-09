import Foundation
import Testing
@testable import OrgCore

/// C-c ^ on an item: `org-sort-list`.
struct SortListTests {
    static let lists = [
        "- pear\n- Apple\n- banana\n  - sub b\n  - sub a\n- cherry\n",
        "* H\n  - 10 ten\n  - 9 nine\n  - [[https://x.org][2 two]]\n  - 1.5 one and a half\n",
        "1. zeta\n2. alpha\n3. mu\n\nAfter.\n",
        "- [ ] open\n- [X] done\n- [-] partial\n- no box\n",
        "- meet <2026-10-09 Fri>\n- call [2026-10-05 Mon]\n- none\n- plan <2026-10-07 Wed 10:00>\n",
        "- b\n\n- a\n\n\n- c\n",
        "Intro\n- one\n- two\n  continued\n- three\nOutro\n",
    ]

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, caret: Int, failure: String?)] = []
        for text in Self.lists {
            let ns = text as NSString
            var carets: [Int] = []
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                let content = ns.substring(with: line)
                if !content.hasPrefix("*"), content.range(of: "^[ \\t]*([-+*]|[0-9]+\\.) ", options: .regularExpression) != nil {
                    carets.append(line.location + content.prefix { $0 == " " || $0 == "\t" }.utf16.count + 1)
                }
                location = NSMaxRange(line)
            }
            for caret in carets.prefix(2) {
                for key in ["a", "A", "n", "N", "t", "T", "x", "X"] {
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: "(org-sort-list nil ?\(key))"))
                    // In UTC, as the oracle runs Emacs: an item without a time sorts as now.
                    ours.append(runCommand(SortEntries(), text, caret: caret, answers: ["sort": key], calendar: Self.utc))
                }
            }
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text && mine.failure == (theirs.error.isEmpty ? nil : theirs.error),
                    "\(cases[i].form) at \(cases[i].point) in\n\(cases[i].text)\nours:\n\(mine.text) \(mine.failure ?? "")\nemacs:\n\(theirs.text) \(theirs.error)")
        }
    }
}
