import Foundation
import Testing
@testable import OrgCore

/// Keys typed with `electric-pair-mode` in an Org buffer, against Emacs.
struct ElectricPairTests {
    struct Typing {
        let text: String
        let point: Int
        var mark: Int?
        let keys: [String]
    }

    static let cases: [Typing] = [
        Typing(text: "", point: 0, keys: ["("]),
        Typing(text: "foo", point: 3, keys: ["(", "x", ")"]),
        Typing(text: ")", point: 0, keys: ["("]),
        Typing(text: "(", point: 1, keys: [")"]),
        Typing(text: "", point: 0, keys: ["\"", "a", "\""]),
        Typing(text: "a \"b", point: 4, keys: ["\""]),
        Typing(text: "(foo )", point: 4, keys: [")"]),
        Typing(text: "x", point: 1, keys: ["<", ">"]),
        Typing(text: "", point: 0, keys: ["[", "[", "a", "]", "]"]),
        Typing(text: "{}", point: 1, keys: ["}"]),
        Typing(text: "(())", point: 2, keys: [")", ")"]),
        Typing(text: "[(])", point: 2, keys: [")"]),
        Typing(text: "()", point: 1, keys: ["DEL"]),
        Typing(text: "(x)", point: 2, keys: ["DEL"]),
        Typing(text: "\"\"", point: 1, keys: ["DEL"]),
        Typing(text: "()", point: 1, keys: ["RET"]),
        Typing(text: "word", point: 4, mark: 0, keys: ["("]),
        Typing(text: "word", point: 4, mark: 0, keys: [")"]),
        Typing(text: "word", point: 4, mark: 0, keys: ["\""]),
        Typing(text: "say ", point: 4, keys: ["“", "hi", "”"]),
        Typing(text: "\"a b\"", point: 2, keys: ["("]),
        Typing(text: "\"a b\"", point: 2, keys: ["<"]),
        Typing(text: "* Heading\nit", point: 12, keys: ["'", "s"]),
        Typing(text: "a (b", point: 4, keys: [")"]),
        Typing(text: "a b)", point: 2, keys: ["("]),
        Typing(text: "(a\n )", point: 2, keys: [")"]),
        Typing(text: "word", point: 0, keys: ["\""]),
        Typing(text: "say \"x\" and ", point: 12, keys: ["\"", "y", "\""]),
        Typing(text: "- item (see [[x]]", point: 17, keys: [")"]),
        Typing(text: "<2026-10-06 Tue>", point: 16, keys: ["DEL"]),
        Typing(text: "f(\"(\")", point: 4, keys: [")"]),
    ]

    /// The keys typed into our side: `ElectricPairKey` where it applies, otherwise as the
    /// text view types them.
    static func ours(_ c: Typing) -> (text: String, point: Int) {
        var text = c.text
        var selection = (c.mark ?? c.point)..<c.point
        if let mark = c.mark, mark > c.point { selection = c.point..<mark }
        var options = EditingOptions.org
        options.electricPair = true
        let units = c.keys.flatMap { key in key == "DEL" || key == "RET" ? [key] : key.map { String($0) } }
        for key in units {
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [selection], options: options)
            let command = ElectricPairKey(key: key)
            if command.applies(in: context), case .commit(let result) = command.run(in: context) {
                for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { text = edit.apply(to: text) }
                selection = result.selection!.first!
                continue
            }
            let ns = text as NSString
            let caret = selection.upperBound
            switch key {
            case "DEL":
                text = ns.replacingCharacters(in: NSRange(location: caret - 1, length: 1), with: "")
                selection = caret - 1..<caret - 1
            default:
                let typed = key == "RET" ? "\n" : key
                text = ns.replacingCharacters(in: NSRange(location: selection.lowerBound, length: selection.count), with: typed)
                selection = selection.lowerBound + 1..<selection.lowerBound + 1
            }
        }
        return (text, selection.upperBound)
    }

    @Test func typesLikeEmacs() throws {
        let cases = Self.cases.map { c in
            let keys = c.keys.map { key in
                key == "DEL" || key == "RET" ? "(execute-kbd-macro (kbd \"\(key)\"))"
                    : key.map { "(execute-kbd-macro \(lispString(String($0))))" }.joined(separator: " ")
            }.joined(separator: " ")
            let region = c.mark.map { "(set-mark \(EmacsOracle.point($0, in: c.text))) (activate-mark)" } ?? ""
            return EmacsOracle.Case(text: c.text, point: EmacsOracle.point(c.point, in: c.text), form: """
                (progn (switch-to-buffer (current-buffer)) (electric-pair-local-mode 1) (transient-mark-mode 1) \(region) \(keys))
                """)
        }
        for (c, theirs) in zip(Self.cases, try EmacsOracle.run(cases)) {
            let ours = Self.ours(c)
            #expect(ours.text == theirs.text && EmacsOracle.point(ours.point, in: ours.text) == theirs.point,
                    "\(c.text.debugDescription) at \(c.point) keys \(c.keys)\nours:  \(ours.text.debugDescription) \(ours.point)\nemacs: \(theirs.text.debugDescription) \(theirs.point) \(theirs.error)")
        }
    }
}
