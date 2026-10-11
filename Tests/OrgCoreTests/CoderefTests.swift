import Foundation
import Testing
@testable import OrgCore

struct CoderefTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        * Code
        #+begin_src python -n
        def f():          (ref:def)
            return 1      (ref:ret)
        #+end_src

        #+begin_src python +n 10 -r
        x = f()           (ref:call)
        print(x)
        #+end_src

        #+begin_example -n -r -k
        first
        second (ref:kept)
        #+end_example

        #+begin_src sh -l "<<%s>>"
        echo hi <<echo>>
        #+end_src

        See [[(def)]], [[(call)][line %s]], [[(kept)]] and [[(echo)]].

        """

    @Test(.enabled(if: oracle))
    func resolvesLikeOrgExport() throws {
        let tree = OrgParser.parse(Self.text)
        let refs = ["def", "ret", "call", "kept", "echo"]
        let form = "(require 'ox) (let ((info (list :parse-tree (org-element-parse-buffer)))) (mapcar (lambda (r) (format \"%s\" (org-export-resolve-coderef r info))) '(\(refs.map { "\"\($0)\"" }.joined(separator: " ")))))"
        let emacs = try EmacsOracle.evaluate(Self.text, "(progn \(form))")
        #expect(refs.map { Coderef.resolve($0, in: tree) ?? "" } == emacs)
    }

    @Test(.enabled(if: oracle))
    func followsLikeOrgLinkSearch() throws {
        let tree = OrgParser.parse(Self.text)
        let refs = ["def", "ret", "call", "kept", "echo"]
        let form = "(mapcar (lambda (r) (goto-char (point-min)) (org-link-search (format \"(%s)\" r)) (number-to-string (1- (point)))) '(\(refs.map { "\"\($0)\"" }.joined(separator: " "))))"
        let emacs = try EmacsOracle.evaluate(Self.text, form)
        let ours = refs.map { ref -> String in
            if case .found(let offset) = Links.search("(\(ref))", text: Self.text, tree: tree) { return String(offset) }
            return "none"
        }
        #expect(ours == emacs.map { String(EmacsOracle.offset(Int($0)! + 1, in: Self.text)) })
        #expect(Links.search("(missing)", text: Self.text, tree: tree) == .failed("No match for coderef: missing"))
        #expect(Links.search("/ret.*1/", text: Self.text, tree: tree) == .occur("ret.*1"))
    }

    @Test func exportsLabelsAndNumbers() {
        let html = HTMLExport.body(Self.text)
        #expect(html.contains("<span id=\"coderef-def\" class=\"coderef-off\"><span class=\"linenr\">1: </span>def f(): (def)</span>"), "\(html)")
        #expect(html.contains("<span class=\"linenr\">13: </span>print(x)"))
        #expect(html.contains("<a href=\"#coderef-def\" class=\"coderef\">def</a>"))
        #expect(html.contains("<a href=\"#coderef-call\" class=\"coderef\">line 12</a>"))
        #expect(html.contains("<a href=\"#coderef-kept\" class=\"coderef\">2</a>"))
        #expect(html.contains("echo hi (echo)"))
        let markdown = MarkdownExport.document(Self.text)
        #expect(markdown.contains("12  x = f()\n13  print(x)"), "\(markdown)")
        #expect(markdown.contains("See def, line 12, 2 and echo."))
    }

    @Test func splitsHighlightedLines() {
        #expect(HTMLRenderer.splitLines("<span class=\"s\">a\nb</span> c") == ["<span class=\"s\">a</span>", "<span class=\"s\">b</span> c"])
    }
}
