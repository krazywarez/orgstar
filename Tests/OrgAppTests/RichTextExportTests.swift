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

    /// As iOS writes Word, whose HTML import keeps no tables: the tables from the HTML.
    @Test func wordTablesFromTheHTML() throws {
        let (page, tables) = RichTextExport.extractingTables(Self.html)
        #expect(tables.count == 1 && !page.contains("<table") && page.contains(DocxWriter.marker(0)))
        #expect(tables[0].components(separatedBy: "<w:tc>").count - 1 == 4)
        #expect(tables[0].contains("<w:b/></w:rPr><w:t xml:space=\"preserve\">Name</w:t>"))
        #expect(tables[0].contains("<w:r><w:rPr></w:rPr><w:t xml:space=\"preserve\">1</w:t>"))
        let data = DocxWriter.data(from: try RichTextExport.attributed(html: page, directory: nil), tables: tables)
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("<w:tbl>") && !xml.contains("\u{E000}"))
        // A page size of its own, or readers choose a narrow one.
        #expect(xml.contains("<w:pgSz w:w="))
        let back = try NSAttributedString(data: data, options: [:], documentAttributes: nil).string
        #expect(back.contains("Report") && back.contains("Count") && back.contains("second"), "\(back)")
        #expect(RichTextExport.decode("a &amp;lt; &#233;&#x41; &quot;") == "a &lt; éA \"")
    }

    /// Headings get Word's heading styles, so its navigation pane and contents fields see them,
    /// and image links come through as pictures.
    @Test func wordHeadingStylesAndImages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("red.png"))
        let html = HTMLExport.page("#+TITLE: Report\n* Results\nText.\n** Detail\n[[file:red.png]]\n", fallbackTitle: "t")
        let data = try RichTextExport.docx(html: html, directory: folder)
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("word/styles.xml") && xml.contains("w:styleId=\"Heading1\"") && xml.contains("<w:name w:val=\"heading 1\"/>"))
        #expect(xml.contains("<w:pStyle w:val=\"Title\"/>"))
        #expect(xml.contains("<w:pStyle w:val=\"Heading1\"/>") && xml.contains("<w:pStyle w:val=\"Heading2\"/>"))
        #expect(!xml.contains("\u{E002}") && !xml.contains("\u{E004}"))
        #expect(xml.contains("word/media/image1.png") && xml.contains("<w:drawing>") && xml.contains("r:embed=\"img1\""))
        // 40 by 20 pixels at 96 to the inch.
        #expect(xml.contains("cx=\"381000\" cy=\"190500\""))
        let back = try NSAttributedString(data: data, options: [:], documentAttributes: nil).string
        #expect(back.contains("Results") && back.contains("Detail") && back.contains("Text."))
    }

    @Test func wordPagesAreLetterOrA4() {
        #expect(PDFExport.usesLetter("US") && !PDFExport.usesLetter("DE") && !PDFExport.usesLetter(nil))
        #expect(DocxWriter.section(letter: true).contains("<w:pgSz w:w=\"12240\" w:h=\"15840\"/>"))
        #expect(DocxWriter.section(letter: false).contains("<w:pgSz w:w=\"11906\" w:h=\"16838\"/>"))
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
