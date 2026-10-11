#if os(macOS)
import AppKit
import Foundation

/// Word's `.docx` from styled text: paragraphs with their runs' fonts, colors and links, and
/// tables from the text's table blocks, which the system's own writer leaves out.
enum DocxWriter {
    static func data(from text: NSAttributedString) -> Data {
        var links: [String] = []
        let body = paragraphs(text, links: &links)
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)\
            <w:sectPr><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>\
            </w:body></w:document>
            """
        let relationships = links.enumerated().map { index, url in
            "<Relationship Id=\"link\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(escape(url))\" TargetMode=\"External\"/>"
        }.joined()
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
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
        return zip.data()
    }

    /// Paragraphs in order, consecutive ones in the same table gathered into `<w:tbl>`.
    private static func paragraphs(_ text: NSAttributedString, links: inout [String]) -> String {
        let string = text.string as NSString
        var out = ""
        var table: (block: NSTextTable, cells: [[Int: [String]]])?
        func flushTable() {
            guard let current = table else { return }
            out += "<w:tbl><w:tblPr><w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map {
                "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A0A0A0\"/>"
            }.joined() + "</w:tblBorders><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr>"
            let columns = max(current.block.numberOfColumns, current.cells.map { ($0.keys.max() ?? 0) + 1 }.max() ?? 1)
            out += "<w:tblGrid>" + String(repeating: "<w:gridCol/>", count: columns) + "</w:tblGrid>"
            for row in current.cells {
                out += "<w:tr>"
                for column in 0..<columns {
                    out += "<w:tc><w:tcPr/>" + (row[column]?.joined() ?? "<w:p/>") + "</w:tc>"
                }
                out += "</w:tr>"
            }
            out += "</w:tbl>"
            table = nil
        }
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let paragraph = self.paragraph(text, range, style, links: &links)
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                if table?.block !== cell.table {
                    flushTable()
                    table = (cell.table, [])
                }
                while table!.cells.count <= cell.startingRow { table!.cells.append([:]) }
                table!.cells[cell.startingRow][cell.startingColumn, default: []].append(paragraph)
            } else {
                flushTable()
                out += paragraph
            }
        }
        flushTable()
        return out
    }

    private static func paragraph(_ text: NSAttributedString, _ range: NSRange, _ style: NSParagraphStyle?, links: inout [String]) -> String {
        var properties = ""
        if let style {
            switch style.alignment {
            case .center: properties += "<w:jc w:val=\"center\"/>"
            case .right: properties += "<w:jc w:val=\"right\"/>"
            default: break
            }
            let left = Int(style.headIndent * 20), first = Int((style.firstLineHeadIndent - style.headIndent) * 20)
            if left != 0 || first != 0 { properties += "<w:ind w:left=\"\(left)\" \(first < 0 ? "w:hanging=\"\(-first)\"" : "w:firstLine=\"\(first)\"")/>" }
            properties += "<w:spacing w:before=\"\(Int(style.paragraphSpacingBefore * 20))\" w:after=\"\(Int(style.paragraphSpacing * 20))\"/>"
            if !style.tabStops.isEmpty {
                properties += "<w:tabs>" + style.tabStops.map { "<w:tab w:val=\"left\" w:pos=\"\(Int($0.location * 20))\"/>" }.joined() + "</w:tabs>"
            }
        }
        var runs = ""
        text.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            var piece = (text.string as NSString).substring(with: runRange)
            piece = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
            guard !piece.isEmpty else { return }
            var run = run(piece, attributes)
            let link = (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
            if let link {
                links.append(link)
                run = "<w:hyperlink r:id=\"link\(links.count)\">\(run)</w:hyperlink>"
            }
            runs += run
        }
        return "<w:p><w:pPr>\(properties)</w:pPr>\(runs)</w:p>"
    }

    private static func run(_ piece: String, _ attributes: [NSAttributedString.Key: Any]) -> String {
        var properties = ""
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            let name = traits.contains(.monoSpace) ? "Menlo" : (font.familyName ?? "Helvetica Neue")
            properties += "<w:rFonts w:ascii=\"\(escape(name))\" w:hAnsi=\"\(escape(name))\" w:cs=\"\(escape(name))\"/>"
            if traits.contains(.bold) { properties += "<w:b/>" }
            if traits.contains(.italic) { properties += "<w:i/>" }
            properties += "<w:sz w:val=\"\(Int((font.pointSize * 2).rounded()))\"/>"
        }
        if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) { properties += "<w:color w:val=\"\(hex(color))\"/>" }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { properties += "<w:u w:val=\"single\"/>" }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { properties += "<w:strike/>" }
        if let background = (attributes[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB), background.alphaComponent > 0.05 {
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
        for character in piece {
            switch character {
            case "\t": flush(); content += "<w:tab/>"
            case "\u{2028}", "\n": flush(); content += "<w:br/>"
            default: textRun.append(character)
            }
        }
        flush()
        return "<w:r><w:rPr>\(properties)</w:rPr>\(content)</w:r>"
    }

    /// `#rrggbb` of the color laid on white paper: Word has no transparency.
    private static func hex(_ color: NSColor) -> String {
        let a = color.alphaComponent
        func on(_ c: CGFloat) -> Int { Int(((c * a + (1 - a)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", on(color.redComponent), on(color.greenComponent), on(color.blueComponent))
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
        let data = Data(text.utf8)
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
#endif
