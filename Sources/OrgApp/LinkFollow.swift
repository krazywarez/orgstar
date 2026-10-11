import Foundation
import OrgCore

/// What following a link comes to.
public enum LinkFollow: Equatable, Sendable {
    /// Shown in Orgstar: a buffer opened or a heading revealed.
    case shown
    /// For the system to open: a web or mail address, or a file Orgstar doesn't edit.
    case openExternally(URL)
    case message(String)
}

extension DocumentSession {
    /// Follows a link as `org-link-open` does: files open as buffers (with a `::` search),
    /// `id:` links through the index, internal and radio links in the current file,
    /// `attachment:` links in their entry's attachment folder, and web and mail links go to
    /// their apps.
    public func follow(_ link: OrgLink, workspace: WorkspaceModel?, isText: (String) -> Bool) -> LinkFollow {
        switch link.type {
        case "http", "https", "ftp", "mailto", "news":
            return Self.url(link.raw)
        case "doi":
            return Self.url("https://doi.org/" + link.path)
        case "file":
            return followFile(link, isText: isText)
        case "id":
            guard let location = try? workspace?.index.headings(withID: link.path).first else {
                return .message("No heading has the ID \(link.path)")
            }
            show(location)
            return .shown
        case "custom-id":
            return searchCurrent("#" + link.path)
        case "fuzzy":
            return searchCurrent(link.path)
        case "radio":
            guard let document else { return .message("No file is open") }
            return shown(Links.searchRadio(link.path, tree: document.tree))
        case "attachment":
            guard let tree = document?.tree,
                  let file = Links.attachmentFile(link, tree: tree, path: path, idDir: OrgPreferences.attachIDDir(), inherit: OrgPreferences.attachUseInheritance(), isDirectory: Self.isDirectory) else {
                return .message("Need absolute `org-attach-id-dir' to attach in buffers without filename")
            }
            return followFile(file, isText: isText)
        case "coderef":
            return searchCurrent("(" + link.path + ")")
        case "shell", "elisp":
            return .message("orgstar doesn't run \(link.type) links")
        default:
            return .message("orgstar can't open \(link.type) links")
        }
    }

    static func url(_ string: String) -> LinkFollow {
        let allowed = CharacterSet.urlFragmentAllowed.union(.urlQueryAllowed).union(CharacterSet(charactersIn: "#%"))
        guard let url = URL(string: string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string) else {
            return .message("Not a link orgstar can open: \(string)")
        }
        return .openExternally(url)
    }

    /// A file link's path against the open file's folder, as Org resolves relative links.
    public static func resolve(_ path: String, from current: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        let folder = current.map { ($0 as NSString).deletingLastPathComponent } ?? NSHomeDirectory()
        return ((folder as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    private func followFile(_ link: OrgLink, isText: (String) -> Bool) -> LinkFollow {
        let target = link.path.isEmpty ? (path ?? "") : Self.resolve(link.path, from: path)
        guard FileManager.default.fileExists(atPath: target) else { return .message("No file \(target)") }
        guard Self.isOrgPath(target) || isText(target) else { return .openExternally(URL(fileURLWithPath: target)) }
        open(target)
        guard let option = link.searchOption, !option.isEmpty else { return .shown }
        if let line = Int(option), let text = document?.text {
            let ns = text as NSString
            var offset = 0
            for _ in 1..<max(1, line) where offset < ns.length { offset = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0))) }
            reveal(offset)
            return .shown
        }
        return searchCurrent(option)
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func searchCurrent(_ s: String) -> LinkFollow {
        guard let document else { return .message("No file is open") }
        return shown(Links.search(s, text: document.text, tree: document.tree))
    }

    private func shown(_ result: Links.SearchResult) -> LinkFollow {
        switch result {
        case .found(let offset):
            reveal(offset)
            return .shown
        case .failed(let message):
            return .message(message)
        case .occur(let regexp):
            // The first match; the Mac's editor shows the sparse tree.
            guard let text = document?.text, let matches = try? SparseTree.occur(regexp, in: text) else { return .message("Invalid regexp: \(regexp)") }
            if let first = matches.points.first { reveal(first) }
            return .message("\(matches.points.count) match(es) for regexp \(regexp)")
        }
    }
}
