import Foundation

/// Which links point at a file or one of its headings, read as `org-open-at-point` would
/// follow them: `id:`, `file:` with `::*Title` or `::#custom-id`, plain paths, and `*Title`,
/// `#custom-id` or a heading's exact title within the same file.
public enum Backlinks {
    public struct Target: Sendable, Equatable {
        public var path: String
        /// The heading, or nil for the file itself.
        public var title: String?
        public var id: String?
        public var customID: String?

        public init(path: String, title: String? = nil, id: String? = nil, customID: String? = nil) {
            self.path = path
            self.title = title
            self.id = id
            self.customID = customID
        }
    }

    /// Whether `link`, written in the file at `source`, leads to `target`.
    public static func links(_ link: String, from source: String, to target: Target, home: String = NSHomeDirectory()) -> Bool {
        let link = Links.unescape(link)
        if link.lowercased().hasPrefix("id:") {
            let id = link.dropFirst(3).components(separatedBy: "::")[0]
            return target.id.map { $0 == id } ?? false
        }
        var path: String
        var search: String
        if link.lowercased().hasPrefix("file:") {
            let parts = link.dropFirst(5).components(separatedBy: "::")
            path = parts[0]
            search = parts.dropFirst().joined(separator: "::")
        } else if ["/", "./", "../", "~/"].contains(where: link.hasPrefix) {
            let parts = link.components(separatedBy: "::")
            path = parts[0]
            search = parts.dropFirst().joined(separator: "::")
        } else if link.firstMatch(of: /^[a-zA-Z][-a-zA-Z0-9+]*:/) != nil {
            return false
        } else {
            // Within the file.
            guard source == target.path else { return false }
            path = ""
            search = link
        }
        if !path.isEmpty {
            let directory = (source as NSString).deletingLastPathComponent
            let expanded = Links.expand(path, directory: directory, home: home)
            guard (expanded as NSString).standardizingPath == (target.path as NSString).standardizingPath else { return false }
            if search.isEmpty { return target.title == nil }
        }
        guard let title = target.title else { return false }
        if search.hasPrefix("#") { return target.customID.map { "#" + $0 == search } ?? false }
        let wanted = search.hasPrefix("*") ? String(search.dropFirst()) : search
        return Links.normalizedTitle(wanted) == Links.normalizedTitle(title)
    }

    /// The line of `body` with the link to `link` in it, links shown as they read (their
    /// description, else what they link to), and the range of that link in the line. A line
    /// longer than `width` keeps the part around the link.
    public static func context(in body: String, link: String, width: Int = 160) -> (text: String, link: Range<Int>)? {
        let pattern = /\[\[((?:[^\]\\]|\\.)+)\](?:\[([^\]]*)\])?\]/
        for line in body.split(whereSeparator: \.isNewline) {
            guard line.contains("[[" + link + "]") else { continue }
            var text = ""
            var found: Range<Int>?
            var rest = Substring(line)
            while let match = rest.firstMatch(of: pattern) {
                text += rest[..<match.range.lowerBound]
                let shown = match.2.map(String.init) ?? String(match.1)
                let start = text.utf16.count
                text += shown
                if found == nil, match.1 == link { found = start..<text.utf16.count }
                rest = rest[match.range.upperBound...]
            }
            text += rest
            guard var range = found else { continue }
            // Trim, then cut to `width` around the link.
            let leading = text.prefix { $0.isWhitespace }.utf16.count
            text = text.trimmingCharacters(in: .whitespaces)
            range = (range.lowerBound - leading)..<(range.upperBound - leading)
            let ns = text as NSString
            if ns.length > width {
                let start = max(0, min(range.lowerBound - width / 3, ns.length - width))
                let end = min(ns.length, start + width)
                let lead = start > 0 ? "…" : "", trail = end < ns.length ? "…" : ""
                text = lead + ns.substring(with: NSRange(location: start, length: end - start)) + trail
                range = (range.lowerBound - start + lead.utf16.count)..<(range.upperBound - start + lead.utf16.count)
            }
            return (text, range)
        }
        return nil
    }
}
