import AppKit
import Foundation
import OrgCore
import Testing
@testable import OrgApp

@MainActor
struct RichTextExportTests {
    static let html = HTMLExport.page("""
        #+TITLE: Report
        * Results
        Some *bold* text.
        | Name | Count |
        |------+-------|
        | a    |     1 |
        - first
        - second
        #+begin_src sh
        echo hi
        #+end_src
        """, fallbackTitle: "t")

    @Test func wordAndRTFReadBackWithTheText() throws {
        let text = try RichTextExport.attributed(html: Self.html, directory: nil)
        for data in [try RichTextExport.docx(text), try RichTextExport.rtf(text)] {
            let back = try NSAttributedString(data: data, options: [:], documentAttributes: nil).string
            #expect(back.contains("Report") && back.contains("bold") && back.contains("Count") && back.contains("second") && back.contains("echo hi"), "\(back)")
        }
        // Word gets a real table, which the system's own writer leaves out.
        let xml = String(decoding: try RichTextExport.docx(text), as: UTF8.self)
        #expect(xml.contains("<w:tbl>") && xml.components(separatedBy: "<w:tc>").count - 1 == 4)
        // Bold survives.
        let bold = (text.string as NSString).range(of: "bold")
        let font = text.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func plainTextAndDarkSystemsStayReadable() throws {
        let text = try RichTextExport.attributed(html: Self.html, directory: nil)
        let plain = RichTextExport.plain(text)
        #expect(plain.hasPrefix("Report") && plain.contains("Some bold text.") && plain.hasSuffix("echo hi\n"))
        // The colors are the light ones whatever the appearance.
        let color = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect((color?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.5)
    }
}
