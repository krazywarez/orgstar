import Foundation
import Testing
@testable import OrgCore

/// The hand-written scans for list item counters and description tags against the
/// patterns they replace.
struct ListItemScanTests {
    static let pieces = ["[@", "start:", "3", "12", "b", "B", "]", " ", "\t", "::", ":", "a", "é", "x y", "[", "\\n"]

    static func strings() -> [Substring] {
        var generator = SystemRandomNumberGenerator()
        var out: [Substring] = ["", "[@3]", "[@start:3] x", "[@b]", "[@start:]", "[@start:b]", "[@3", "[@ab]", "a :: b", "a ::", "a::b",
                                "a :: b :: c", "a\t::\tb", " :: x", "::", "a ::b", "tag  ::  rest", "x :: y\nz :: w"]
        for _ in 0..<5000 {
            let count = Int.random(in: 1...7, using: &generator)
            out.append(Substring((0..<count).map { _ in pieces.randomElement(using: &generator)! }.joined().replacingOccurrences(of: "\\n", with: "\n")))
        }
        return out
    }

    @Test func counterMatchesThePattern() {
        for s in Self.strings() {
            let expected = s.prefixMatch(of: /\[@(?:start:)?(?:[0-9]+|[A-Za-z])\]/).map { s[$0.range] }
            #expect(Parser.counter(s) == expected, "\(s.debugDescription)")
        }
    }

    @Test func descriptionTagMatchesThePattern() {
        for s in Self.strings() {
            let m = s.prefixMatch(of: /(.*)([ \t]+::)(?:[ \t]+|$)/.anchorsMatchLineEndings())
            let found = Parser.descriptionTag(s)
            #expect(found?.tag == m.map { s[$0.1.startIndex..<$0.1.endIndex] }, "\(s.debugDescription)")
            #expect(found?.separator == m.map { s[$0.2.startIndex..<$0.2.endIndex] }, "\(s.debugDescription)")
        }
    }
}
