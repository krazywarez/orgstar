import Foundation
import Testing
@testable import OrgCore

/// Citations against `oc-basic` through ox-md: each paragraph and the bibliography.
struct CitationTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let bib = #"""
        @string{jos = "Journal of Stuff"}
        @article{doe2020,
          author = {Doe, Jane and Roe, Richard},
          title = {A Study of {Things}},
          journal = jos,
          year = {2020},
          pages = {1--10}
        }
        @book{smith1999,
          author = "Smith, John",
          title = {The Book},
          publisher = {Pub House},
          year = 1999
        }
        @misc{lee,
          author = {Lee, Kim and Park, Min and Choi, Su},
          title = {Three Authors},
          year = {2021}
        }
        @article{doe2020b,
          author = {Doe, Jane and Roe, Richard},
          title = {Another Study},
          journal = {Other Journal},
          year = {2020}
        }
        @report{org,
          editor = {{Org Team}},
          title = {Manual},
          institution = {GNU},
          date = {2022-03-04}
        }
        @comment{ignored}
        """#

    static let json = #"""
        [{"id": "csl1", "author": [{"family": "Zed", "given": "Ann"}], "title": "From JSON", "issued": {"date-parts": [[2018, 5]]}, "publisher": "Pubs"}]
        """#

    static let body = """
        Plain [cite:@doe2020] and [cite:@smith1999 p. 5] and [cite/t:@lee].

        Several [cite:see @doe2020;@smith1999] and common [cite:pre; @lee; post].

        Same year [cite:@doe2020b] then [cite/t:@doe2020] and [cite/text/c:@lee].

        Noauthor [cite/na:@doe2020], bare [cite/na/b:@smith1999], author [cite/a:@lee] [cite/author/caps:@lee].

        Bare default [cite//b:@smith1999] and text bare [cite/t/b:@org], missing [cite:@nope], json [cite:@csl1].

        Nocite here [cite/n:@lee] and there [cite/nocite:@smith1999].

        Markup [cite:/see/ @doe2020 *p. 3*].

        #+print_bibliography:
        """

    func compare(_ text: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-cite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.bib.write(to: folder.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        try Self.json.write(to: folder.appendingPathComponent("more.json"), atomically: true, encoding: .utf8)
        let path = folder.appendingPathComponent("doc.org").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let text = "#+OPTIONS: toc:nil\n" + text
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let emacs = try EmacsOracle.evaluate("", """
            (with-current-buffer (find-file-noselect \(lispString(path)))
              (require 'ox-md) (require 'oc-basic)
              (list (org-export-as 'md nil nil t)))
            """)[0]
        let ours = MarkdownExport.document(text, path: path)
        func paragraphs(_ s: String) -> [String] {
            s.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        #expect(paragraphs(ours) == paragraphs(emacs), "ours:\n\(ours)\nemacs:\n\(emacs)")
    }

    @Test func htmlUsesTheSameCitations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-cite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.bib.write(to: folder.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        let page = HTMLExport.page("#+bibliography: refs.bib\nSee [cite:@doe2020 *p. 3*] [cite/n:@lee].\n\n#+print_bibliography:\n", fallbackTitle: "t",
                                   path: folder.appendingPathComponent("doc.org").path)
        #expect(page.contains("<p>See (Doe, Jane and Roe, Richard, 2020 <strong>p. 3</strong>).</p>"))
        #expect(page.contains("<p>Doe, Jane and Roe, Richard (2020). <i>A Study of Things</i>, Journal of Stuff.</p>"))
        #expect(page.contains("<p>Lee, Kim and Park, Min and Choi, Su (2021). <i>Three Authors</i>.</p>"))
        #expect(!page.contains("[cite"))
    }

    @Test(.enabled(if: oracle))
    func authorYearMatchesOcBasic() throws {
        try compare("#+bibliography: refs.bib\n#+bibliography: more.json\n" + Self.body)
    }

    @Test(.enabled(if: oracle))
    func numericMatchesOcBasic() throws {
        try compare("#+bibliography: refs.bib\n#+cite_export: basic numeric numeric\n" + "Cites [cite:@smith1999;@doe2020;@lee] and [cite:@doe2020b] and [cite:see @lee p. 2] and [cite:pre; @lee;@org; post].\n\n#+print_bibliography:\n")
    }

    @Test(.enabled(if: oracle))
    func plainBibliographyMatchesOcBasic() throws {
        try compare("#+bibliography: refs.bib\n#+cite_export: basic plain\n" + "A [cite:@lee] [cite:@doe2020] [cite:@org].\n\n#+print_bibliography:\n")
    }
}
