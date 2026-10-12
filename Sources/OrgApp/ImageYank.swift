import Foundation
import OrgCore

/// Org 9.7's `yank-media` and drag-and-drop handlers (org.el, Org 9.8.7): a pasted image saved
/// as `org-yank-image-save-method` says, dropped files handled as `org-yank-dnd-method` says,
/// and their links inserted at the caret. Two differences from Org: links have no
/// description, and each goes on a line of its own, so they show as inline images.
public enum ImageYank {
    /// `org-yank-image-save-method`: an attachment of the entry, or a file in a folder,
    /// relative to the org file's folder unless absolute.
    public enum SaveMethod: Equatable, Sendable {
        case attach
        case directory(String)

        public init(_ value: String) {
            self = value.isEmpty || value == "attach" ? .attach : .directory(value)
        }
    }

    /// `org-yank-dnd-method`.
    public enum DropMethod: String, Sendable {
        case attach, open, fileLink = "file-link", ask
    }

    /// `org-yank-image-autogen-filename` with the extension: `clipboard-20261011T232238.png`.
    /// Org's `.%6N` is the part `file-name-with-extension` replaces, so it never shows.
    public static func fileName(ext: String, date: Date = Date(), prefix: String = "clipboard") -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd'T'HHmmss"
        return "\(prefix)-\(format.string(from: date)).\(ext)"
    }

    /// `name`, or `name-2`, `name-3`… before the extension, whichever `dir` doesn't have yet.
    static func unused(_ name: String, in dir: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(candidate)) {
            candidate = "\(base)-\(n)" + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
        return candidate
    }

    /// A `file:` link to `path` from the org file at `orgPath`: relative when it's under the
    /// file's folder, else absolute with `~` for the home folder.
    static func fileLink(_ path: String, from orgPath: String) -> String {
        let folder = (orgPath as NSString).deletingLastPathComponent + "/"
        let target = path.hasPrefix(folder) ? String(path.dropFirst(folder.count)) : (path as NSString).abbreviatingWithTildeInPath
        return "[[file:\(target)]]"
    }

    /// The folder a `directory` method names, made if missing.
    static func folder(_ dir: String, for entry: Attachments.Entry) throws -> String {
        let folder = OrgAttach.expand((dir as NSString).expandingTildeInPath, in: (entry.path as NSString).deletingLastPathComponent)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `org--image-yank-media-handler`: `data` saved with extension `ext`; the link to it.
    public static func save(_ data: Data, ext: String, method: SaveMethod, in entry: inout Attachments.Entry,
                            date: Date = Date(), prefix: String = "clipboard") throws -> String {
        switch method {
        case .attach:
            let dir = try Attachments.directoryCreating(&entry)
            let name = unused(fileName(ext: ext, date: date, prefix: prefix), in: dir)
            try Attachments.attach(data, named: name, to: &entry)
            return "[[attachment:\(name)]]"
        case .directory(let dir):
            let folder = try folder(dir, for: entry)
            let file = (folder as NSString).appendingPathComponent(unused(fileName(ext: ext, date: date, prefix: prefix), in: folder))
            try data.write(to: URL(fileURLWithPath: file))
            return fileLink(file, from: entry.path)
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "tif", "tiff", "bmp", "heic", "avif"]

    /// `org--dnd-attach-file` and the `file-link` case of `org--dnd-local-file-handler` for
    /// each file; `.open` and `.ask` are the caller's. With `attach`, an image goes to the
    /// save method's folder when that is a directory, as Org does. The links, in order.
    public static func drop(_ files: [URL], method: DropMethod, attachMethod: Attachments.Method, saveMethod: SaveMethod,
                            in entry: inout Attachments.Entry) throws -> [String] {
        try files.map { file in
            switch method {
            case .fileLink, .open, .ask:
                return fileLink(file.standardizedFileURL.path, from: entry.path)
            case .attach:
                if case .directory(let dir) = saveMethod, imageExtensions.contains(file.pathExtension.lowercased()) {
                    let folder = try folder(dir, for: entry)
                    let target = (folder as NSString).appendingPathComponent(file.lastPathComponent)
                    let files = FileManager.default
                    switch attachMethod {
                    case .mv: try files.moveItem(atPath: file.path, toPath: target)
                    case .cp: try files.copyItem(atPath: file.path, toPath: target)
                    case .ln: try files.linkItem(atPath: file.path, toPath: target)
                    case .lns: try files.createSymbolicLink(atPath: target, withDestinationPath: file.path)
                    }
                    return fileLink(target, from: entry.path)
                }
                return "[[\(try Attachments.attach(file, method: attachMethod, to: &entry).link)]]"
            }
        }
    }

    /// `text` with `links` inserted at `offset`, one per line: a line break goes before them
    /// when the line has text before the caret, and after them when it has text after. The
    /// caret after the last link.
    public static func inserting(_ links: [String], into text: String, at offset: Int) -> (text: String, caret: Int) {
        let ns = text as NSString
        let offset = min(max(offset, 0), ns.length)
        let line = ns.lineRange(for: NSRange(location: offset, length: 0))
        var contentEnd = NSMaxRange(line)
        while contentEnd > line.location, [0x0A, 0x0D].contains(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let before = ns.substring(with: NSRange(location: line.location, length: offset - line.location))
        let after = offset < contentEnd ? ns.substring(with: NSRange(location: offset, length: contentEnd - offset)) : ""
        let lead = before.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
        let trail = after.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
        let body = lead + links.joined(separator: "\n")
        let new = ns.replacingCharacters(in: NSRange(location: offset, length: 0), with: body + trail)
        return (new, offset + (body as NSString).length)
    }

    /// `offset` in `old` moved to where it is in `new`, for a change that touched one span;
    /// text inserted at `offset`, such as a property drawer, ends up before it.
    public static func map(_ offset: Int, from old: String, to new: String) -> Int {
        guard let edit = TextEdit.between(old, new).first else { return offset }
        if offset < edit.range.lowerBound { return offset }
        let delta = (new as NSString).length - (old as NSString).length
        return max(offset, edit.range.upperBound) + delta
    }
}
