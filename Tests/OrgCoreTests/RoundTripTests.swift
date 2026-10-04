import Foundation
import Testing
@testable import OrgCore

/// SplitMix64, so failures reproduce from the seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let fragments = [
    "* ", "** TODO [#A] title :a:b:", "*** DONE", "#+TODO: NEXT | DONE", "#+begin_src sh", "#+end_src",
    "#+BEGIN_QUOTE", "#+end_quote", "#+BEGIN: clocktable", "#+END:", ":PROPERTIES:", ":ID: x", ":END:",
    ":LOGBOOK:", "CLOCK: [2026-10-04 Sun 10:00]", "SCHEDULED: <2026-10-04 Sun>", "- item", "  - nested",
    "\t+ tab", "1. one", "| a | b |", "|---+---|", "#+TBLFM: $2=$1", "# comment", ": fixed", "-----",
    "[fn:1] note", "#+NAME: x", "plain text", "é", "😀", "e\u{301}", " ", "\t", "\n", "\n", "\r\n", "\r", "",
    "*bold*", "/it/ ", "=v=", "~c~", "_u_", "+s+", "*", "/", "=", "[[https://a.b][d *b*]]", "[[x]]", "[[", "]]",
    "<2026-10-04 Sun 10:00 +1w -2d>", "[2026-10-04]--[2026-10-05]", "<", ">", "[fn:2]", "[fn::in [x]]", "[1/3]",
    "[50%]", "<<t>>", "{{{m(a)}}}", "\\(x\\)", "a\\\\", "x^2", "^{y}", "src_sh{echo}", "https://e.com.",
    "<https://e.com>", "| *a* | b |", "||", "- [X] done", "+ [ ] todo", "-",
]

func randomDocument(_ rng: inout SeededGenerator) -> String {
    (0..<Int.random(in: 0...40, using: &rng)).map { _ in
        fragments.randomElement(using: &rng)! + (Bool.random(using: &rng) ? "\n" : "")
    }.joined()
}

func checkLengths(_ node: SyntaxNode) -> Bool {
    let sum = node.green.children.reduce(0) { $0 + $1.length }
    return sum == node.green.length && node.children.allSatisfy(checkLengths)
}

struct RoundTripTests {
    @Test func fuzzedDocumentsRoundTrip() {
        var rng = SeededGenerator(state: 20261004)
        for n in 0..<2_000 {
            let text = randomDocument(&rng)
            let tree = OrgParser.parse(text)
            #expect(tree.text == text, "document \(n)")
            #expect(checkLengths(tree.root), "document \(n)")
        }
    }

    @Test(arguments: [
        [0xEF, 0xBB, 0xBF] + Array("* a\r\n".utf8),
        Array("* a\r\n- b\n\tc".utf8),
        Array("* a".utf8),
        Array("😀 e\u{301}\n".utf8),
        [0x2A, 0x20, 0xFF, 0x0A] as [UInt8],
    ])
    func encodingFixturesRoundTrip(bytes: [UInt8]) {
        let source = SourceText(bytes: bytes)
        let tree = OrgParser.parse(source.text)
        #expect(source.encode(tree.text) == bytes)
    }

    /// Private corpus: `ORGSTAR_CORPUS=/path/to/org swift test --filter corpus`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_CORPUS"] != nil))
    func corpusRoundTrips() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { ["org", "org_archive"].contains($0.pathExtension) }
        #expect(!files.isEmpty)
        for file in files {
            let bytes = try [UInt8](Data(contentsOf: file))
            let source = SourceText(bytes: bytes)
            let tree = OrgParser.parse(source.text)
            #expect(source.encode(tree.text) == bytes, "\(file.path)")
        }
    }
}
