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
}
