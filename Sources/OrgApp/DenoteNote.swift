import Foundation
import OrgCore

/// A new Denote note, as `denote` makes it: `IDENTIFIER==signature--title__keywords.org` in
/// `denote-directory` or a folder under it, starting with the Org front matter and then the
/// template.
public enum DenoteNote {
    /// `denote-directory`: the setting, else the first folder.
    public static func directory(roots: [String], defaults: UserDefaults = .standard) -> String? {
        let denote = OrgPreferences.denoteDirectory(defaults)
        return denote.isEmpty ? roots.first : OrgAttach.expand(denote, in: roots.first ?? NSHomeDirectory())
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

    /// Makes the note's file in `folder`. Its identifier is `now`'s, or as
    /// `denote-generate-identifier-as-date` does, the first second after it no file under
    /// `root` has; the front matter keeps `now`. Fails rather than replace a file.
    public static func create(
        title: String, keywords: [String], in folder: String, root: String? = nil, now: Date = Date(), signature: String = "", template: String = ""
    ) throws -> (path: String, id: String) {
        let used = identifiers(under: root ?? folder)
        var stamp = now
        while used.contains(Denote.identifier(for: stamp)) { stamp += 1 }
        let id = Denote.identifier(for: stamp)
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
