import Foundation
import OrgCore

/// Bookmarks that give access back after relaunch: security-scoped in the Mac sandbox, plain
/// elsewhere.
public enum SecurityBookmark {
    public static func make(_ url: URL, sandboxed: Bool = Sandbox.isActive) -> Data? {
        try? url.bookmarkData(options: Sandbox.bookmarkCreationOptions(sandboxed: sandboxed))
    }

    /// The bookmarked URL with access to it started, and new data when the bookmark was stale.
    public static func resolve(_ data: Data, sandboxed: Bool = Sandbox.isActive) -> (url: URL, renewed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Sandbox.bookmarkResolutionOptions(sandboxed: sandboxed), bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return (url, stale ? make(url, sandboxed: sandboxed) : nil)
    }
}

/// Folders outside the sidebar's folders that the Mac sandbox let orgstar into through an open
/// panel: setup files, includes, tangle and export targets and the like. Kept as bookmarks and
/// started when the store is first used.
@MainActor
public final class FolderGrants {
    public static let shared = FolderGrants()
    static let key = "folderGrants"

    private let defaults: UserDefaults
    private let sandboxed: Bool
    /// The granted folders, with access started.
    public private(set) var folders: [URL] = []

    init(defaults: UserDefaults = .standard, sandboxed: Bool = Sandbox.isActive) {
        self.defaults = defaults
        self.sandboxed = sandboxed
        let saved = defaults.array(forKey: Self.key) as? [Data] ?? []
        var kept: [Data] = []
        for data in saved {
            // One that doesn't resolve now (an unmounted volume) is kept for later.
            guard let (url, renewed) = SecurityBookmark.resolve(data, sandboxed: sandboxed) else {
                kept.append(data)
                continue
            }
            folders.append(url)
            kept.append(renewed ?? data)
        }
        if kept != saved { defaults.set(kept, forKey: Self.key) }
    }

    /// Keeps `url`, a folder from an open panel, and starts access to it. False when its
    /// bookmark can't be made, so access lasts only until the app quits.
    @discardableResult
    public func add(_ url: URL) -> Bool {
        _ = url.startAccessingSecurityScopedResource()
        guard !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return true }
        folders.append(url)
        guard let data = SecurityBookmark.make(url, sandboxed: sandboxed) else { return false }
        defaults.set((defaults.array(forKey: Self.key) as? [Data] ?? []) + [data], forKey: Self.key)
        return true
    }

    /// Whether `granted` is `folder` or contains it.
    public nonisolated static func covers(_ granted: URL, _ folder: URL) -> Bool {
        let outer = granted.resolvingSymlinksInPath().standardizedFileURL.path
        let inner = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return inner == outer || inner.hasPrefix(outer == "/" ? "/" : outer + "/")
    }
}
