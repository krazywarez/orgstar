import Foundation
import Testing
@testable import OrgCore

/// Key sequences through `isearch-forward` and `isearch-backward`, against Emacs: where point
/// ends up after RET.
struct ISearchTests {
    static let text = "foo bar foo baz foo\nFoo  bar\tbaz\nend of foobar text\n"

    static let sequences: [(origin: Int, keys: [String])] = [
        (4, ["C-s", "f", "o", "o", "RET"]),
        (11, ["C-r", "f", "o", "o", "RET"]),
        (0, ["C-s", "b", "a", "C-s", "C-s", "RET"]),
        (0, ["C-s", "b", "a", "C-s", "C-s", "C-s", "C-s", "C-s", "C-s", "RET"]),
        (0, ["C-s", "b", "a", "z", "z", "C-g", "RET"]),
        (0, ["C-s", "b", "a", "z", "z", "DEL", "DEL", "RET"]),
        (0, ["C-s", "F", "o", "o", "RET"]),
        (0, ["C-s", "f", "o", "o", "SPC", "b", "RET"]),
        (0, ["C-s", "b", "a", "r", "SPC", "b", "RET"]),
        (30, ["C-r", "b", "a", "C-r", "RET"]),
        (30, ["C-r", "b", "a", "C-s", "RET"]),
        (0, ["C-s", "o", "C-s", "C-r", "RET"]),
        (0, ["C-s", "f", "o", "o", "b", "RET"]),
        (50, ["C-r", "f", "o", "o", "b", "a", "r", "RET"]),
        (50, ["C-r", "z", "z", "C-r", "RET"]),
        (5, ["C-s", "q", "C-s", "RET"]),
        (0, ["C-s", "e", "n", "d", "DEL", "DEL", "o", "RET"]),
    ]

    static func ours(_ origin: Int, _ keys: [String]) -> Int {
        var search: ISearch?
        for key in keys {
            switch key {
            case "C-s", "C-r":
                if search == nil { search = ISearch(origin: origin, forward: key == "C-s") } else { search!.again(forward: key == "C-s", in: text) }
            case "DEL": search?.delete()
            case "C-g": if search?.abort() == false { return origin }
            case "RET": return search?.point ?? origin
            case "SPC": search?.add(" ", in: text)
            default: search?.add(key, in: text)
            }
        }
        return search?.point ?? origin
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func searchingMatchesEmacs() throws {
        var cases: [EmacsOracle.Case] = []
        for (origin, keys) in Self.sequences {
            let macro = keys.joined(separator: " ")
            // isearch reads keys in the selected window's buffer, which stays current for the
            // oracle to read point from.
            cases.append(EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(origin, in: Self.text), form: """
                (let ((text (buffer-string)) (p (point)))
                  (switch-to-buffer (get-buffer-create "isearch"))
                  (erase-buffer) (insert text) (goto-char p)
                  (execute-kbd-macro (kbd \(macro.debugDescription))))
                """))
        }
        let results = try EmacsOracle.run(cases)
        for (index, (sequence, theirs)) in zip(Self.sequences, results).enumerated() {
            let theirPoint = Self.text.unicodeScalars.prefix(theirs.point - 1).reduce(0) { $0 + $1.utf16.count }
            #expect(Self.ours(sequence.origin, sequence.keys) == theirPoint, "case \(index): \(sequence.keys.joined(separator: " ")) \(theirs.error)")
        }
    }

    @Test func messages() {
        var search = ISearch(origin: 0, forward: true)
        search.add("b", in: Self.text)
        #expect(search.message == "I-search: b")
        search.add("q", in: Self.text)
        #expect(search.message == "Failing I-search: bq")
        var back = ISearch(origin: 10, forward: false)
        back.add("z", in: Self.text)
        #expect(back.message == "Failing I-search backward: z")
    }
}
