import Foundation
#if os(macOS)
import AppKit
typealias DocxFont = NSFont
typealias DocxColor = NSColor
#else
import UIKit
typealias DocxFont = UIFont
typealias DocxColor = UIColor
#endif

/// Word's `.docx` from styled text: paragraphs with their runs' fonts, colors and links, and
/// tables from the text's table blocks, which the system's own writer leaves out. iOS's HTML
/// import keeps no tables, so there `tables` holds them, each standing for a paragraph that is
/// its `marker` alone.
enum DocxWriter {
    static func marker(_ index: Int) -> String { "\u{E000}\(index)\u{E001}" }
    /// Put at the start of a heading's text: 0 for the title, 1 to 6 for Word's heading levels.
    static func headingMarker(_ level: Int) -> String { "\u{E002}\(level)\u{E003}" }
    /// Stands for `images[index]` in the text.
    static func imageMarker(_ index: Int) -> String { "\u{E004}\(index)\u{E005}" }

    /// A picture for the document: PNG, JPEG or GIF bytes and its size in pixels.
    struct Image: Equatable {
        let data: Data
        let ext: String
        let width: Int
        let height: Int
    }

    /// EMUs to a pixel at 96 to the inch, and to a twip.
    static let emuPerPixel = 9525, emuPerTwip = 635

