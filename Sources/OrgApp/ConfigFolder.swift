import Foundation
import OrgCore

/// A configuration folder chosen in the app, kept as a bookmark: on iOS a synced copy of the
/// Mac's `~/.config/orgstar`, in the Mac sandbox a folder outside the container. The bookmark
/// is security-scoped in the Mac sandbox and plain elsewhere.
public enum ConfigFolder {
    public static let bookmarkKey = "configFolderBookmark"

    /// The chosen folder with access to it started, or nil when none is chosen or its bookmark
    /// no longer resolves. A stale bookmark is renewed.
    public static func resolve(defaults: UserDefaults = .standard, sandboxed: Bool = Sandbox.isActive) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Sandbox.bookmarkResolutionOptions(sandboxed: sandboxed), bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? Sandbox.bookmark(url, sandboxed: sandboxed) {
            defaults.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    /// Keeps `url`, as from a folder picker, as the chosen folder and starts access to it. False
    /// when its bookmark can't be made, so the choice isn't kept after the app quits.
    @discardableResult
    public static func set(_ url: URL, defaults: UserDefaults = .standard, sandboxed: Bool = Sandbox.isActive) -> Bool {
        _ = url.startAccessingSecurityScopedResource()
        guard let bookmark = try? Sandbox.bookmark(url, sandboxed: sandboxed) else { return false }
        defaults.set(bookmark, forKey: bookmarkKey)
        return true
    }

    /// Stops using a chosen folder.
    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bookmarkKey)
    }

    /// `~/.config/orgstar` in the real home folder, where a folder picker starts.
    public static var suggested: URL {
        URL(fileURLWithPath: OrgPaths.home).appendingPathComponent(".config/orgstar")
    }
}
