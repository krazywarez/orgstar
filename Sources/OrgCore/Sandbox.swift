import Foundation

/// Whether this process runs in the App Sandbox, as the Mac App Store build does, and the
/// choices that follow from it.
public enum Sandbox {
    /// True for a sandboxed Mac process. Always false on iOS.
    public static let isActive = isActive(environment: ProcessInfo.processInfo.environment)

    /// The sandbox sets `APP_SANDBOX_CONTAINER_ID` for the processes it confines.
    static func isActive(environment: [String: String]) -> Bool {
        #if os(macOS)
        environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        false
        #endif
    }

    /// Options for a bookmark that should give access back after relaunch: security-scoped in
    /// the Mac sandbox, plain elsewhere.
    public static func bookmarkCreationOptions(sandboxed: Bool = isActive) -> URL.BookmarkCreationOptions {
        #if os(macOS)
        sandboxed ? .withSecurityScope : []
        #else
        []
        #endif
    }

    /// The resolving side of `bookmarkCreationOptions`.
    public static func bookmarkResolutionOptions(sandboxed: Bool = isActive) -> URL.BookmarkResolutionOptions {
        #if os(macOS)
        sandboxed ? .withSecurityScope : []
        #else
        []
        #endif
    }
}