    static func data(from text: NSAttributedString, tables: [String] = [], images: [Image] = []) -> Data {
        var links: [String] = []
        let letter = PDFExport.usesLetter()
        let body = paragraphs(text, tables: tables, images: images, maxWidth: (letter ? 12240 : 11906) - 2 * 1134, links: &links)
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\
            \(section(letter: letter))\
            </w:body></w:document>
            """
        let relationships = "<Relationship Id=\"styles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + links.enumerated().map { index, url in
                "<Relationship Id=\"link\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(escape(url))\" TargetMode=\"External\"/>"
            }.joined()
            + images.enumerated().map { index, image in
                "<Relationship Id=\"img\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\(index + 1).\(image.ext)\"/>"
            }.joined()
        let mediaTypes = Set(images.map(\.ext)).sorted().map { "<Default Extension=\"\($0)\" ContentType=\"image/\($0)\"/>" }.joined()
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\(mediaTypes)\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
            </Types>
            """)
        zip.add("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
            </Relationships>
            """)
        zip.add("word/_rels/document.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)</Relationships>
            """)
        zip.add("word/document.xml", document)
        zip.add("word/styles.xml", styles)
        for (index, image) in images.enumerated() { zip.add("word/media/image\(index + 1).\(image.ext)", data: image.data) }
        return zip.data()
    }

    /// Normal, Title and Word's built-in heading 1 to 6, so the navigation pane, outline view
    /// and contents fields see the headings. The runs keep their own fonts and colors.
    static let styles: String = {
        let headings = (1...6).map { level in
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/>"
                + "<w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr>"
                + "<w:rPr><w:b/></w:rPr></w:style>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Helvetica Neue"/>\
            <w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault/></w:docDefaults>\
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
            <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
            <w:qFormat/><w:pPr><w:keepNext/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>\(headings)\
            </w:styles>
            """
    }()

    /// An inline picture, as wide as its pixels at 96 to the inch, or `maxWidth` twips if less.
    static func drawing(_ image: Image, index: Int, maxWidth: Int) -> String {
        var cx = image.width * emuPerPixel, cy = image.height * emuPerPixel
        let limit = maxWidth * emuPerTwip
        if cx > limit, cx > 0 {
            cy = cy * limit / cx
            cx = limit
        }
        let id = index + 1
        return "<w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:docPr id=\"\(id)\" name=\"Picture \(id)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"image\(id).\(image.ext)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"img\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>"
    }

    /// The page: Letter or A4, as PDF export has it. Without a size, readers pick their own, and
    /// Quick Look and Pages pick a narrow one.
    static func section(letter: Bool) -> String {
        let size = letter ? "<w:pgSz w:w=\"12240\" w:h=\"15840\"/>" : "<w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
        return "<w:sectPr>\(size)<w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/></w:sectPr>"
    }

    /// Paragraphs in order, consecutive ones in the same table gathered into `<w:tbl>`.
    /// A `<w:tbl>` of rows of cells, each cell its paragraphs.
    static func table(_ rows: [[String]], columns: Int) -> String {
        var out = "<w:tbl><w:tblPr><w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map {
            "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A0A0A0\"/>"
        }.joined() + "</w:tblBorders><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr>"
        out += "<w:tblGrid>" + String(repeating: "<w:gridCol/>", count: columns) + "</w:tblGrid>"
        for row in rows {
            out += "<w:tr>"
            for column in 0..<columns {
                out += "<w:tc><w:tcPr/>" + (column < row.count && !row[column].isEmpty ? row[column] : "<w:p/>") + "</w:tc>"
            }
            out += "</w:tr>"
        }
        return out + "</w:tbl>"
    }

    private static func paragraphs(_ text: NSAttributedString, tables: [String], images: [Image], maxWidth: Int, links: inout [String]) -> String {
        let string = text.string as NSString
        var out = ""
        #if os(macOS)
        var table: (block: NSTextTable, cells: [[Int: [String]]])?
        func flushTable() {
            guard let current = table else { return }
            let columns = max(current.block.numberOfColumns, current.cells.map { ($0.keys.max() ?? 0) + 1 }.max() ?? 1)
            out += Self.table(current.cells.map { row in (0..<columns).map { row[$0]?.joined() ?? "" } }, columns: columns)
            table = nil
        }
        #else
        func flushTable() {}
        #endif
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let line = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = tables.indices.first(where: { line == marker($0) }) {
                flushTable()
                out += tables[index]
                continue
            }
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let paragraph = self.paragraph(text, range, style, images: images, maxWidth: maxWidth, links: &links)
            #if os(macOS)
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                if table?.block !== cell.table {
                    flushTable()
                    table = (cell.table, [])
                }
                while table!.cells.count <= cell.startingRow { table!.cells.append([:]) }
                table!.cells[cell.startingRow][cell.startingColumn, default: []].append(paragraph)
                continue
            }
            #endif
            flushTable()
            out += paragraph
        }
        flushTable()
        return out
    }

    private static func paragraph(
        _ text: NSAttributedString, _ range: NSRange, _ style: NSParagraphStyle?, images: [Image], maxWidth: Int, links: inout [String]
    ) -> String {
        // In the order the schema has them: style, tabs, spacing, indentation, justification.
        var properties = ""
        let content = (text.string as NSString).substring(with: range)
        if let match = content.firstMatch(of: /^\s*\u{E002}(\d)\u{E003}/), let level = Int(match.1) {
            properties += "<w:pStyle w:val=\"\(level == 0 ? "Title" : "Heading\(level)")\"/>"
        }
        if let style {
            if !style.tabStops.isEmpty {
                properties += "<w:tabs>" + style.tabStops.map { "<w:tab w:val=\"left\" w:pos=\"\(Int($0.location * 20))\"/>" }.joined() + "</w:tabs>"
            }
            properties += "<w:spacing w:before=\"\(Int(style.paragraphSpacingBefore * 20))\" w:after=\"\(Int(style.paragraphSpacing * 20))\"/>"
            let left = Int(style.headIndent * 20), first = Int((style.firstLineHeadIndent - style.headIndent) * 20)
            if left != 0 || first != 0 { properties += "<w:ind w:left=\"\(left)\" \(first < 0 ? "w:hanging=\"\(-first)\"" : "w:firstLine=\"\(first)\"")/>" }
            switch style.alignment {
            case .center: properties += "<w:jc w:val=\"center\"/>"
            case .right: properties += "<w:jc w:val=\"right\"/>"
            default: break
            }
        }
        var runs = ""
        text.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            var piece = (text.string as NSString).substring(with: runRange)
            piece = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
            piece = piece.replacing(/\u{E002}\d\u{E003}/, with: "")
            guard !piece.isEmpty else { return }
            var run = run(piece, attributes, images: images, maxWidth: maxWidth)
            let link = (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
            if let link {
                links.append(link)
                run = "<w:hyperlink r:id=\"link\(links.count)\">\(run)</w:hyperlink>"
            }
            runs += run
        }
        return "<w:p><w:pPr>\(properties)</w:pPr>\(runs)</w:p>"
    }

    private static func run(_ piece: String, _ attributes: [NSAttributedString.Key: Any], images: [Image], maxWidth: Int) -> String {
        var properties = ""
        if let font = attributes[.font] as? DocxFont {
            let traits = self.traits(font)
            let name = traits.mono ? "Menlo" : traits.family
            properties += "<w:rFonts w:ascii=\"\(escape(name))\" w:hAnsi=\"\(escape(name))\" w:cs=\"\(escape(name))\"/>"
            if traits.bold { properties += "<w:b/>" }
            if traits.italic { properties += "<w:i/>" }
            properties += "<w:sz w:val=\"\(Int((font.pointSize * 2).rounded()))\"/>"
        }
        if let color = (attributes[.foregroundColor] as? DocxColor).flatMap(rgba) { properties += "<w:color w:val=\"\(hex(color))\"/>" }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { properties += "<w:u w:val=\"single\"/>" }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { properties += "<w:strike/>" }
        if let background = (attributes[.backgroundColor] as? DocxColor).flatMap(rgba), background.a > 0.05 {
            properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex(background))\"/>"
        }
        if let offset = attributes[.baselineOffset] as? Double, offset != 0 { properties += "<w:vertAlign w:val=\"\(offset > 0 ? "superscript" : "subscript")\"/>" }
        // Tabs and line breaks are elements of their own.
        var content = ""
        var textRun = ""
        func flush() {
            if !textRun.isEmpty { content += "<w:t xml:space=\"preserve\">\(escape(textRun))</w:t>" }
            textRun = ""
        }
        // A picture's marker: its index between the two marker characters.
        var picture: String?
        for character in piece {
            if picture != nil {
                if character == "\u{E005}" {
                    if let index = Int(picture!), images.indices.contains(index) { content += drawing(images[index], index: index, maxWidth: maxWidth) }
                    picture = nil
                } else {
                    picture!.append(character)
                }
                continue
            }
            switch character {
            case "\u{E004}": flush(); picture = ""
            case "\t": flush(); content += "<w:tab/>"
            case "\u{2028}", "\n": flush(); content += "<w:br/>"
            default: textRun.append(character)
            }
        }
        flush()
        return "<w:r><w:rPr>\(properties)</w:rPr>\(content)</w:r>"
    }

    private static func traits(_ font: DocxFont) -> (bold: Bool, italic: Bool, mono: Bool, family: String) {
        let traits = font.fontDescriptor.symbolicTraits
        #if os(macOS)
        return (traits.contains(.bold), traits.contains(.italic), traits.contains(.monoSpace), font.familyName ?? "Helvetica Neue")
        #else
        return (traits.contains(.traitBold), traits.contains(.traitItalic), traits.contains(.traitMonoSpace), font.familyName)
        #endif
    }

    /// The color's sRGB components and alpha.
    private static func rgba(_ color: DocxColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        #if os(macOS)
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (r, g, b, a)
        #endif
    }

    /// `#rrggbb` of the color laid on white paper: Word has no transparency.
    private static func hex(_ color: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> String {
        func on(_ c: CGFloat) -> Int { Int(((c * color.a + (1 - color.a)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", on(color.r), on(color.g), on(color.b))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A zip archive with stored (uncompressed) entries, as `.docx` files are read.
struct ZipWriter {
    private var entries: [(name: Data, data: Data, crc: UInt32, offset: UInt32)] = []
    private var archive = Data()

    mutating func add(_ name: String, _ text: String) {
        add(name, data: Data(text.utf8))
    }

    mutating func add(_ name: String, data: Data) {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(data)
        let offset = UInt32(archive.count)
        archive += Self.le32(0x04034b50) + Self.le16(20) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0x21)
        archive += Self.le32(crc) + Self.le32(UInt32(data.count)) + Self.le32(UInt32(data.count))
        archive += Self.le16(UInt16(nameData.count)) + Self.le16(0) + nameData + data
        entries.append((nameData, data, crc, offset))
    }

    func data() -> Data {
        var central = Data()
        for entry in entries {
            central += Self.le32(0x02014b50) + Self.le16(20) + Self.le16(20) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0x21)
            central += Self.le32(entry.crc) + Self.le32(UInt32(entry.data.count)) + Self.le32(UInt32(entry.data.count))
            central += Self.le16(UInt16(entry.name.count)) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le32(0)
            central += Self.le32(entry.offset) + entry.name
        }
        var end = Self.le32(0x06054b50) + Self.le16(0) + Self.le16(0) + Self.le16(UInt16(entries.count)) + Self.le16(UInt16(entries.count))
        end += Self.le32(UInt32(central.count)) + Self.le32(UInt32(archive.count)) + Self.le16(0)
        return archive + central + end
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
