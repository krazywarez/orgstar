import Foundation
import OrgCore

/// Publishing directories chosen in a folder picker, by project name. On iOS the app can write
/// only to folders it was given, so a project whose `publishing-directory` is outside the
/// app's folders publishes to the folder chosen for it instead. Kept as bookmarks.
@MainActor
public final class PublishFolders {
    public static let shared = PublishFolders()
    static let key = "publishFolders"

    private let defaults: UserDefaults
    private let sandboxed: Bool
    /// The chosen folders by project name, with access started.
    private var folders: [String: URL] = [:]

    init(defaults: UserDefaults = .standard, sandboxed: Bool = Sandbox.isActive) {
        self.defaults = defaults
        self.sandboxed = sandboxed
        let saved = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        var kept = saved
        for (name, data) in saved {
            guard let (url, renewed) = SecurityBookmark.resolve(data, sandboxed: sandboxed) else { continue }
            folders[name] = url
            if let renewed { kept[name] = renewed }
        }
        if kept != saved { defaults.set(kept, forKey: Self.key) }
    }

    /// The folder chosen for `project`, if any.
    public func folder(for project: String) -> URL? { folders[project] }

    /// Keeps `url`, a folder from a folder picker, as where `project` publishes; making its bookmark
    /// starts access. False when the bookmark can't be made, so it lasts only until the app quits.
    @discardableResult
    public func set(_ url: URL, for project: String) -> Bool {
        folders[project] = url
        guard let data = SecurityBookmark.make(url, sandboxed: sandboxed) else { return false }
        var saved = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        saved[project] = data
        defaults.set(saved, forKey: Self.key)
        return true
    }

    /// `projects`, each publishing to the folder chosen for it where there is one.
    public func applied(to projects: [PublishProject]) -> [PublishProject] {
        projects.map { project in
            var project = project
            if let folder = folders[project.name] { project.publishingDirectory = folder.path }
            return project
        }
    }

    /// The projects among `projects` (expanded from projects of projects) that publish outside
    /// `roots` with no folder chosen for them.
    public func needed(_ projects: [PublishProject], all: [PublishProject], roots: [String]) throws -> [PublishProject] {
        try Publish.expand(projects, all: all).filter { project in
            folders[project.name] == nil
                && !roots.contains { FolderGrants.covers(URL(fileURLWithPath: $0), URL(fileURLWithPath: project.publishingDirectory)) }
        }
    }
}
