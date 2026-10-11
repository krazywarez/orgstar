import Foundation

/// What an export covers and where it goes, as Org's export dispatcher decides them: the whole
/// file or the subtree at point (`org-export-as` with SUBTREEP), and `#+EXPORT_FILE_NAME` or
/// the subtree's `EXPORT_FILE_NAME` (`org-export-output-file-name`).
public enum ExportScope {
    /// Subtree properties that stand in for the file's keywords, as `org-export-options-alist`
    /// and the backends' options name them.
    static let overrides: [(property: String, keyword: String)] = [
        ("EXPORT_TITLE", "TITLE"), ("EXPORT_AUTHOR", "AUTHOR"), ("EXPORT_DATE", "DATE"), ("EXPORT_EMAIL", "EMAIL"),
        ("EXPORT_OPTIONS", "OPTIONS"), ("EXPORT_SELECT_TAGS", "SELECT_TAGS"), ("EXPORT_EXCLUDE_TAGS", "EXCLUDE_TAGS"),
        ("EXPORT_HTML_HEAD", "HTML_HEAD"), ("EXPORT_HTML_HEAD_EXTRA", "HTML_HEAD_EXTRA"),
    ]

    /// The subtree containing `offset` as a document of its own: the file's keyword lines, then
    /// the heading's title as `#+TITLE` and its `EXPORT_*` properties as keywords, then the
    /// heading's body without its planning line and property drawer, its children promoted so
    /// the first is level 1. Nil before the first heading.
    public static func subtree(_ text: String, at offset: Int, settings: OrgSettings = .default) -> String? {
        let tree = OrgParser.parse(text, defaults: settings)
        let model = DocumentModel(tree: tree)
        guard let index = model.headings.lastIndex(where: { $0.headingRange.lowerBound <= offset }) else { return nil }
        let heading = model.headings[index]
        let ns = text as NSString
        let end = model.headings[(index + 1)...].first { $0.level <= heading.level }?.headingRange.lowerBound ?? ns.length
        let bodyStart = NSMaxRange(ns.lineRange(for: NSRange(location: heading.headingRange.lowerBound, length: 0)))
        var body = bodyStart < end ? ns.substring(with: NSRange(location: bodyStart, length: end - bodyStart)) : ""
        body = body.replacing(#/^(?:[ \t]*(?:SCHEDULED|DEADLINE|CLOSED):[^\n]*\n)?(?:[ \t]*:PROPERTIES:[ \t]*\n(?:[^\n]*\n)*?[ \t]*:END:[ \t]*(?:\n|$))?/#, with: "", maxReplacements: 1)
        body = ExportPreprocess.shift(body, to: 1)

        var lines = preamble(tree)
        let property = { (key: String) in heading.properties.last { $0.key.uppercased() == key }?.value }
        lines.append("#+TITLE: " + (property("EXPORT_TITLE") ?? Links.displayFormat(heading.title).trimmingCharacters(in: .whitespaces)))
        for (key, keyword) in overrides where key != "EXPORT_TITLE" {
            if let value = property(key) { lines.append("#+\(keyword): \(value)") }
        }
        return lines.joined(separator: "\n") + "\n" + body
    }

    /// The export's name: the subtree's `EXPORT_FILE_NAME` property when exporting the subtree
    /// at `offset`, else the file's last `#+EXPORT_FILE_NAME`; nil when neither is set.
    public static func fileName(_ text: String, subtreeAt offset: Int? = nil, settings: OrgSettings = .default) -> String? {
        let tree = OrgParser.parse(text, defaults: settings)
        if let offset {
            let model = DocumentModel(tree: tree)
            if let index = model.headings.lastIndex(where: { $0.headingRange.lowerBound <= offset }),
               let name = model.headings[index].properties.last(where: { $0.key.uppercased() == "EXPORT_FILE_NAME" })?.value, !name.isEmpty {
                return name
            }
        }
        var name: String?
        for line in (settings.setupKeywords.split(separator: "\n").map(String.init) + preamble(tree)) {
            if let m = line.firstMatch(of: #/(?i)^#\+EXPORT_FILE_NAME:[ \t]*(.*?)[ \t]*$/#), !m.1.isEmpty { name = String(m.1) }
        }
        return name
    }

    /// Where the export of `source` is written: `name` (relative to the source's folder, `~`
    /// expanded) with its extension replaced by `ext`, or the source's name with `ext`.
    public static func output(for source: URL, name: String?, extension ext: String) -> URL {
        guard let name, !name.isEmpty else { return source.deletingPathExtension().appendingPathExtension(ext) }
        let expanded = (name as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : source.deletingLastPathComponent().appendingPathComponent(expanded)
        return url.deletingPathExtension().appendingPathExtension(ext).standardizedFileURL
    }

    /// The keyword lines before the first heading.
    static func preamble(_ tree: OrgTree) -> [String] {
        tree.root.children.filter { $0.kind == .zerothSection }
            .flatMap { $0.children.filter { $0.kind == .keyword } }
            .map { $0.text.trimmingCharacters(in: .newlines) }
    }
}
