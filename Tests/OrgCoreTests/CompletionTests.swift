import Foundation
import Testing
@testable import OrgCore

struct CompletionTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    func complete(_ text: String, _ caret: Int? = nil, knownTags: [String] = []) -> Completion? {
        let caret = caret ?? text.utf16.count
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], knownTags: { knownTags })
        return OrgCompletion.at(context)
    }

    static let cases: [(String, Int?)] = [
        ("#+TI", nil), ("#+", nil), ("#+ti", nil), ("#+BEGIN_S", nil),
        ("* T", nil), ("* ", nil), ("* D x", 3),
        ("* H :work:\n* I :", nil), ("* H :work:\n* I :w", nil), ("* H :a:b:\n* I :x:", nil), ("* H :a:b:\n* I :a:", nil),
        ("#+TAGS: work home(h)\n* H :", nil),
        ("* H\n:PROPERTIES:\n:A: 1\n:\n:END:\n", 24), ("* H\n:PROPERTIES:\n:A: 1\n:CU\n:END:\n", 26),
        ("* H\n:PROPERTIES:\n:A: 1\n:END:\n* I\n:PROPERTIES:\n:\n:END:\n", 46),
        ("x \\alp", nil), ("x \\Alp", nil),
        ("* Foo bar\n* TODO [#A] Baz [1/2] :t:\n[[*", nil), ("* Foo bar\n[[*Fo", nil),
        ("#+STARTUP: in", nil), ("#+STARTUP: hidestars s", nil), ("#+OPTIONS: to", nil), ("#+PRIORITIES: ", nil),
        ("#+begin_src py", nil), ("#+begin_src python :ses", nil),
        ("#+BEGIN: clocktable :max", nil),
        ("#+LINK: gh https://github.com/%s\n[[g", nil),
        ("text\n:LO", nil), ("text\n:LOGBOOK:\n- x\n:END:\n:L", nil), ("* H\ntext\n:", nil),
        ("plain text", nil),
    ]

    @Test(.enabled(if: oracle))
    func matchesPcomplete() throws {
        let form = """
            (let ((r (progn (require 'ox) (org-load-export-backends) (pcomplete-completions-at-point))) out)
              (setq out (if (null r) "none"
                          (let* ((beg (nth 0 r))
                                 (all (delete-dups (all-completions (buffer-substring-no-properties beg (point)) (nth 2 r)))))
                            (mapconcat #'identity (cons (number-to-string (1- beg)) (sort all #'string<)) "\\n"))))
              (erase-buffer)
              (insert out))
            """
        let results = try EmacsOracle.run(Self.cases.map { EmacsOracle.Case(text: $0.0, point: ($0.1 ?? $0.0.count) + 1, form: form) })
        for ((text, caret), result) in zip(Self.cases, results) {
            let completion = complete(text, caret)
            let ours = completion.map { c in ([String(c.range.lowerBound)] + c.candidates.sorted()).joined(separator: "\n") } ?? "none"
            let emacs = result.text
            let a = Set(ours.split(separator: "\n")), b = Set(emacs.split(separator: "\n"))
            #expect(ours == emacs, "\(text.debugDescription) @\(caret ?? text.count)\nonly ours:  \(a.subtracting(b).sorted())\nonly emacs: \(b.subtracting(a).sorted()) \(result.error)")
        }
    }

    @Test func addsLinkTypesWorkspaceTagsAndTemplates() {
        #expect(complete("[[ht")?.candidates == ["http:", "https:"])
        #expect(complete("* H :", knownTags: ["home", "work"])?.candidates == ["home:", "work:"])
        #expect(complete("#+TAGS: a\n* H :", knownTags: ["home"])?.candidates == ["a:"])
        let template = complete("  <s")!
        #expect(template.kind == .template && template.range == 0..<4 && template.candidates == ["<s"])
        #expect(template.insertion("<s") == ("#+begin_src \n#+end_src", 12))
        #expect(complete("<q")!.insertion("<q") == ("#+begin_quote\n#+end_quote", 13))
        var options = EditingOptions.org
        options.structureTemplates = StructureTemplate.merged([.init(key: "el", type: "src emacs-lisp")])
        let configured = OrgCompletion.at(EditContext(revision: 0, text: "<e", tree: OrgParser.parse("<e"), selection: [2..<2], options: options))!
        #expect(configured.candidates == ["<e", "<el"] && configured.label("<el") == "<el  src emacs-lisp")
        #expect(configured.insertion("<el") == ("#+begin_src emacs-lisp\n#+end_src", 22))
        #expect(configured.insertion("<L") == ("#+latex: ", 9))
        #expect(complete("<h")!.insertion("<h") == ("#+begin_export html\n#+end_export", 19))
        #expect(complete("<L")!.insertion("<L") == ("#+latex: ", 9))
        #expect(complete("text <s") == nil)
    }
}
