import Foundation

/// The parts of an `.odt` file around the exported text: the content wrapper with its
/// automatic styles, `styles.xml` with the style names ox-odt (Org 9.8.7) uses, `meta.xml` and
/// the manifest. Written here rather than taken from ox-odt's templates.
enum ODTTemplate {
    static let mimetype = "application/vnd.oasis.opendocument.text"

    static let namespaces = """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
        xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
        xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
        xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
        xmlns:xlink="http://www.w3.org/1999/xlink"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
        xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0"
        xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
        xmlns:ooow="http://openoffice.org/2004/writer"
        office:version="1.2"
    """

    /// `content.xml`: table cell borders by row and column group, indented sections for tables
    /// in lists, then `body`.
    static func content(automaticStyles: String, body: String) -> String {
        let border = "0.002cm solid #000000"
        var styles = """
            <style:style style:name="OrgTable" style:family="table">
              <style:table-properties style:rel-width="96%" fo:margin-top="0cm" fo:margin-bottom="0.20cm" table:align="center"/>
            </style:style>
            <style:style style:name="OrgTableColumn" style:family="table-column">
              <style:table-column-properties style:rel-column-width="1*"/>
            </style:style>
            <style:style style:name="OrgIndexSection" style:family="section">
              <style:section-properties fo:background-color="#c0c0c0" style:editable="false"/>
            </style:style>

        """
        for sides in ["", "T", "B", "L", "TB", "TL", "BL", "TBL"] {
            func edge(_ side: Character) -> String { sides.contains(side) ? border : "none" }
            styles += """
                <style:style style:name="OrgTblCell\(sides)" style:family="table-cell">
                  <style:table-cell-properties style:vertical-align="top" fo:padding="0.159cm" fo:border-top="\(edge("T"))" fo:border-bottom="\(edge("B"))" fo:border-left="\(edge("L"))" fo:border-right="none"/>
                </style:style>

            """
        }
        for level in 0...10 {
            styles += """
                <style:style style:name="OrgIndentedSection-Level-\(level)" style:family="section">
                  <style:section-properties fo:margin-left="\(String(format: "%.3fcm", level == 0 ? 0 : 0.635 * Double(level + 1)))" fo:margin-right="0cm" style:editable="false"/>
                </style:style>

            """
        }
        styles += """
                <style:style style:name="Sect1" style:family="section">
                  <style:section-properties style:editable="false"/>
                </style:style>

            """
        let sequences = ["Table", "Illustration", "Text", "Equation", "Listing"].map {
            "<text:sequence-decl text:display-outline-level=\"2\" text:name=\"\($0)\"/>"
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content
            \(namespaces)>
              <office:automatic-styles>
            \(styles)\(automaticStyles)  </office:automatic-styles>
              <office:body>
                <office:text>

            <text:sequence-decls>
            \(sequences)
            </text:sequence-decls>\(body)
            </office:text>
              </office:body>
            </office:document-content>

            """
    }

    /// `author`, `title` and `subtitle` are XML text already.
    static func meta(author: String, date: String?, keywords: String, description: String, title: String, subtitle: String) -> String {
        let e = { ODTRenderer.escape($0) }
        var out = """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-meta
            \(namespaces)>
              <office:meta>
            <dc:creator>\(author)</dc:creator>
            <meta:initial-creator>\(author)</meta:initial-creator>

            """
        if let date { out += "<dc:date>\(date)</dc:date>\n<meta:creation-date>\(date)</meta:creation-date>\n" }
        out += "<meta:generator>orgstar</meta:generator>\n<meta:keyword>\(e(keywords))</meta:keyword>\n<dc:subject>\(e(description))</dc:subject>\n<dc:title>\(title)</dc:title>\n"
        if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "<meta:user-defined meta:name=\"subtitle\">\(subtitle)</meta:user-defined>\n"
        }
        return out + "\n  </office:meta>\n</office:document-meta>\n"
    }

    /// The manifest, which lists every part but `mimetype` (the package itself, `/`).
    static func manifest(images: [String]) -> String {
        var entries = [(mimetype, "/", " manifest:version=\"1.2\""), ("text/xml", "content.xml", ""), ("text/xml", "styles.xml", ""), ("text/xml", "meta.xml", "")]
        if !images.isEmpty { entries.append(("", "Images/", "")) }
        // ox-odt names the type after the extension.
        entries += images.map { ("image/" + ($0 as NSString).pathExtension, $0, "") }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
            \(entries.map { "<manifest:file-entry manifest:media-type=\"\($0.0)\" manifest:full-path=\"\($0.1)\"\($0.2)/>" }.joined(separator: "\n"))
            </manifest:manifest>

            """
    }

    /// `styles.xml`: headings numbered to `numbered` levels, A4 pages with 2 cm margins.
    static func styles(numbered: Int) -> String {
        func paragraph(_ name: String, display: String? = nil, parent: String? = "Standard", _ properties: String = "", text: String = "") -> String {
            var out = "  <style:style style:name=\"\(name)\" style:display-name=\"\(display ?? name)\" style:family=\"paragraph\""
            if let parent { out += " style:parent-style-name=\"\(parent)\"" }
            out += ">"
            if !properties.isEmpty { out += "<style:paragraph-properties \(properties)/>" }
            if !text.isEmpty { out += "<style:text-properties \(text)/>" }
            return out + "</style:style>\n"
        }
        func span(_ name: String, display: String? = nil, _ text: String) -> String {
            "  <style:style style:name=\"\(name)\" style:display-name=\"\(display ?? name)\" style:family=\"text\"><style:text-properties \(text)/></style:style>\n"
        }
        func graphic(_ name: String, _ properties: String) -> String {
            "  <style:style style:name=\"\(name)\" style:family=\"graphic\"><style:graphic-properties \(properties)/></style:style>\n"
        }
        let mono = "fo:font-family=\"Courier, monospace\" fo:font-size=\"10pt\""
        let body = "fo:margin-top=\"0cm\" fo:margin-bottom=\"0.212cm\""
        var styles = """
              <style:default-style style:family="paragraph"><style:paragraph-properties style:tab-stop-distance="1.251cm"/><style:text-properties fo:font-size="12pt" fo:language="en" fo:country="US"/></style:default-style>
              <style:style style:name="Standard" style:family="paragraph" style:class="text"/>

            """
        styles += paragraph("Text_20_body", display: "Text body", body)
        styles += paragraph("Text_20_body_20_bold", display: "Text body bold", parent: "Text_20_body", text: "fo:font-weight=\"bold\"")
        styles += paragraph("Heading", parent: "Standard", "fo:margin-top=\"0.423cm\" fo:margin-bottom=\"0.212cm\" fo:keep-with-next=\"always\"", text: "fo:font-size=\"14pt\"")
        let sizes = ["", "130%", "115%", "101%", "95%", "85%", "85%", "75%", "75%", "65%", "65%"]
        for level in 1...10 {
            let bold = "fo:font-size=\"\(sizes[level])\" fo:font-weight=\"bold\""
            styles += "  <style:style style:name=\"Heading_20_\(level)\" style:display-name=\"Heading \(level)\" style:family=\"paragraph\" style:parent-style-name=\"Heading\" style:next-style-name=\"Text_20_body\" style:default-outline-level=\"\(level)\" style:class=\"text\"><style:text-properties \(bold)/></style:style>\n"
            styles += "  <style:style style:name=\"Heading_20_\(level)_unnumbered\" style:display-name=\"Heading \(level) unnumbered\" style:family=\"paragraph\" style:parent-style-name=\"Heading_20_\(level)\" style:class=\"text\"/>\n"
        }
        styles += paragraph("OrgTitle", "fo:text-align=\"center\" fo:margin-bottom=\"0.212cm\"", text: "fo:font-size=\"24pt\" fo:font-weight=\"bold\"")
        styles += paragraph("OrgSubtitle", "fo:text-align=\"center\" fo:margin-bottom=\"0.212cm\"", text: "fo:font-size=\"14pt\"")
        styles += paragraph("Quotations", parent: "Text_20_body", "fo:margin-left=\"1cm\" fo:margin-right=\"1cm\"")
        styles += paragraph("OrgCenter", parent: "Text_20_body", "fo:text-align=\"center\"")
        styles += paragraph("OrgVerse", parent: "Text_20_body", "fo:margin-left=\"1cm\"")
        styles += paragraph("OrgSrcBlock", parent: "Standard", "fo:margin-top=\"0cm\" fo:margin-bottom=\"0cm\" fo:background-color=\"#f0f0f0\"", text: mono)
        styles += paragraph("OrgSrcBlockLastLine", parent: "OrgSrcBlock", "fo:margin-bottom=\"0.212cm\"")
        styles += paragraph("OrgFixedWidthBlock", parent: "Standard", "fo:margin-top=\"0cm\" fo:margin-bottom=\"0cm\" fo:background-color=\"#f0f0f0\"", text: mono)
        styles += paragraph("OrgFixedWidthBlockLastLine", parent: "OrgFixedWidthBlock", "fo:margin-bottom=\"0.212cm\"")
        styles += paragraph("Footnote", parent: "Standard", "fo:margin-left=\"0.5cm\" fo:text-indent=\"-0.5cm\"", text: "fo:font-size=\"10pt\"")
        styles += paragraph("OrgFootnoteCenter", parent: "Footnote", "fo:text-align=\"center\"")
        styles += paragraph("OrgFootnoteQuotations", parent: "Footnote", "fo:margin-left=\"1cm\" fo:margin-right=\"1cm\"")
        styles += paragraph("Table_20_Contents", display: "Table Contents", parent: "Standard")
        for (name, align) in [("Left", "start"), ("Right", "end"), ("Center", "center")] {
            styles += paragraph("OrgTableContents\(name)", parent: "Table_20_Contents", "fo:text-align=\"\(align)\"")
            styles += paragraph("OrgTableHeading\(name)", parent: "Table_20_Contents", "fo:text-align=\"\(align)\"", text: "fo:font-weight=\"bold\"")
        }
        styles += paragraph("Contents_20_Heading", display: "Contents Heading", parent: "Heading", text: "fo:font-size=\"16pt\" fo:font-weight=\"bold\"")
        for level in 1...10 {
            styles += paragraph("Contents_20_\(level)", display: "Contents \(level)", parent: "Standard", "fo:margin-left=\"\(String(format: "%.3f", 0.499 * Double(level - 1)))cm\"")
        }
        styles += paragraph("Horizontal_20_Line", display: "Horizontal Line", parent: "Standard", "fo:margin-bottom=\"0.5cm\" fo:border-bottom=\"0.002cm solid #808080\"")
        styles += paragraph("Caption", parent: "Standard", "fo:margin-top=\"0.212cm\" fo:margin-bottom=\"0.212cm\"", text: "fo:font-style=\"italic\" fo:font-size=\"10pt\"")
        for name in ["Illustration", "Table", "Listing"] { styles += paragraph(name, parent: "Caption") }
        styles += span("Emphasis", "fo:font-style=\"italic\"")
        styles += span("Bold", "fo:font-weight=\"bold\"")
        styles += span("Underline", "style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"")
        styles += span("Strikethrough", "style:text-line-through-style=\"solid\"")
        styles += span("OrgCode", mono)
        styles += span("OrgSubscript", "style:text-position=\"sub 58%\"")
        styles += span("OrgSuperscript", "style:text-position=\"super 58%\"")
        styles += span("OrgTodo", "fo:color=\"#b00000\" fo:font-weight=\"bold\"")
        styles += span("OrgDone", "fo:color=\"#008000\" fo:font-weight=\"bold\"")
        styles += span("OrgTags", "fo:font-size=\"85%\"")
        styles += span("OrgTag", "fo:font-weight=\"bold\"")
        styles += span("OrgPriority", "fo:font-weight=\"bold\"")
        for priority in ["A", "B", "C"] { styles += span("OrgPriority-\(priority)", "fo:font-weight=\"bold\"") }
        styles += span("OrgActiveTimestamp", "fo:color=\"#555555\"")
        styles += span("OrgInactiveTimestamp", "fo:color=\"#888888\"")
        styles += span("Internet_20_link", display: "Internet link", "fo:color=\"#000080\" style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"")
        styles += graphic("OrgDisplayImage", "style:wrap=\"none\" style:vertical-pos=\"top\" style:vertical-rel=\"paragraph\" style:horizontal-pos=\"center\" style:horizontal-rel=\"paragraph\"")
        styles += graphic("OrgInlineImage", "style:vertical-pos=\"middle\" style:vertical-rel=\"text\"")
        styles += graphic("OrgCaptionedImage", "style:wrap=\"none\" style:vertical-pos=\"top\" style:vertical-rel=\"paragraph\" style:horizontal-pos=\"center\" style:horizontal-rel=\"paragraph\"")
        styles += graphic("OrgImageCaptionFrame", "style:wrap=\"none\" style:vertical-pos=\"top\" style:vertical-rel=\"paragraph\" style:horizontal-pos=\"center\" style:horizontal-rel=\"paragraph\" fo:padding=\"0cm\" fo:border=\"none\"")
        func list(_ name: String, _ level: (Int) -> String) -> String {
            "  <text:list-style style:name=\"\(name)\">\n" + (1...10).map(level).joined() + "  </text:list-style>\n"
        }
        func position(_ level: Int) -> String {
            let indent = String(format: "%.3fcm", 0.635 * Double(level))
            return "<style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" text:list-tab-stop-position=\"\(indent)\" fo:text-indent=\"-0.635cm\" fo:margin-left=\"\(indent)\"/></style:list-level-properties>"
        }
        styles += list("OrgBulletedList") { "    <text:list-level-style-bullet text:level=\"\($0)\" text:bullet-char=\"•\">\(position($0))</text:list-level-style-bullet>\n" }
        styles += list("OrgNumberedList") { "    <text:list-level-style-number text:level=\"\($0)\" style:num-suffix=\".\" style:num-format=\"1\">\(position($0))</text:list-level-style-number>\n" }
        styles += list("OrgDescriptionList") { "    <text:list-level-style-number text:level=\"\($0)\" style:num-format=\"\">\(position($0))</text:list-level-style-number>\n" }
        styles += list("OrgSrcBlockNumberedLine") { "    <text:list-level-style-number text:level=\"\($0)\" style:num-suffix=\" \" style:num-format=\"1\">\(position($0))</text:list-level-style-number>\n" }
        styles += "  <text:outline-style style:name=\"Outline\">\n"
        for level in 1...10 {
            let format = level <= numbered ? "style:num-format=\"1\" style:num-suffix=\".\" text:display-levels=\"\(level)\"" : "style:num-format=\"\""
            styles += "    <text:outline-level-style text:level=\"\(level)\" \(format)><style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"space\"/></style:list-level-properties></text:outline-level-style>\n"
        }
        styles += "  </text:outline-style>\n"
        styles += "  <text:notes-configuration text:note-class=\"footnote\" style:num-format=\"1\" text:start-value=\"0\" text:footnotes-position=\"page\" text:start-numbering-at=\"document\"/>\n"
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-styles
            \(namespaces)>
              <office:styles>
            \(styles)  </office:styles>
              <office:automatic-styles>
                <style:page-layout style:name="OrgPage"><style:page-layout-properties fo:page-width="21cm" fo:page-height="29.7cm" style:print-orientation="portrait" fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" fo:margin-right="2cm"/></style:page-layout>
              </office:automatic-styles>
              <office:master-styles>
                <style:master-page style:name="Standard" style:page-layout-name="OrgPage"/>
              </office:master-styles>
            </office:document-styles>

            """
    }
}
