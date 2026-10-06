import Foundation
import Testing
@testable import OrgCore

struct ExportOptionsTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    @Test func readsOptions() {
        let o = ExportOptions.parse("#+OPTIONS: toc:2 num:nil tags:not-in-toc\n#+OPTIONS: todo:nil ^:{} pri:t H:4\n#+EXCLUDE_TAGS: private\n#+HTML_HEAD: <link rel=x>\n")
        #expect(o.toc == 2 && o.num == nil && o.tags && !o.tagsInTOC && !o.todo && o.scripts == .braces && o.priority && o.headlineLevels == 4)
        #expect(o.excludeTags == ["private"] && o.htmlHead == ["<link rel=x>"])
        #expect(ExportOptions.parse("* x\n").toc == 3)
        #expect(ExportOptions.parse("#+OPTIONS: H:2 toc:t\n").toc == 2)
    }

    @Test func pagesFollowOptions() {
        let org = """
            #+TITLE: Doc
            #+OPTIONS: ^:{} pri:t
            #+HTML_HEAD: <link rel="stylesheet" href="s.css">
            * TODO [#A] One :work:
            x_1 y_{2} \\(a^2\\) $b$ and $5
            ** Two
            * Secret :noexport:
            hidden
            * COMMENT Draft
            gone
            * Old :ARCHIVE:
            archived body
            """
        let page = HTMLExport.page(org, fallbackTitle: "f")
        #expect(page.contains("<div id=\"table-of-contents\""))
        #expect(page.contains("<span class=\"section-number-2\">1.</span>"))
        #expect(page.contains("<span class=\"section-number-3\">1.1.</span>"))
        #expect(page.contains("x_1 y<sub>2</sub>"))
        #expect(page.contains("<span class=\"priority\">[#A]</span>"))
        #expect(page.contains("<link rel=\"stylesheet\" href=\"s.css\">"))
        #expect(page.contains("MathJax-script") && page.contains("\\(a^2\\)"))
        #expect(!page.contains("hidden") && !page.contains("Secret") && !page.contains("gone"))
        #expect(page.contains("Old") && !page.contains("archived body"))
        let plain = HTMLExport.page("#+OPTIONS: toc:nil num:nil todo:nil tags:nil\n* TODO A :t:\n", fallbackTitle: "f")
        #expect(!plain.contains("id=\"table-of-contents\"") && !plain.contains("section-number") && !plain.contains("TODO") && !plain.contains("class=\"tag\""))
        let selected = HTMLExport.page("* A\na\n* B :export:\nb\n** C\nc\n", fallbackTitle: "f")
        #expect(!selected.contains("<p>a</p>") && selected.contains("<p>b</p>") && selected.contains("<p>c</p>"))
    }

    @Test(.enabled(if: oracle))
    func expandsIncludesAndMacrosLikeOrg() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "* Part\nbody\n** Sub\nsub body\n* Other\n:PROPERTIES:\n:CUSTOM_ID: oth\n:END:\nother\n".write(to: folder.appendingPathComponent("part.org"), atomically: true, encoding: .utf8)
        try "line 1\nline 2\n* not a heading\nline 4\nline 5\n".write(to: folder.appendingPathComponent("code.sh"), atomically: true, encoding: .utf8)
        let text = """
            #+TITLE: The Doc
            #+AUTHOR: Me
            #+MACRO: greet Hello, $1 and $2!
            Intro {{{title}}} by {{{author}}}.
            #+INCLUDE: "part.org"
            #+INCLUDE: "part.org::*Sub" :minlevel 1
            #+INCLUDE: "part.org::#oth"
            #+INCLUDE: "code.sh" src sh :lines "2-4"
            #+INCLUDE: "code.sh" example
            {{{greet(you\\, me,them)}}} {{{n}}} {{{n}}} {{{n(x)}}} {{{keyword(AUTHOR)}}} {{{input-file}}}
            """ + "\n"
        let path = folder.appendingPathComponent("main.org").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let emacs = try EmacsOracle.evaluate(text, """
            (with-current-buffer (find-file-noselect \(lispString(path)))
              (require 'ox)
              (org-export-expand-include-keyword)
              (org-macro-initialize-templates)
              (org-macro-replace-all org-macro-templates)
              (list (buffer-substring-no-properties (point-min) (point-max))))
            """)
        let ours = ExportPreprocess.macros(ExportPreprocess.includes(text, directory: folder), path: path)
        #expect(ours == emacs.first, "ours:\n\(ours)\nemacs:\n\(emacs.first ?? "")")
    }
}
