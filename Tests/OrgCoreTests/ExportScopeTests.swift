import Foundation
import Testing
@testable import OrgCore

struct ExportScopeTests {
    static let file = """
        #+TITLE: Whole file
        #+AUTHOR: Ann
        #+OPTIONS: toc:nil num:nil
        * Intro
        Some intro.
        * TODO [#A] Project :work:
        SCHEDULED: <2026-10-10 Sat>
        :PROPERTIES:
        :EXPORT_FILE_NAME: project-notes
        :EXPORT_AUTHOR: Bob
        :END:
        Body of project.
        ** Step one
        Do it.
        *** Deep
        deep text
        * Other
        """

    static var project: Int { (file as NSString).range(of: "Body of").location }

    /// As `org-export-as` with SUBTREEP in Emacs 31: the heading's title is the title, its
    /// EXPORT_AUTHOR the author; planning and drawer left out; children one level up.
    @Test func subtreeIsADocumentOfItsOwn() throws {
        let text = try #require(ExportScope.subtree(Self.file, at: Self.project))
        #expect(text == """
            #+TITLE: Whole file
            #+AUTHOR: Ann
            #+OPTIONS: toc:nil num:nil
            #+TITLE: Project
            #+AUTHOR: Bob
            Body of project.
            * Step one
            Do it.
            ** Deep
            deep text

            """)
        let meta = HTMLExport.metadata(text)
        #expect(meta.title == "Project" && meta.author == "Bob")
        let body = HTMLExport.page(text, fallbackTitle: "t", bodyOnly: true)
        #expect(!body.contains("<html") && !body.contains("class=\"title\"") && !body.contains("Intro"))
        #expect(body.contains("<h2") && body.contains("Step one") && body.contains("<h3") && !body.contains("table-of-contents"))
        #expect(ExportScope.subtree(Self.file, at: 0) == nil)
    }

    @Test func exportTitleOverridesTheHeading() throws {
        let file = "* Proj\n:PROPERTIES:\n:EXPORT_TITLE: Custom\n:EXPORT_OPTIONS: toc:nil\n:END:\nText.\n"
        let text = try #require(ExportScope.subtree(file, at: 0))
        #expect(HTMLExport.metadata(text).title == "Custom")
        #expect(text.hasSuffix("#+OPTIONS: toc:nil\nText.\n"))
    }

    /// `org-export-output-file-name`: relative to the file's folder, the extension replaced.
    @Test func fileNames() {
        let source = URL(fileURLWithPath: "/notes/t.org")
        #expect(ExportScope.fileName(Self.file, subtreeAt: Self.project) == "project-notes")
        #expect(ExportScope.fileName(Self.file, subtreeAt: 0) == nil)
        #expect(ExportScope.fileName("#+EXPORT_FILE_NAME: out/x\n* A\n") == "out/x")
        #expect(ExportScope.output(for: source, name: "out/x", extension: "html").path == "/notes/out/x.html")
        #expect(ExportScope.output(for: source, name: "out/x.txt", extension: "html").path == "/notes/out/x.html")
        #expect(ExportScope.output(for: source, name: "/tmp/abs", extension: "md").path == "/tmp/abs.md")
        #expect(ExportScope.output(for: source, name: nil, extension: "md").path == "/notes/t.md")
    }

    @Test func markdownBodyOnlyHasNoTitle() {
        let text = "#+TITLE: T\n* A\nx\n"
        #expect(MarkdownExport.document(text).hasPrefix("# T"))
        #expect(MarkdownExport.document(text, bodyOnly: true).hasPrefix("## A"))
    }
}
