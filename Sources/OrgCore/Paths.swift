import Foundation

/// Paths as written in Org files and settings, where `~` is the home folder.
public enum OrgPaths {
    /// The account's home folder. On the Mac this is the real one even in the sandbox, where
    /// `NSHomeDirectory()` and `expandingTildeInPath` give the app's container.
    public static let home: String = {
        #if os(macOS)
        getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory()
        #else
        NSHomeDirectory()
        #endif
    }()

    /// `path` with a leading `~` or `~/` taken from `home`; otherwise, `~user` included, as
    /// `expandingTildeInPath` gives it.
    public static func expandingTilde(_ path: String, home: String = home) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return (path as NSString).expandingTildeInPath }
        return ((home + path.dropFirst()) as NSString).expandingTildeInPath
    }

    /// `path` with `home` at its start written as `~`, as `abbreviatingWithTildeInPath` does.
    public static func abbreviatingWithTilde(_ path: String, home: String = home) -> String {
        let normalized = path.hasPrefix("~") ? path : (path as NSString).expandingTildeInPath
        if normalized == home { return "~" }
        return normalized.hasPrefix(home + "/") ? "~" + normalized.dropFirst(home.count) : normalized
    }
}
