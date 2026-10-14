import Foundation
import Testing
@testable import OrgCore

struct EmphasizeTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    func run(_ text: String, _ selection: Range<Int>, _ marker: String) -> (text: String, caret: Int, failure: String?) {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [selection], answers: ["emphasis": marker])
        switch Emphasize().run(in: context) {
        case .commit(let result):
            var new = text
            for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
            return (new, result.selection?.first?.lowerBound ?? selection.lowerBound, nil)
        case .failed(let message): return (text, selection.lowerBound, message)
        default: return (text, selection.lowerBound, "unexpected")
        }
    }

    @Test(.enabled(if: oracle))
    func emphasizesLikeOrg() throws {
        let cases: [(String, Range<Int>)] = [
            ("Hello world\n", 6..<11), ("Hello world\n", 5..<5), ("Hello world\n", 6..<6), ("Hello world\n", 0..<0),
            ("Hello *world* again\n", 6..<13), ("Hello world\n", 0..<5), ("say (it) now\n", 5..<7), ("abc", 3..<3),
            ("one-two\n", 4..<7), ("a**b\n", 1..<3),
        ]
        let markers = ["*", "/", "_", "=", "~", "+", " ", "q"]
        var oracleCases: [EmacsOracle.Case] = []
        var ours: [(text: String, caret: Int, failure: String?)] = []
        for (text, selection) in cases {
            for marker in markers {
                let char = marker == " " ? "?\\s" : "?\(marker)"
                let form = selection.isEmpty
                    ? "(org-emphasize \(char))"
                    : "(let ((transient-mark-mode t)) (push-mark \(selection.lowerBound + 1) t t) (org-emphasize \(char)))"
                oracleCases.append(EmacsOracle.Case(text: text, point: selection.upperBound + 1, form: form))
                ours.append(run(text, selection, marker))
            }
        }
        for (i, theirs) in try EmacsOracle.run(oracleCases).enumerated() {
            let label = "\(oracleCases[i].form) on \(oracleCases[i].text.debugDescription)"
            #expect((ours[i].failure != nil) == !theirs.error.isEmpty, "\(label): \(ours[i].failure ?? "") vs \(theirs.error)")
            guard theirs.error.isEmpty else { continue }
            #expect(ours[i].text == theirs.text, "\(label)")
            #expect(ours[i].caret == theirs.point - 1, "\(label): caret")
        }
    }

    @Test func asksForTheMarker() {
        let text = "word\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [0..<4])
        guard case .prompt(let prompt) = Emphasize().run(in: context) else { Issue.record("no prompt"); return }
        #expect(prompt.key == "emphasis")
        #expect(prompt.fast?.items.count == 7)
    }

    @Test func fixedMarkers() {
        let text = "word\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [0..<4])
        guard case .commit(let result) = Emphasize(marker: "*").run(in: context) else { Issue.record("no edit"); return }
        #expect(result.edits.first.map { $0.apply(to: text) } == "*word*\n")
        #expect(Emphasize(marker: "*").id == "org.emphasize.bold")
        #expect(Emphasize(marker: "/").id == "org.emphasize.italic")
        #expect(Emphasize(marker: "_").id == "org.emphasize.underline")
        #expect(Emphasize(marker: "~").id == "org.emphasize.code")
    }
}
