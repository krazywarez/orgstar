import Foundation
import Testing
import OrgCore
@testable import OrgPresentation

struct SpellCheckTests {
    /// The words left for the spell checker.
    func checked(_ text: String) -> [String] {
        let skipped = SpellCheck.skipped(OrgParser.parse(text))
        let ns = text as NSString
        var words: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
            if !skipped.contains(where: { $0.contains(range.location) }) { words.append(word!) }
        }
        return words
    }

    @Test func skipsMarkupAndCode() {
        let text = """
            #+TITLE: Speling
            * TODO [#A] Headng wurd :tagg:
            SCHEDULED: <2026-10-06 Tue>
            :PROPERTIES:
            :ID: abcxyz
            :END:
            Prose ~codez~ =verbz= [[https://x.org][desc]] <2026-01-01> wurds.
            - [ ] itemm
            #+begin_src sh
            ecko
            #+end_src
            #+begin_quote
            quotd
            #+end_quote
            : fixd
            $x^2$ \\alpha
            """ + "\n"
        #expect(checked(text) == ["Headng", "wurd", "Prose", "wurds", "itemm", "quotd"])
    }
}
