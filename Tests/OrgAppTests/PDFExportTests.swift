import Foundation
import OrgCore
import PDFKit
import Testing
@testable import OrgApp

@MainActor
struct PDFExportTests {
    /// A long document comes out as several pages with its text, without Emacs.
    @Test func paginatesTheHTMLExport() async throws {
        let sections = (1...40).map { "* Section \($0)\n" + String(repeating: "Some words in a paragraph. ", count: 30) + "\n" }.joined()
        let html = HTMLExport.page("#+TITLE: Long\n" + sections + "#+begin_src sh\necho done\n#+end_src\n", fallbackTitle: "t")
        let data = try await PDFExport.pdf(html: html, directory: nil)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount > 3)
        let text = document.string ?? ""
        #expect(text.contains("Long") && text.contains("Section 40") && text.contains("echo done"))
        let page = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(page.width < page.height)
        // Page numbers, centred under the text, as annotations so the export's links stay.
        let numbers = (0..<document.pageCount).compactMap { document.page(at: $0)?.annotations.first { $0.type == "FreeText" }?.contents }
        #expect(numbers == (1...document.pageCount).map(String.init))
    }

    @Test func marginsFontAndNoNumbers() async throws {
        let html = HTMLExport.page("#+TITLE: Short\nOne paragraph.\n", fallbackTitle: "t")
        let data = try await PDFExport.pdf(html: html, directory: nil, options: PDFExport.Options(margin: 100, font: "Georgia", pageNumbers: false))
        let document = try #require(PDFDocument(data: data))
        #expect(document.page(at: 0)?.annotations.contains { $0.type == "FreeText" } == false)
        let css = PDFExport.css(PDFExport.Options(margin: 100, font: "Georgia", pageNumbers: false))
        #expect(css.contains("font-family: \"Georgia\""))
        #expect(!PDFExport.css(PDFExport.Options()).contains("font-family"))
    }

    /// In the sandbox WebKit can't read the user's folders, so local images go in the page.
    @Test func inlinesLocalImages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("img/a b.png"))
        try Data([4]).write(to: folder.appendingPathComponent("c.svg"))
        let absolute = folder.appendingPathComponent("c.svg").path
        let html = #"<p><img src="img/a b.png" alt="a"> <img alt="c" src="\#(absolute)"> <img src="https://x.org/r.png"> <img src="gone.png"></p>"#
        let inlined = PDFExport.inliningImages(html, directory: folder)
        #expect(inlined.contains(#"<img src="data:image/png;base64,AQID" alt="a">"#))
        #expect(inlined.contains(#"<img alt="c" src="data:image/svg+xml;base64,BA==">"#))
        #expect(inlined.contains(#"<img src="https://x.org/r.png">"#))
        #expect(inlined.contains(#"<img src="gone.png">"#))
        #expect(PDFExport.inliningImages(#"<img src="img/a b.png">"#, directory: nil) == #"<img src="img/a b.png">"#)
    }
}
