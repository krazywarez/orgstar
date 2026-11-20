import Foundation
import Testing
@testable import OrgCore

/// ox-latex under `emacs -Q`, for whole documents: each case is exported in its own file.
enum LaTeXOracle {
    static let author = "A. Writer"

    struct Case {
        var text: String
        var bodyOnly = false
        /// Emacs point to export the subtree at.
        var subtree: Int?
    }

    /// Each case's `org-export-as 'latex`, or `ERROR: message`.
    static func export(_ cases: [Case]) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-latex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var input: [[String]] = []
        for (index, c) in cases.enumerated() {
            let url = folder.appendingPathComponent("doc\(index).org")
            try c.text.write(to: url, atomically: true, encoding: .utf8)
            input.append([url.path, c.bodyOnly ? "1" : "0", c.subtree.map(String.init) ?? "0"])
        }
        let inputURL = folder.appendingPathComponent("input.json")
        let output = folder.appendingPathComponent("output.json")
        try JSONEncoder().encode(input).write(to: inputURL)
        let script = folder.appendingPathComponent("export.el")
        try #"""
            ;;; -*- lexical-binding: t -*-
            (require 'org)
            (require 'ox-latex)
            (require 'json)
            (setq user-full-name "A. Writer")
            (let ((results nil))
              (seq-doseq (c (json-read-file (getenv "ORACLE_INPUT")))
                (with-current-buffer (find-file-noselect (aref c 0))
                  (let ((point (string-to-number (aref c 2))))
                    (push (condition-case e
                              (progn (when (> point 0) (goto-char point))
                                     (org-export-as 'latex (> point 0) nil (equal (aref c 1) "1")))
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
            return try LaTeXExport.document(text, bodyOnly: c.bodyOnly, author: author)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    /// The output without what changes between runs: the `% Created` line, and labels, which
    /// are numbered in the order they appear.
    static func normalized(_ s: String) -> String {
        var s = s.replacing(#/(?m)^% Created .*\n/#, with: "")
        var labels: [String: String] = [:]
        s = s.replacing(#/org[0-9a-f]{7}/#) { m in
            let key = String(m.output)
            if let existing = labels[key] { return existing }
            let label = "org\(labels.count + 1)"
            labels[key] = label
            return label
        }
        return s
    }
}

struct LaTeXExportTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Conformance")
    static let corpus = ["minimal", "core", "headings", "listblocks", "lists", "table", "blocks", "timestamps", "footnote", "images", "tblfm"]

    /// Snippets for what the corpus doesn't show.
    static let snippets: [String] = [
        "No title here.\n",
        "#+TITLE: A /styled/ title\n#+SUBTITLE: and more\n#+AUTHOR: Someone & Co\n#+DATE: <2024-03-01 Fri>\n#+KEYWORDS: k1 k2\n#+DESCRIPTION: About $x$\n\nText.\n",
        "#+OPTIONS: toc:nil num:nil author:nil date:nil title:nil\n#+TITLE: T\n* One\n** Two\n*** Three\n**** Four\n***** Five\n",
        "#+OPTIONS: toc:2 num:1 H:2\n* One\n** Two\n*** Three\nbody\n*** Four\n* Back\n",
        "#+LATEX_CLASS: report\n#+LATEX_CLASS_OPTIONS: [a4paper,12pt]\n#+LATEX_HEADER: \\usepackage{xcolor}\n#+LATEX_HEADER_EXTRA: \\usepackage{tikz}\n* Part\n** Chapter\n*** Section\n",
        "#+LATEX_CLASS: book\n#+LATEX_COMPILER: xelatex\n#+LANGUAGE: fr\n* P\nx\n",
        "#+LATEX_COMPILER: lualatex\n#+LANGUAGE: nb\nText.\n",
        "Special: % $ # & { } _ ~ ^ \\ \\% \\- LaTeX TeX LaTeXs ... -- --- 3 < 4 > 2 a\\\\b\n[bracket] at the start\nand *bold*[x] then.\n",
        "Math \\(a+b\\) and $x^2$ and \\[y\\] and $$z$$ and \\alpha$\\beta$ then \\frac{1}{2} \\alpha{} \\aacute ok.\n",
        "Scripts x^2 y_{i} a_b and \\nbsp{}here.\n",
        "#+OPTIONS: ^:{}\nScripts x^2 y_{i} a_b.\n",
        "#+OPTIONS: ^:nil tex:nil\nScripts x^2 y_{i} and \\(a\\) gone.\n",
        "Markup *b* /i/ _u_ +s+ =v $ { -- <<= ~c \\ ^ ~= and *nested /italic/ bold*.\n",
        "Snippets @@latex:\\newpage@@ and @@html:<br>@@ gone. Also @@html:x@@ @@html:y@@ end.\n@@html:z@@ start\n",
        "Line one\\\\\nline two \\\\\n\\\\\nafter\n",
        "Links: [[https://orgmode.org][Org & co]] <https://a.b/c_d> https://x.y/%20 [[mailto:me@x.org]] [[file:doc.pdf][the doc]] [[./rel/file.txt]] [[file:/abs/path.org]]\n",
        "* Target section\nA <<anchor>> here and [[anchor]] and [[anchor][desc]].\n* Other\nSee [[*Target section]] and [[Target section][named]] and [[#cid]].\n* Third\n:PROPERTIES:\n:CUSTOM_ID: cid\n:END:\nx\n",
        "#+OPTIONS: num:nil\n* Head\nSee [[*Head]].\n",
        "Footnotes[fn:1] twice[fn:1] and[fn:2][fn:3] and inline[fn::anon /x/] and[fn:named:inline def].\n\n[fn:1] First.\n\n[fn:2] Second\n  with two lines.\n\n[fn:3] Third.\n",
        "1. one\n2. [@5] five\n   1. nested\n   2. [@3] three\n3. after\n\n- [X] done\n- [-] half\n- [ ] todo\n\n- term :: def\n- [X] checked term :: def2\n- [bracketed] item\n",
        "1. [ ] ordered box\n2. [X] done box\n\n+ plus bullet\n+ second\n\n#+ATTR_LATEX: :environment compactitem :options [x]\n- a\n- b\n",
        "#+CAPTION: Scores\n#+NAME: tab:scores\n| Name | Score |\n|------+-------|\n| a    |   1.5 |\n| b    |       |\n| c    |  1e3  |\n\nSee [[tab:scores]].\n",
        "#+ATTR_LATEX: :environment tabularx :width \\textwidth :align lX :center nil\n| a | b |\n| c | d |\n\n#+ATTR_LATEX: :float sideways :placement [H] :font \\small\n#+CAPTION: Side\n| 1 | 2 |\n\n#+ATTR_LATEX: :float nil\n#+CAPTION: Not floating\n| x | y |\n",
        "| *b* | =v= | [[https://x.y][l]] |\n|-----+-----+-----|\n| 1   | -2  | 3%  |\n| x   |     | 4   |\n|-----+-----+-----|\n",
        "#+NAME: code\n#+CAPTION: A listing\n#+begin_src python -n\nprint(1)\nprint(2)\n#+end_src\n\n#+begin_src emacs-lisp +n 10\n(a)\n#+end_src\n\n#+begin_example -r\nline (ref:x)\n#+end_example\n\n#+begin_src sh\n  indented\n    more\n#+end_src\n\n#+begin_src\n#+end_src\n",
        "#+begin_src c -n -k\nint x; (ref:decl)\nreturn x;\n#+end_src\n\nSee line [[(decl)]] and [[(decl)][line %s]].\n",
        "#+NAME: ex\n#+begin_example\n,* not a heading\n,#+not keyword\n#+end_example\n\n#+ATTR_LATEX: :environment lstlisting\n#+begin_example\nx\n#+end_example\n",
        "#+begin_quote\nQ /one/.\n\nQ two.\n#+end_quote\n#+ATTR_LATEX: :environment displayquote :options [x]\n#+begin_quote\nd\n#+end_quote\n\n#+begin_center\nC\n#+end_center\n#+begin_verse\n  Roses are red,\n    violets blue\n\nnext stanza\n#+end_verse\n",
        "#+begin_warning\nW *b*.\n#+end_warning\n\n#+ATTR_LATEX: :options [Note]\n#+begin_theorem\nT.\n#+end_theorem\n\n#+begin_export latex\n  \\begin{x}\n    y\n  \\end{x}\n#+end_export\n#+begin_export html\n<p>no</p>\n#+end_export\n#+begin_comment\nhidden\n#+end_comment\nafter\n",
        "#+LATEX: \\clearpage\n#+TOC: headlines 2\n#+TOC: tables\n#+INDEX: term\n: fixed\n:   width\n\n-----\n\nText\n-----\nmore\n",
        "\\begin{equation}\nx = 1\n\\end{equation}\n\n  \\begin{align}\n  a &= b\n  \\end{align}\n",
        "Para one.\n# a comment\nPara two.\n\n# comment\n\nPara three.\n#+begin_comment\nc\n#+end_comment\n\nfour\n",
        "* TODO [#B] Task :work:urgent_x:\nSCHEDULED: <2024-01-01 Mon>\n:PROPERTIES:\n:X: 1\n:END:\n:LOGBOOK:\n- note\n:END:\n:NOTES:\nDrawer *text*.\n:END:\nCLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:00] =>  1:00\nbody\n* Archived :ARCHIVE:\nhidden\n** child\n* Kept\n* Drop :noexport:\nx\n* COMMENT Gone\ny\n",
        "#+OPTIONS: pri:t tags:nil todo:nil\n* TODO [#A] Title [1/2] [50%]\n- [X] a\n- [ ] b\n",
        "#+SELECT_TAGS: pick\nPreamble text.\n* A\n* B :pick:\n** B1\n* C\n",
        "Dates <2024-01-15 Mon 9:05> [2024-02-29 Thu 10:00-11:30] <2024-01-15 Mon +1w -2d> <2024-01-15 Mon>--<2024-01-17 Wed> [2024-01-15 Mon .+1d]\n",
        "#+CAPTION: Fig /one/\n#+NAME: fig:one\n#+ATTR_LATEX: :width 5cm\n[[file:img.png]]\n\n#+ATTR_LATEX: :float wrap :width 0.4\\textwidth :placement {r}{0.4\\textwidth}\n[[file:w.jpg]]\n\n#+ATTR_LATEX: :scale 0.5 :center nil\n[[./s.pdf]]\n\n#+ATTR_LATEX: :height 2cm :options angle=90\n[[file:h.eps]]\n\nInline [[file:i.png]] image.\n\n#+ATTR_LATEX: :float multicolumn\n#+CAPTION: Wide\n[[file:m.png]]\n\n#+NAME: noCaption\n[[file:n.png]]\n",
        "#+MACRO: greet Hello, $1!\n{{{greet(World)}}} on {{{date}}}? {{{title}}} and {{{results(=x=)}}}.\n",
        "#+begin_src emacs-lisp :exports code\n(+ 1 2)\n#+end_src\n\n#+RESULTS:\n: 3\n\nafter\n",
        "  Indented paragraph\n  second line\n    deeper\n\n- item first line\n  continued\n    more\n",
        "* Low levels\n** two\n*** three\n**** four a\n**** four b\nbody\n***** five\n**** [bracket] four c\n* next\n",
        "#+OPTIONS: H:1 num:nil\n* one\n** two a\n** two b\n*** three\n",
        "#+EXCLUDE_TAGS: secret\n* A\n** B :secret:\n** C\n",
        "#+OPTIONS: timestamp:nil -:nil\nNo special... strings -- \\- here.\n",
        "Text with a statistics [2/3] cookie and 100% sure.\n",
        "* Section with <<target in heading>> and *bold* =code= ~x_y~ _u_\n",
        "- a\n\n- b\n  para two\n\n  para three\n- c\n  - d\n\n  - e\nafter list\n",
        "| | a |\n|---+---|\n| 1 |\n| 2 | 3 | 4 |\n|---+---|\n",
        "Entities \\ast \\nbsp \\_ \\to \\rarr \\deg{}C \\copy \\pi\\pi and \\alpha \\beta.\n",
        "#+TITLE: one\n#+TITLE: two\n#+AUTHOR:\nBody.\n",
        "H_2O x^{-1} a_{b_c} 10^10 e^{i\\pi} f_{\\alpha}\n",
        "Mixed $a$ text $b $ and $5 and $c$, $d$.\n",
        "Text @@latex:\\textbf{raw}@@ and @@tex:x@@ and @@LaTeX:y@@.\n",
        "- a\n  #+begin_quote\n  q\n  #+end_quote\n  tail\n",
        "#+NAME: src1\n#+begin_src sh\nls\n#+end_src\n\nSee [[src1]].\n\n#+NAME: quoted\n#+begin_quote\nq\n#+end_quote\n\n[[quoted][the quote]]\n",
        "*** starts deep\n* then shallow\n",
        "#+LANGUAGE: de\n* Teil\nText.\n",
        "#+LANGUAGE: xx-yy\nText.\n",
        "#+ATTR_LATEX: :caption \\caption{Raw}\n| a |\n",
        "Fixed:\n: one\n:\n: three\n",
        "Text.[fn:1]\n* Footnotes\n[fn:1] Note.\n",
        "| a | =b\\\\|c= |\n\nThe {{{title}}} macro and ={{{title}}}= as written.\n",
        "#+begin_src emacs-lisp :exports none\n(hidden)\n#+end_src\n\n#+RESULTS:\n: gone\n\nafter\n\n#+RESULTS: orphan\n: kept\n",
        "Plain LaTeX's own words and TeXbook.\n",
    ]

    @Test(.enabled(if: oracle))
    func matchesEmacs() throws {
        var cases = try Self.corpus.map { LaTeXOracle.Case(text: try String(contentsOf: Self.folder.appendingPathComponent("\($0).org"), encoding: .utf8)) }
        cases += Self.snippets.map { LaTeXOracle.Case(text: $0) }
        let names = Self.corpus + Self.snippets.indices.map { "snippet \($0)" }
        try compare(cases, names: names)
    }

    @Test(.enabled(if: oracle))
    func bodyOnlyAndSubtreesMatchEmacs() throws {
        let doc = "#+TITLE: Doc\n#+OPTIONS: toc:nil\nIntro.\n* One\nFirst.\n** Sub\n:PROPERTIES:\n:EXPORT_TITLE: Exported title\n:END:\nSub body *b*.\n*** Deeper\nx\n* Two\nSecond.\n"
        let sub = (doc as NSString).range(of: "** Sub").location
        let one = (doc as NSString).range(of: "First.").location
        let cases = [
            LaTeXOracle.Case(text: doc, bodyOnly: true),
            LaTeXOracle.Case(text: try String(contentsOf: Self.folder.appendingPathComponent("blocks.org"), encoding: .utf8), bodyOnly: true),
            LaTeXOracle.Case(text: doc, subtree: EmacsOracle.point(sub, in: doc)),
            LaTeXOracle.Case(text: doc, subtree: EmacsOracle.point(one, in: doc)),
            LaTeXOracle.Case(text: doc, bodyOnly: true, subtree: EmacsOracle.point(sub, in: doc)),
        ]
        try compare(cases, names: ["body", "blocks body", "subtree", "subtree from body", "subtree body"])
    }

    private func compare(_ cases: [LaTeXOracle.Case], names: [String]) throws {
        let emacs = try LaTeXOracle.export(cases)
        for (index, c) in cases.enumerated() {
            let ours = LaTeXOracle.native(c)
            if ours.hasPrefix("ERROR: ") {
                Issue.record("\(names[index]) unsupported: \(ours)\n--- org\n\(c.text)")
                continue
            }
            if let dump = ProcessInfo.processInfo.environment["LATEX_DUMP"], LaTeXOracle.normalized(ours) != LaTeXOracle.normalized(emacs[index]) {
                let name = names[index].replacingOccurrences(of: " ", with: "_")
                try? LaTeXOracle.normalized(ours).write(toFile: dump + "/" + name + ".ours", atomically: true, encoding: .utf8)
                try? LaTeXOracle.normalized(emacs[index]).write(toFile: dump + "/" + name + ".emacs", atomically: true, encoding: .utf8)
                try? c.text.write(toFile: dump + "/" + name + ".org", atomically: true, encoding: .utf8)
            }
            #expect(LaTeXOracle.normalized(ours) == LaTeXOracle.normalized(emacs[index]),
                    "\(names[index])\n--- org\n\(c.text)\n--- ours\n\(ours)\n--- emacs\n\(emacs[index])")
        }
    }

    /// What Emacs exports differently or refuses is refused, naming it.
    @Test func refusesWhatItCannotMatch() {
        func reason(_ org: String) -> String? {
            do {
                _ = try LaTeXExport.document(org)
                return nil
            } catch let error as LaTeXExport.Unsupported {
                return error.reason
            } catch {
                return "\(error)"
            }
        }
        #expect(reason("#+LATEX_CLASS: beamer\nx\n") == "Unknown LaTeX class `beamer'")
        #expect(reason("See [[id:nowhere]].\n")?.hasPrefix("Unable to resolve link") == true)
        #expect(reason("See [[nowhere]].\n")?.hasPrefix("Unable to resolve link") == true)
        #expect(reason("Ref[fn:9].\n") == "Definition not found for footnote 9")
        #expect(reason("#+OPTIONS: \\n:t\nx\n") == "#+OPTIONS: \\n:t")
        #expect(reason("#+ATTR_LATEX: :mode math\n| a | b |\n") == "#+ATTR_LATEX: :mode math")
        #expect(reason("#+LATEX_HEADER: \\usepackage[AUTO]{babel}\nx\n") != nil)
        #expect(reason("#+begin_src sh :exports results\necho\n#+end_src\n") == ":exports results")
        #expect(reason("[cite:@key]\n") == "Citations")
    }

    @Test func labelsStayTheSame() throws {
        let org = "* A\n* B\nSee [[*A]].\n"
        let first = try LaTeXExport.document(org, now: Date(timeIntervalSince1970: 0))
        let second = try LaTeXExport.document(org, now: Date(timeIntervalSince1970: 0))
        #expect(first == second)
        #expect(first.contains("\\label{sec:org") && first.contains("\\ref{sec:org"))
    }
}
