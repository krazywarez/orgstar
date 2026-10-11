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
    }
}
