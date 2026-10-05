import Foundation
import Testing
@testable import OrgCore

/// Reparses `text` after an edit, checks the result against a full parse, and returns the
/// strategy used.
@discardableResult
func checkReparse(_ text: String, _ range: Range<Int>, _ replacement: String) -> ReparseStrategy {
    let old = OrgParser.parse(text)
    let edit = TextEdit(range: range, replacement: replacement)
    let result = OrgParser.reparseWithStrategy(old, oldText: text, edit: edit)
    let expected = OrgParser.parse(edit.apply(to: text))
    #expect(result.tree.text == expected.text)
    #expect(result.tree.green == expected.green)
    return result.strategy
}

/// UTF-16 offsets of every unicode scalar boundary.
func scalarOffsets(_ text: String) -> [Int] {
    var offsets = [0]
    var offset = 0
    for scalar in text.unicodeScalars {
        offset += scalar.utf16.count
        offsets.append(offset)
    }
    return offsets
}

struct IncrementalTests {
    @Test func applyKeepsCRLFHalves() {
        #expect(TextEdit(range: 1..<1, replacement: "x").apply(to: "\r\n") == "\rx\n")
        #expect(TextEdit(range: 1..<3, replacement: "").apply(to: "a😀b") == "ab")
    }

    @Test func typingInAParagraphReparsesOneElement() {
        #expect(checkReparse("* a\nhello world\n* b\n", 10..<10, "big ") == .element)
        #expect(checkReparse("- item *one*\n  - two\n", 8..<8, "x") == .element)
    }

    @Test func typingAtTheStartOfAnItemParagraph() {
        #expect(checkReparse(" >\n1. one", 6..<6, " ") != .element)
    }

    @Test func changingATodoKeywordReparsesOneElement() {
        #expect(checkReparse("* TODO a\nbody\n", 2..<6, "DONE") == .element)
    }

    @Test func newHeadingReparsesSections() {
        #expect(checkReparse("* a\nx\ny\n* b\n", 6..<6, "* c\n") == .sections)
    }

    @Test func joiningParagraphsReparsesARegion() {
        #expect(checkReparse("a\n\nb\n", 1..<2, "") == .region)
        #expect(checkReparse("* h\nfirst\nsecond\n\nthird\n** child\n", 15..<15, "\n\n") == .region)
    }

    @Test func regionGrowsUntilABoundaryHolds() {
        // Splitting a paragraph next to a table and a list.
        #expect(checkReparse("* h\nx\ntext\nmore\n| a |\n- i\n", 9..<9, "\n") == .region)
        // A new begin line without its end runs to the end of the body.
        #expect(checkReparse("* h\nx\none\ntwo\n#+end_src\nthree\n", 6..<6, "\n#+begin_src") == .region)
    }

    @Test func regionDefersToSectionsNearHeadings() {
        // The first body line could become a planning line.
        #expect(checkReparse("* h\nbody\n", 4..<4, "\n") != .region)
        // An added end delimiter could close a block that starts before the window.
        #expect(checkReparse("x\n#+begin_src\na\n\nb\n", 16..<16, "#+end_src\n") != .region)
    }

    @Test func runGrowsUntilAHeadingEndsIt() {
        #expect(checkReparse("** a\n** b\n* c\n", 0..<0, "* x\n") == .sections)
    }

    @Test func settingsLineForcesFullParse() {
        #expect(checkReparse("#+TODO: A | B\n* A x\n", 8..<9, "C") == .full)
    }

    @Test func exposingAKeywordInsideABlockForcesFullParse() {
        let text = "#+begin_example\n#+TODO: X\n#+end_example\n* X a\n"
        #expect(checkReparse(text, 26..<40, "") == .full)
    }

    @Test func editsAtTheEdges() {
        checkReparse("", 0..<0, "* a\n")
        checkReparse("* a\n", 0..<4, "")
        checkReparse("* a", 3..<3, "\n")
        checkReparse("a\r\nb\r\n", 1..<1, "x")
    }

    /// Set `ORGSTAR_FUZZ_EDITS` to run more (the phase 1 gate is 100,000 in a release build) and
    /// `ORGSTAR_FUZZ_SEED` to try another sequence.
    @Test func incrementalEqualsFull() {
        let environment = ProcessInfo.processInfo.environment
        var rng = SeededGenerator(state: UInt64(environment["ORGSTAR_FUZZ_SEED"] ?? "") ?? 20261005)
        let count = Int(environment["ORGSTAR_FUZZ_EDITS"] ?? "") ?? 3_000
        let small = ["a", " ", "*", "/", "=", "[", "]", "<", ">", "-", ":", "|", "#", "+", "\n", "\r\n", "😀", "é"]
        for n in 0..<count {
            let text = randomDocument(&rng)
            let offsets = scalarOffsets(text)
            let a = offsets.randomElement(using: &rng)!
            let later = offsets.filter { $0 >= a && $0 <= a + 12 }
            let b = Bool.random(using: &rng) ? a : later.randomElement(using: &rng)!
            let replacement: String
            if Int.random(in: 0..<10, using: &rng) < 7 {
                replacement = (0..<Int.random(in: 0...2, using: &rng)).map { _ in small.randomElement(using: &rng)! }.joined()
            } else {
                replacement = fragments.randomElement(using: &rng)! + (Bool.random(using: &rng) ? "\n" : "")
            }
            let old = OrgParser.parse(text)
            let edit = TextEdit(range: a..<b, replacement: replacement)
            let tree = OrgParser.reparse(old, oldText: text, edit: edit)
            let expected = OrgParser.parse(edit.apply(to: text))
            #expect(tree.green == expected.green, "edit \(n): \(a)..<\(b) \(replacement.debugDescription) in \(text.debugDescription)")
        }
    }
}
