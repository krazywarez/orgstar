import Foundation
import OrgCore

/// A new Denote note, as `denote` makes it: `IDENTIFIER==signature--title__keywords.org` in
/// `denote-directory` or a folder under it, starting with the Org front matter and then the
/// template.
public enum DenoteNote {
    /// `denote-directories`: the folders of `denote-directory`, separated by `:`, else the
    /// first sidebar folder.
    public static func directories(roots: [String], defaults: UserDefaults = .standard) -> [String] {
        let folders = paths(OrgPreferences.denoteDirectory(defaults), roots: roots)
        return folders.isEmpty ? Array(roots.prefix(1)) : folders
    }

    /// The folder new notes go in: the first of `denote-directory`.
    public static func directory(roots: [String], defaults: UserDefaults = .standard) -> String? {
        directories(roots: roots, defaults: defaults).first
    }

    /// `denote-silo-directories`, separated by `:`; by default `denote-directory`'s folders.
    public static func silos(roots: [String], defaults: UserDefaults = .standard) -> [String] {
        let silos = paths(OrgPreferences.denoteSiloDirectories(defaults), roots: roots)
        return silos.isEmpty ? directories(roots: roots, defaults: defaults) : silos
    }

    static func paths(_ setting: String, roots: [String]) -> [String] {
        setting.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { OrgAttach.expand($0, in: roots.first ?? NSHomeDirectory()) }
    }

    /// A folder as the folder prompts show it, under `~` when it's in the home folder.
    public static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The `subdirectory` prompt's choices and their folders: `.` and the folders under the
    /// one root, relative to it, or with several roots, each root and its folders in full.
    public static func folderChoices(_ roots: [String]) -> [(label: String, path: String)] {
        if roots.count == 1, let root = roots.first {
            return [(".", root)] + subdirectories(of: root).map { ($0, (root as NSString).appendingPathComponent($0)) }
        }
        return roots.flatMap { root in
            [root] + subdirectories(of: root).map { (root as NSString).appendingPathComponent($0) }
        }.map { (abbreviated($0), $0) }
    }

    /// `denote-directory-subdirectories`: the folders under `root`, relative to it, without
    /// hidden ones.
    public static func subdirectories(of root: String) -> [String] {
        let url = URL(fileURLWithPath: root)
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [String] = []
        for case let item as URL in walk where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            found.append(String(item.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1)))
        }
        return found.sorted()
    }

    /// The identifiers in the names of the files under `root`.
    static func identifiers(under root: String) -> Set<String> {
        guard let walk = FileManager.default.enumerator(atPath: root) else { return [] }
        var found = Set<String>()
        for case let path as String in walk { if let id = Denote.identifier(ofFile: path) { found.insert(id) } }
        return found
    }

    /// `denote-generate-identifier-as-date`: `date`'s identifier, or the first second after it
    /// no file under `roots` has.
    public static func unusedIdentifier(_ date: Date, roots: [String]) -> String {
        let used = roots.reduce(into: Set<String>()) { $0.formUnion(identifiers(under: $1)) }
        var stamp = date
        while used.contains(Denote.identifier(for: stamp)) { stamp += 1 }
        return Denote.identifier(for: stamp)
    }

    /// `denote-rename-file` of the file at `path` with `text`: its new path and text, the
    /// keywords sorted, the identifier kept (or for a file without one, its modification
    /// time's, unused under `roots`), the front matter rewritten or, without one, added.
    /// A nil `date` keeps the front matter's.
    public static func renaming(
        _ path: String, text: String, title: String, keywords: [String], signature: String, date: Date?, roots: [String]
    ) -> (path: String, text: String) {
        let name = Denote.name(ofFile: path), front = Denote.frontMatter(of: text)
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        let identifier = name.identifier ?? front.identifier ?? unusedIdentifier(date ?? modified, roots: roots)
        let keywords = Denote.keywords(keywords), signature = Denote.signature(signature)
        let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(
            Denote.fileName(identifier: identifier, signature: signature, title: title, keywords: keywords, extension: name.ext.isEmpty ? "org" : name.ext))
        guard name.ext == "org" || name.ext.isEmpty else { return (target, text) }
        return (target, Denote.rewritingFrontMatter(text, title: title, keywords: keywords, signature: signature, date: date, identifier: identifier, now: date ?? modified))
    }

    /// Makes the note's file in `folder`. Its identifier is `now`'s, or as
    /// `denote-generate-identifier-as-date` does, the first second after it no file under
    /// `roots` (by default `folder`) has; the front matter keeps `now`. Fails rather than
    /// replace a file.
    public static func create(
        title: String, keywords: [String], in folder: String, roots: [String] = [], now: Date = Date(), signature: String = "", template: String = ""
    ) throws -> (path: String, id: String) {
        let id = unusedIdentifier(now, roots: roots.isEmpty ? [folder] : roots)
        let keywords = Denote.keywords(keywords)
        let signature = Denote.signature(signature)
        let name = Denote.fileName(identifier: id, signature: signature, title: title, keywords: keywords)
        let path = (folder as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: path) else { throw Dailies.Failure("\(name) is already there") }
        let text = Denote.frontMatter(title: title, date: now, keywords: keywords, identifier: id, signature: signature) + template
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        return (path, id)
    }
}
