import Foundation
import OrgCore

/// A new Denote note, as `denote` makes it with the default `denote-prompts` (title and
/// keywords): `IDENTIFIER--title__keywords.org` in `denote-directory`, starting with the
/// Org front matter.
public enum DenoteNote {
    /// `denote-directory`: the setting, else the first folder.
    public static func directory(roots: [String], defaults: UserDefaults = .standard) -> String? {
        let denote = OrgPreferences.denoteDirectory(defaults)
        return denote.isEmpty ? roots.first : OrgAttach.expand(denote, in: roots.first ?? NSHomeDirectory())
    }

    /// Makes the note's file in `folder`. Fails rather than replace a file that's there.
    public static func create(title: String, keywords: [String], in folder: String, now: Date = Date()) throws -> (path: String, id: String) {
        let id = Denote.identifier(for: now)
        let keywords = Denote.keywords(keywords)
        let name = Denote.fileName(identifier: id, title: title, keywords: keywords)
        let path = (folder as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: path) else { throw Dailies.Failure("\(name) is already there") }
        let text = Denote.frontMatter(title: title, date: now, keywords: keywords, identifier: id)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        return (path, id)
    }
}
