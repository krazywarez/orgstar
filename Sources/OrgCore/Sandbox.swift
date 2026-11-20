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

    /// A bookmark of `url` made with `bookmarkCreationOptions`. Access to the URL is started
    /// first: a URL from SwiftUI's file importer is security-scoped, and the sandbox refuses a
    /// bookmark of it until access starts. Access stays on for the session.
    public static func bookmark(_ url: URL, sandboxed: Bool = isActive) throws -> Data {
        _ = url.startAccessingSecurityScopedResource()
        return try url.bookmarkData(options: bookmarkCreationOptions(sandboxed: sandboxed), includingResourceValuesForKeys: nil, relativeTo: nil)
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
