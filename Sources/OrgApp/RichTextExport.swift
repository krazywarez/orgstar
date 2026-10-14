import Foundation
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Word, RTF and plain text from the HTML export, through the system's HTML import, and the
/// same for the clipboard.
@MainActor
public enum RichTextExport {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The HTML export as styled text: light colors, and fonts other apps have.
    public static func attributed(html: String, directory: URL?) throws -> NSAttributedString {
        // The dark rules would turn the text white wherever the system is dark.
        let light = html.components(separatedBy: "\n").filter { !$0.contains("prefers-color-scheme: dark") }.joined(separator: "\n")
        let page = light.replacingOccurrences(of: "</head>", with: """
            <style>
            body { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; color: #222; background: #fff; }
            code, pre { font-family: Menlo, Consolas, "Courier New", monospace; }
            </style>
            </head>
            """)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        #if os(macOS)
        if let directory { options[.baseURL] = directory }
        #endif
        do {
            return try NSAttributedString(data: Data(page.utf8), options: options, documentAttributes: nil)
        } catch {
            throw Failure(description: "The text couldn't be converted: \(error.localizedDescription)")
        }
    }

    public static func rtf(_ text: NSAttributedString) throws -> Data {
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    #if os(macOS)
    /// Word's `.docx`, tables included.
    public static func docx(_ text: NSAttributedString) throws -> Data {
        DocxWriter.data(from: text)
    }
    #endif

    /// The HTML export as Word's `.docx`, with tables, heading styles and pictures.
    public static func docx(html: String, directory: URL?) throws -> Data {
        let (marked, images) = markingHeadingsAndImages(html, directory: directory)
        #if os(macOS)
        return DocxWriter.data(from: try attributed(html: marked, directory: directory), images: images)
        #else
        let (page, tables) = extractingTables(marked)
        return DocxWriter.data(from: try attributed(html: page, directory: directory), tables: tables, images: images)
        #endif
    }

    /// `html` with each heading's text starting with `DocxWriter.headingMarker` (`<h1>` the
    /// title, `<h2>` to `<h7>` Word's levels 1 to 6), and each local image replaced by
    /// `DocxWriter.imageMarker` for the pictures returned: what the system's HTML import
    /// leaves out or, on iOS, can't say.
    static func markingHeadingsAndImages(_ html: String, directory: URL?) -> (html: String, images: [DocxWriter.Image]) {
        var out = html.replacing(#/(?i)<h([1-7])\b([^>]*)>/#) { match in
            let level = Int(match.1)! - 1
            return "<h\(match.1)\(match.2)>" + DocxWriter.headingMarker(min(level, 6))
        }
        var images: [DocxWriter.Image] = []
        out = out.replacing(#/(?i)<img\b[^>]*>/#) { match in
            let tag = String(match.0)
            guard let src = tag.firstMatch(of: #/(?i)\bsrc="([^"]*)"/#).map({ decode(String($0.1)) }),
                  let image = image(src, width: tag.firstMatch(of: #/(?i)\bwidth="(\d+)/#).flatMap { Int($0.1) }, directory: directory) else { return tag }
            images.append(image)
            return DocxWriter.imageMarker(images.count - 1)
        }
        return (out, images)
    }

    /// A local image as Word takes it: PNG, JPEG or GIF as they are, other formats ImageIO
    /// reads as PNG. `width` in pixels scales it, as `#+ATTR_HTML: :width` does on the page.
    static func image(_ src: String, width: Int?, directory: URL?) -> DocxWriter.Image? {
        let url: URL
        if src.hasPrefix("file://") {
            guard let file = URL(string: src) else { return nil }
            url = file
        } else if src.contains("://") || src.hasPrefix("data:") {
            return nil
        } else {
            let path = src.removingPercentEncoding ?? src
            if path.hasPrefix("/") { url = URL(fileURLWithPath: path) } else if let directory { url = directory.appendingPathComponent(path) } else { return nil }
        }
        guard let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int, let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let (w, h) = width.map { ($0, pixelHeight * $0 / pixelWidth) } ?? (pixelWidth, pixelHeight)
        switch CGImageSourceGetType(source) as String? {
        case "public.png": return DocxWriter.Image(data: data, ext: "png", width: w, height: h)
        case "public.jpeg": return DocxWriter.Image(data: data, ext: "jpeg", width: w, height: h)
        case "com.compuserve.gif": return DocxWriter.Image(data: data, ext: "gif", width: w, height: h)
        default:
            let png = NSMutableData()
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return DocxWriter.Image(data: png as Data, ext: "png", width: w, height: h)
        }
    }

    /// `html` with each `<table>` replaced by a paragraph holding `DocxWriter.marker`, and the
    /// tables as Word XML, header cells bold.
    static func extractingTables(_ html: String) -> (html: String, tables: [String]) {
        var tables: [String] = []
        var out = ""
        var rest = Substring(html)
        while let match = rest.firstMatch(of: #/(?is)<table\b.*?</table>/#) {
            out += rest[..<match.range.lowerBound]
            var rows: [[String]] = []
            for row in match.0.matches(of: #/(?is)<tr\b[^>]*>(.*?)</tr>/#) {
                rows.append(row.1.matches(of: #/(?is)<t([hd])\b[^>]*>(.*?)</t[hd]>/#).map { cell in
                    let text = decode(String(cell.2).replacing(#/(?s)<[^>]*>/#, with: "")).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return "" }
                    return "<w:p><w:pPr></w:pPr><w:r><w:rPr>\(cell.1.lowercased() == "h" ? "<w:b/>" : "")</w:rPr><w:t xml:space=\"preserve\">\(DocxWriter.escape(text))</w:t></w:r></w:p>"
                })
            }
            out += "<p>\(DocxWriter.marker(tables.count))</p>"
            tables.append(DocxWriter.table(rows, columns: rows.map(\.count).max() ?? 1))
            rest = rest[match.range.upperBound...]
        }
        return (out + rest, tables)
    }

    /// HTML character references.
    static func decode(_ s: String) -> String {
        var out = s
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", "\u{A0}")] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        out = out.replacing(#/&#(x?)([0-9a-fA-F]+);/#) { m in
            UInt32(m.2, radix: m.1.isEmpty ? 10 : 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(m.0)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The HTML export as RTF.
    public static func rtf(html: String, directory: URL?) throws -> Data {
        try rtf(attributed(html: html, directory: directory))
    }

    /// The HTML export as plain text.
    public static func plain(html: String, directory: URL?) throws -> String {
        plain(try attributed(html: html, directory: directory))
    }

    /// The text without its styles, ending in one newline.
    public static func plain(_ text: NSAttributedString) -> String {
        text.string.replacingOccurrences(of: "\u{2028}", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// The export on the clipboard as HTML, RTF and plain text, for pasting formatted.
    public static func copy(html: String, directory: URL?) throws {
        let text = try attributed(html: html, directory: directory)
        let rtf = try rtf(text)
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString(plain(text), forType: .string)
        #else
        UIPasteboard.general.setItems([[
            "public.html": html, "public.rtf": rtf, "public.utf8-plain-text": plain(text),
        ]])
        #endif
    }
}
