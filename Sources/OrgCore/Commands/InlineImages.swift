import Foundation

/// Image links shown as images (`org-display-inline-images`, Org 9.8.7): a line that is only a
/// `file:` or `attachment:` link to an image, without a description, and the width
/// `#+ATTR_ORG: :width` asks for.
public enum InlineImages {
    public struct Image: Sendable, Equatable {
        public let path: String
        public let width: Int?
    }

    static let extensions = "png|jpe?g|gif|svg|webp|tiff?|bmp|heic|avif"
    static let pattern = try! NSRegularExpression(pattern: "^[ \\t]*\\[\\[(?:file:)?([^\\]\\n]+\\.(?:\(extensions)))\\]\\][ \\t]*$", options: .caseInsensitive)

    /// The image on the line at `lineStart`, if the line is an image link; with `remote`,
    /// http and https links too (`org-display-remote-inline-images` other than `skip`).
    /// `attachment` gives an `attachment:` link's file from its name and offset, as
    /// `org-attach-expand` does; without it those links don't show.
    public static func image(atLine lineStart: Int, in text: NSString, remote: Bool = false, attachment: ((String, Int) -> String?)? = nil) -> Image? {
        let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let content = text.substring(with: line).trimmingCharacters(in: .newlines)
        guard let m = pattern.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) else { return nil }
        var path = (content as NSString).substring(with: m.range(at: 1))
        if path.hasPrefix("attachment:") {
            guard let file = attachment?(String(path.dropFirst("attachment:".count)), line.location) else { return nil }
            path = file
        }
        if path.contains("://") {
            guard remote, path.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        }
        // `#+ATTR_ORG: :width N` in the affiliated keywords above.
        var width: Int?
        var at = line.location
        while at > 0 {
            let previous = text.lineRange(for: NSRange(location: at - 1, length: 0))
            let keyword = text.substring(with: previous)
            guard keyword.range(of: "^[ \\t]*#\\+[A-Za-z_]+:", options: .regularExpression) != nil else { break }
            if width == nil, let w = keyword.firstMatch(of: /(?i)^[ \t]*#\+ATTR_ORG:.*:width[ \t]+([0-9]+)/) { width = Int(w.1) }
            at = previous.location
        }
        return Image(path: path, width: width)
    }

    /// `#+STARTUP: inlineimages` or `noinlineimages`, if the file says.
    public static func startup(_ tree: OrgTree) -> Bool? {
        var shown: Bool?
        for word in tree.settings.startup {
            if word.lowercased() == "inlineimages" { shown = true }
            if word.lowercased() == "noinlineimages" { shown = false }
        }
        return shown
    }
}
