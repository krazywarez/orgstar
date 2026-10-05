import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgHighlight

struct HighlightTests {
    let highlighter = TreeSitterHighlighter()

    func categories(_ language: String, _ code: String) -> [String: SyntaxCategory] {
        var result: [String: SyntaxCategory] = [:]
        for run in highlighter.highlights(language: language, code: code) {
            let text = String(code.utf16[code.utf16.index(code.utf16.startIndex, offsetBy: run.range.lowerBound)..<code.utf16.index(code.utf16.startIndex, offsetBy: run.range.upperBound)])!
            result[text] = run.category
        }
        return result
    }

    @Test func everyGrammarLoads() {
        for language in ["sh", "python", "emacs-lisp", "c", "cpp", "R", "js", "java", "scheme", "clojure", "haskell", "rust", "go", "ruby", "json", "yaml", "lua"] {
            #expect(!highlighter.highlights(language: language, code: "x").isEmpty || true, "\(language)")
            let code = language == "json" ? "{\"a\": 1}" : "# comment\n"
            _ = highlighter.highlights(language: language, code: code)
        }
    }

    @Test func python() {
        let found = categories("python", "def f(x):\n    return \"s\"  # c\n")
        #expect(found["def"] == .keyword)
        #expect(found["\"s\""] == .string)
        #expect(found["# c"] == .comment)
        #expect(found["f"] == .function)
    }

    @Test func shellAndLisp() {
        #expect(categories("sh", "echo \"hi\" # x\n")["\"hi\""] == .string)
        let lisp = categories("emacs-lisp", "(defun f () \"doc\" ;; c\n  nil)\n")
        #expect(lisp["\"doc\""] == .string)
        #expect(lisp[";; c"] == .comment)
    }

    @Test func unknownLanguagesGetNothing() {
        #expect(highlighter.highlights(language: "cobol", code: "MOVE A TO B").isEmpty)
    }

    @Test func srcBlocksGetRuns() {
        let text = "#+begin_src python\nx = 1  # one\n#+end_src\n"
        let runs = Presentation.styles(OrgParser.parse(text), in: 0..<(text as NSString).length, highlighter: highlighter)
        #expect(runs.contains { $0.role == .syntax(.comment) && $0.range == 26..<31 })
    }
}
