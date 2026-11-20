import Foundation
import Testing
@testable import OrgCore

/// ox-ascii under `emacs -Q`, for whole documents: each case is exported in its own file.
enum ASCIIOracle {
    static let author = "A. Writer"

    struct Case {
        var text: String
        var charset = ASCIIExport.Charset.ascii
        var bodyOnly = false
        /// Emacs point to export the subtree at.
        var subtree: Int?
    }

    /// Each case's `org-export-as 'ascii`, or `ERROR: message`.
    static func export(_ cases: [Case]) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-ascii-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var input: [[String]] = []
        for (index, c) in cases.enumerated() {
            let url = folder.appendingPathComponent("doc\(index).org")
            try c.text.write(to: url, atomically: true, encoding: .utf8)
            input.append([url.path, c.bodyOnly ? "1" : "0", c.subtree.map(String.init) ?? "0", c.charset.rawValue])
        }
        let inputURL = folder.appendingPathComponent("input.json")
        let output = folder.appendingPathComponent("output.json")
        try JSONEncoder().encode(input).write(to: inputURL)
        let script = folder.appendingPathComponent("export.el")
        try #"""
            ;;; -*- lexical-binding: t -*-
            (require 'org)
            (require 'ox-ascii)
            (require 'json)
            (setq user-full-name "A. Writer")
            (let ((results nil))
              (seq-doseq (c (json-read-file (getenv "ORACLE_INPUT")))
                (with-current-buffer (find-file-noselect (aref c 0))
                  (let ((point (string-to-number (aref c 2)))
                        (org-ascii-charset (intern (aref c 3))))
                    (push (condition-case e
                              (progn (when (> point 0) (goto-char point))
                                     (org-export-as 'ascii (> point 0) nil (equal (aref c 1) "1")))
                            (error (concat "ERROR: " (error-message-string e))))
                          results))
                  (kill-buffer)))
              (let ((coding-system-for-write 'utf-8-unix))
                (with-temp-file (getenv "ORACLE_OUTPUT")
                  (insert (json-encode (vconcat (nreverse results)))))))
            """#.write(to: script, atomically: true, encoding: .utf8)
        let log = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["ORACLE_INPUT": inputURL.path, "ORACLE_OUTPUT": output.path, "TZ": "UTC"])
        guard let data = try? Data(contentsOf: output) else { throw EmacsOracle.EvaluateError(log: log) }
        return try JSONDecoder().decode([String].self, from: data)
    }

    /// Ours for the same case, or `ERROR: reason`.
    static func native(_ c: Case) -> String {
        do {
            var text = c.text
            if let point = c.subtree {
                guard let narrowed = ExportScope.subtree(text, at: EmacsOracle.offset(point, in: text)) else { return "ERROR: not in a subtree" }
                text = narrowed
            }
            return try ASCIIExport.document(text, charset: c.charset, bodyOnly: c.bodyOnly, author: author)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}

struct ASCIIExportTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Conformance")
    static let corpus = ["minimal", "core", "headings", "listblocks", "lists", "table", "blocks", "timestamps", "footnote", "images", "tblfm"]

    /// Snippets for what the corpus doesn't show.
    static let snippets: [String] = [
        "No title here.\n",
        "#+TITLE: A /styled/ title\n#+SUBTITLE: and more\n#+AUTHOR: Someone & Co\n#+DATE: <2024-03-01 Fri>\n\nText.\n",
        "#+TITLE: A rather long title that goes on and on until it has to be filled over lines\n#+AUTHOR: Me\nx\n",
        "#+OPTIONS: toc:nil num:nil author:nil date:nil title:nil\n#+TITLE: T\n* One\n** Two\n*** Three\n**** Four\n***** Five\n",
        "#+OPTIONS: toc:2 num:1 H:2\n* One\n** Two\n*** Three\nbody\n*** Four\n* Back\n",
        "#+OPTIONS: H:5\n* One\n** Two\n*** Three\n**** Four\n***** Five\ntext\n",
        "#+OPTIONS: author:nil\n#+DATE: today\nx\n",
        "#+DATE: today\nx\n",
        "#+AUTHOR:\nx\n",
        "Special: \\- -- --- ... a\\\\b\nand *bold*[x] then.\n",
        "Math \\(a+b\\) and $x^2$ and \\alpha \\to \\deg{}C \\copy \\nbsp{}here \\pi.\n",
        "Scripts x^2 y_{i} a_b.\n",
        "#+OPTIONS: ^:{}\nScripts x^2 y_{i} a_b.\n",
        "#+OPTIONS: ^:nil tex:nil\nScripts x^2 y_{i} and \\(a\\) gone.\n",
        "Markup *b* /i/ _u_ +s+ =v= ~c~ and *nested /italic/ bold*.\n",
        "Snippets @@ascii:raw@@ and @@html:<br>@@ gone. Also @@html:x@@ @@html:y@@ end.\n@@html:z@@ start\n",
        "Line one\\\\\nline two \\\\\nafter\n",
        "Links: [[https://orgmode.org][Org & co]] <https://a.b/c_d> https://x.y/z [[mailto:me@x.org]] [[file:doc.pdf][the doc]] [[./rel/file.txt]] [[file:/abs/path.org]]\n",
        "* Target section\nSee [[*Other]].\n* Other\nSee [[*Target section]] and [[Target section][named]] and [[#cid]].\n* Third\n:PROPERTIES:\n:CUSTOM_ID: cid\n:END:\nx\n",
        "#+OPTIONS: num:nil\n* Head\nSee [[*Head]] and [[*Head][desc]].\n",
        "Footnotes[fn:1] twice[fn:1] and[fn:2][fn:3] and inline[fn::anon /x/] and[fn:named:inline def].\n\n[fn:1] First.\n\n[fn:2] Second\n  with two lines.\n\n[fn:3] Third.\n",
        "1. one\n2. [@5] five\n   1. nested\n   2. [@3] three\n3. after\n\n- [X] done\n- [-] half\n- [ ] todo\n\n- term :: def\n- [X] checked term :: def2\n",
        "+ plus bullet\n+ second\n\n* not a heading\n",
        "#+CAPTION: Scores\n#+NAME: tab:scores\n| Name | Score |\n|------+-------|\n| a    |   1.5 |\n| b    |       |\n| c    |  1e3  |\n",
        "| *b* | =v= | [[https://x.y][l]] |\n|-----+-----+-----|\n| 1   | -2  | 3%  |\n| x   |     | 4   |\n|-----+-----+-----|\n",
        "|---+---|\n| a | b |\n|---+---|\n| c | d |\n|---+---|\n",
        "| <l> | <r5> | <c> |\n| a | b | c |\n| long | x | yy |\n",
        "#+NAME: code\n#+CAPTION: A listing\n#+begin_src python -n\nprint(1)\nprint(2)\n#+end_src\n\n#+begin_src emacs-lisp +n 10\n(a)\n#+end_src\n\n#+begin_example -r\nline (ref:x)\n#+end_example\n\n#+begin_src sh\n  indented\n    more\n#+end_src\n",
        "#+begin_src c -n -k\nint x; (ref:decl)\nreturn x;\n#+end_src\n\nSee line [[(decl)]].\n",
        "#+begin_quote\nQ /one/.\n\nQ two.\n#+end_quote\n\n#+begin_center\nC\n#+end_center\n#+begin_verse\n  Roses are red,\n    violets blue\n\nnext stanza\n#+end_verse\n",
        "#+begin_warning\nW *b*.\n#+end_warning\n\n#+begin_export ascii\n  raw\n#+end_export\n#+begin_export html\n<p>no</p>\n#+end_export\n#+begin_comment\nhidden\n#+end_comment\nafter\n",
        "#+begin_JUSTIFYRIGHT\nRight.\n#+end_JUSTIFYRIGHT\n\n#+begin_center\nA table:\n| a | b |\n#+end_center\n",
        "#+ASCII: raw line\n#+TOC: headlines 1\n: fixed\n:   width\n\n-----\n\n#+ATTR_ASCII: :width 10\n-----\n* One\n** Two\n",
        "\\begin{equation}\nx = 1\n\\end{equation}\n",
        "Para one.\n# a comment\nPara two.\n\n# comment\n\nPara three.\n",
        "* TODO [#B] Task :work:urgent_x:\nSCHEDULED: <2024-01-01 Mon>\n:PROPERTIES:\n:X: 1\n:END:\n:LOGBOOK:\n- note\n:END:\n:NOTES:\nDrawer *text*.\n:END:\nbody\n* Archived :ARCHIVE:\nhidden\n** child\n* Kept\n* Drop :noexport:\nx\n* COMMENT Gone\ny\n",
        "#+OPTIONS: pri:t tags:nil todo:nil\n* TODO [#A] Title [1/2] [50%]\n- [X] a\n- [ ] b\n",
        "#+OPTIONS: tags:not-in-toc\n* One :a:\n** Two :b:\n",
        "#+SELECT_TAGS: pick\nPreamble text.\n* A\n* B :pick:\n** B1\n* C\n",
        "Dates <2024-01-15 Mon 9:05> [2024-02-29 Thu 10:00-11:30] <2024-01-15 Mon +1w -2d> <2024-01-15 Mon>--<2024-01-17 Wed> end.\n",
        "#+MACRO: greet Hello, $1!\n{{{greet(World)}}} and {{{title}}}.\n",
        "#+begin_src emacs-lisp :exports code\n(+ 1 2)\n#+end_src\n\n#+RESULTS:\n: 3\n\nafter\n",
        "  Indented paragraph\n  second line\n    deeper\n\n- item first line\n  continued\n    more\n",
        "* Low levels\n** two\n*** three\n**** four a\n**** four b\nbody\n***** five\n* next\n",
        "#+EXCLUDE_TAGS: secret\n* A\n** B :secret:\n** C\n",
        "#+OPTIONS: -:nil\nNo special... strings -- \\- here.\n",
        "- a\n\n- b\n  para two\n\n  para three\n- c\n  - d\n\n  - e\nafter list\n",
        "#+LANGUAGE: de\n* Teil\nText[fn:1] and [[https://x.y][link]].\n\n[fn:1] Note.\n",
        "#+LANGUAGE: fr\n#+TOC: headlines\n* Un\n",
        "A long paragraph that has to be filled because it runs on for well over the seventy-two columns of a line. Sentences end. Here.\n",
        "* Heading with [[https://a.b][a link]] in it\nAnd [[https://c.d][another]] and [[https://a.b][a link]] again.\n** Sub\n[[https://e.f][third]]\n",
        "#+TITLE: Title with [[https://a.b][link]]\nx\n",
        "* A\n#+FOO: bar\n\n* B\n",
        "#+TITLE: T\n\n* H\nx\n",
        "| a |\n| 1 |\n",
        "#+begin_example\n#+end_example\n\n#+begin_src sh\n#+end_src\n\nafter\n",
    ]

    static let extra: [String] = [
        "#+OPTIONS: H:2 toc:3\n* A :x:\n** B\n*** C\n**** D\n***** E\n****** F\n* G\n",
        "#+OPTIONS: num:2\n* A\n** B\n*** C\n**** D\n",
        "* A\nText.[fn:1]\n** B\nMore.[fn:2]\n\n[fn:1] A note under A that is long enough to be filled at a width shorter than seventy-two.\n\n[fn:2] Short.\n\n\nNot part of the note.\n",
        "Refs[fn:1].\n\n[fn:1] A note in the preamble that is long enough to be filled at the full width of seventy-two.\n",
        "Inline[fn:: an inline note that is long enough to be filled at the full width of seventy-two columns wide].\n",
        "| a[fn:1] | b |\n\n- item[fn:2]\n\n[fn:1] One.\n\n[fn:2] Two.\n",
        "* Heading\nSee [[https://a.b][A]] here.\n** Child\nx\n",
        "* Heading [[https://a.b][A]]\n** Child\nx\n",
        "- item [[https://a.b][A]]\n  - nested [[https://c.d][C]]\n\n| [[https://e.f][E]] |\n",
        "Same [[https://a.b][A]] and [[https://a.b][A]] and [[https://a.b][B]] and [[https://a.b]].\n",
        "#+begin_src sh -n -r\necho a (ref:one)\necho b\n#+end_src\nLine [[(one)]] and [[(one)][here]].\n",
        "#+begin_center\n- one\n- two\n\n#+begin_quote\nq\n#+end_quote\n#+end_center\n",
        "#+begin_quote\n- a list in a quote that runs on long enough to need filling inside the narrower width\n-----\n#+end_quote\n",
        "- term :: definition\n  - nested :: inner definition that is long enough to be filled at the narrower width\n",
        "1. a\n2. b\n3. c\n4. d\n5. e\n6. f\n7. g\n8. h\n9. i\n10. j that is long enough to be filled at a width shorter by the wider bullet here\n",
        "1. [X] done and long enough to wrap because the checkbox narrows the width of the item text\n2) other\n",
        "| <c> |\n| a |\n| long cell |\n\n| <6> | <l3> |\n| a | b |\n",
        "| 1 | x |\n|   | y |\n| 3 | z |\n",
        "#+begin_verse\n  /Roses/ are *red*,\n  violets \\alpha blue\n#+end_verse\n",
        "Entities \\eacute \\copy \\laquo \\nbsp \\mdash \\hellip \\Aring \\sup2 \\frac12 \\times.\n",
        "* TODO [#A] A task with a title long enough to push the tags past the edge :tag:other:\n",
        "* A\n:PROPERTIES:\n:CUSTOM_ID: a\n:END:\n* B\nSee [[#a][the A]] and [[#a]].\n",
        "#+OPTIONS: num:nil toc:nil\n* A\n* B\nSee [[*A]] and [[*A][x]].\n",
        "#+TITLE: T\n#+SUBTITLE: The subtitle is longer than the title\n#+AUTHOR: An author with a long name\n#+DATE: 2024\nx\n",
        "#+TITLE: Ünïcödé — title\n#+AUTHOR: Ëm\nx\n",
        "#+begin_example\n  a\n    b\n#+end_example\n\n#+begin_example -i\n  a\n#+end_example\n",
        ": a\n:   b\n: c\n",
        "Text\n\n#+begin_src emacs-lisp :exports none\n(x)\n#+end_src\n\nafter\n",
        "* A\n** B :noexport:\n*** C\n** D\n",
        "* COMMENT A\n* B\n",
        "x\n\n* Footnotes\n[fn:1] in section\n* After\ny[fn:1]\n",
        "A sentence ends here.  Another one follows. And a third e.g. this one continues on for a while to wrap the line.\n",
        "Word\nbroken\n  across\n    lines\n",
        "*bold that is long enough* /italic that goes on/ _underline_ +strike+ =verbatim text= ~code text~ and more words to wrap the line around.\n",
        "#+begin_center\nA centered paragraph that is long enough to be filled over more than one line of the text width.\n#+end_center\n",
        "#+begin_JUSTIFYRIGHT\n| a | b |\n#+end_JUSTIFYRIGHT\n",
        "#+begin_JUSTIFYLEFT\nleft\n#+end_JUSTIFYLEFT\n",
        "#+ATTR_ASCII: :width 20\n-----\n",
        "* A\n#+TOC: headlines 2\n** B\n** C\n",
    ]

    static var cases: [(String, ASCIIOracle.Case)] {
        var cases: [(String, ASCIIOracle.Case)] = []
        for charset in ASCIIExport.Charset.allCases {
            for name in corpus {
                let text = (try? String(contentsOf: folder.appendingPathComponent("\(name).org"), encoding: .utf8)) ?? ""
                cases.append(("\(name) \(charset.rawValue)", ASCIIOracle.Case(text: text, charset: charset)))
            }
            for (index, snippet) in (snippets + extra).enumerated() {
                cases.append(("snippet \(index) \(charset.rawValue)", ASCIIOracle.Case(text: snippet, charset: charset)))
            }
        }
        return cases
    }

    @Test(.enabled(if: oracle))
    func matchesEmacs() throws {
        let all = Self.cases
        try compare(all.map(\.1), names: all.map(\.0))
    }

    @Test(.enabled(if: oracle))
    func bodyOnlyAndSubtreesMatchEmacs() throws {
        let doc = "#+TITLE: Doc\n#+OPTIONS: toc:nil\nIntro.\n* One\nFirst.\n** Sub\n:PROPERTIES:\n:EXPORT_TITLE: Exported title\n:END:\nSub body *b*.\n*** Deeper\nx\n* Two\nSecond.\n"
        let sub = (doc as NSString).range(of: "** Sub").location
        let one = (doc as NSString).range(of: "First.").location
        var cases: [ASCIIOracle.Case] = []
        var names: [String] = []
        for charset in ASCIIExport.Charset.allCases {
            cases += [
                ASCIIOracle.Case(text: doc, charset: charset, bodyOnly: true),
                ASCIIOracle.Case(text: try String(contentsOf: Self.folder.appendingPathComponent("blocks.org"), encoding: .utf8), charset: charset, bodyOnly: true),
                ASCIIOracle.Case(text: doc, charset: charset, subtree: EmacsOracle.point(sub, in: doc)),
                ASCIIOracle.Case(text: doc, charset: charset, subtree: EmacsOracle.point(one, in: doc)),
                ASCIIOracle.Case(text: doc, charset: charset, bodyOnly: true, subtree: EmacsOracle.point(sub, in: doc)),
            ]
            names += ["body", "blocks body", "subtree", "subtree from body", "subtree body"].map { "\($0) \(charset.rawValue)" }
        }
        try compare(cases, names: names)
    }

    private func compare(_ cases: [ASCIIOracle.Case], names: [String]) throws {
        let emacs = try ASCIIOracle.export(cases)
        for (index, c) in cases.enumerated() {
            let ours = ASCIIOracle.native(c)
            if ours.hasPrefix("ERROR: ") {
                Issue.record("\(names[index]) unsupported: \(ours)\n--- org\n\(c.text)")
                continue
            }
            if let dump = ProcessInfo.processInfo.environment["ASCII_DUMP"], ours != emacs[index] {
                let name = names[index].replacingOccurrences(of: " ", with: "_")
                try? ours.write(toFile: dump + "/" + name + ".ours", atomically: true, encoding: .utf8)
                try? emacs[index].write(toFile: dump + "/" + name + ".emacs", atomically: true, encoding: .utf8)
                try? c.text.write(toFile: dump + "/" + name + ".org", atomically: true, encoding: .utf8)
            }
            #expect(ours == emacs[index], "\(names[index])\n--- org\n\(c.text)\n--- ours\n\(ours)\n--- emacs\n\(emacs[index])")
        }
    }
}
