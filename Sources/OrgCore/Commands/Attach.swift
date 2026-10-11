import Foundation

/// org-attach (org-attach.el, Org 9.8.7) with its defaults: where an entry's attachments are,
/// and the text changes its commands make. The file system is the caller's; `isDirectory`
/// answers for it.
public enum OrgAttach {
    /// `org-attach-id-to-path-function-list`: the uuid, timestamp and fallback folder formats.
    public static func idFolders(_ id: String) -> [String] {
        let chars = Array(id)
        guard let first = chars.first else { return [] }
        var folders: [String] = []
        if chars.count > 2 { folders.append(String(chars[..<2]) + "/" + String(chars[2...])) }
        if chars.count > 6 { folders.append(String(chars[..<6]) + "/" + String(chars[6...])) }
        folders.append("__/\(first)/\(id)")
        return folders
    }

    /// `expand-file-name` of `path` in `folder`: `.` and `..` resolved, symbolic links not.
    public static func expand(_ path: String, in folder: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (folder as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardized.path
    }

    /// `org-attach-dir-from-id`: the first folder for `id` under `idDir` that exists, or under
    /// `data/` when `idDir` is something else; with `existing` false, or when none exists, the
    /// first format's folder under `idDir`.
    public static func folder(forID id: String, idDir: String, in folder: String, existing: Bool, isDirectory: (String) -> Bool) -> String? {
        let base = expand(idDir, in: folder)
        let fallbacks = [expand("data/", in: folder)].filter { $0 != base && isDirectory($0) }
        var preferred: String?
        var first: String?
        for name in idFolders(id) where preferred == nil {
            let candidate = expand(name, in: base)
            if !existing || isDirectory(candidate) {
                preferred = candidate
            } else if first == nil {
                first = candidate
            }
            if existing, !isDirectory(candidate), let fallback = fallbacks.map({ expand(name, in: $0) }).first(where: isDirectory) {
                preferred = fallback
            }
        }
        return preferred ?? first
    }

    /// The heading index of the entry at `offset`, nil before the first heading.
    static func entry(_ model: DocumentModel, at offset: Int) -> Int? {
        model.headings.lastIndex { $0.headingRange.lowerBound <= offset }
    }

    /// `org-attach-dir` for the entry at `offset` of the file at `path`: its DIR property (or the
    /// older ATTACH_DIR), else its ID's folder. `inherit` is `org-attach-use-inheritance`: nil
    /// for `selective` (as `org-use-property-inheritance` has it), true to look in the
    /// ancestors too, false for the entry's own. Nil when there is no folder, or, unless
    /// `noFSCheck`, when the folder doesn't exist.
    public static func directory(tree: OrgTree, at offset: Int, path: String, idDir: String = "data/", inherit: Bool? = nil, noFSCheck: Bool = false, isDirectory: (String) -> Bool) -> String? {
        let model = DocumentModel(tree: tree)
        let heading = entry(model, at: offset)
        let folder = (path as NSString).deletingLastPathComponent
        func own(_ key: String, _ index: Int) -> String? {
            model.headings[index].properties.last { $0.key.uppercased() == key && !$0.additive }?.value
        }
        func value(_ key: String) -> String? {
            guard let heading else { return model.property(key, of: nil)?.value }
            switch inherit {
            case nil: return model.property(key, of: heading)?.value
            case false?: return own(key, heading)
            case true?: return ([heading] + model.ancestors(of: heading).reversed()).lazy.compactMap { own(key, $0) }.first ?? model.property(key, of: nil)?.value
            }
        }
        var dir: String?
        if let value = value("DIR") ?? value("ATTACH_DIR") {
            dir = expand(value, in: folder)
        } else if let id = value("ID"), !id.isEmpty {
            dir = Self.folder(forID: id, idDir: idDir, in: folder, existing: true, isDirectory: isDirectory)
        }
        guard let dir else { return nil }
        return noFSCheck || isDirectory(dir) ? dir : nil
    }

    /// The entry's own DIR property, which `org-attach-set-directory` starts from.
    public static func dirProperty(tree: OrgTree, at offset: Int) -> String? {
        let model = DocumentModel(tree: tree)
        guard let heading = entry(model, at: offset) else { return model.property("DIR", of: nil)?.value }
        return model.headings[heading].properties.last { $0.key.uppercased() == "DIR" && !$0.additive }?.value
    }

    /// `org-id-get` with `create`: the text with the entry's ID, made when it has none, and
    /// the ID.
    public static func ensuringID(_ text: String, at offset: Int, newID: () -> String = { UUID().uuidString.lowercased() }) -> (text: String, id: String) {
        let buffer = EmacsBuffer(text, point: min(offset, (text as NSString).length))
        return buffer.saveExcursion {
            buffer.backToHeadingOrPointMin()
            if let id = buffer.entryID() { return (text, id) }
            let id = newID()
            buffer.entryPut("ID", id)
            return (buffer.text as String, id)
        }
    }

    /// `org-attach-tag`: the text with `tag` added to or removed from the entry's heading;
    /// unchanged before the first heading.
    public static func tagging(_ text: String, at offset: Int, on: Bool, tag: String = "ATTACH", options: EditingOptions = .org) -> String {
        let tree = OrgParser.parse(text)
        let context = EditContext(revision: 0, text: text, tree: tree, selection: [offset..<offset], options: options)
        guard entryHeading(at: offset, in: tree) != nil,
              case .commit(let result) = ToggleTag(tag: tag, on: on).run(in: context) else { return text }
        return result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
    }

    /// The text with the entry's DIR property set to `dir`, or with DIR and ATTACH_DIR removed
    /// for nil (`org-attach-set-directory`, `org-attach-unset-directory`).
    public static func settingDirectory(_ text: String, at offset: Int, to dir: String?) -> String {
        let buffer = EmacsBuffer(text, point: min(offset, (text as NSString).length))
        buffer.saveExcursion {
            buffer.backToHeadingOrPointMin()
            if let dir {
                buffer.entryPut("DIR", dir)
            } else {
                buffer.entryDelete("DIR")
                buffer.backToHeadingOrPointMin()
                buffer.entryDelete("ATTACH_DIR")
            }
        }
        return buffer.text as String
    }

    /// `org-attach-file-list`: the folder's names, without `.`, `..` and names ending in `~`,
    /// sorted as `directory-files` sorts them.
    public static func fileList(_ names: [String]) -> [String] {
        names.filter { $0 != "." && $0 != ".." && !$0.hasSuffix("~") }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }
}
