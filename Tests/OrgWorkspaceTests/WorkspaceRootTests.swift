import Foundation
import Testing
@testable import OrgWorkspace

struct WorkspaceRootTests {
    @Test func plainBookmarkResolves() throws {
        let folder = try Folder()
        let root = try WorkspaceRoot(url: folder.url)
        let resolved = try root.resolve()
        #expect(resolved.url.resolvingSymlinksInPath() == folder.url.resolvingSymlinksInPath())
        #expect(root.path == folder.url.path)
    }

    #if os(macOS)
    /// The sandboxed build's bookmarks carry their scope, and resolve with it.
    @Test func securityScopedBookmarkResolves() throws {
        let folder = try Folder()
        let root = try WorkspaceRoot(url: folder.url, sandboxed: true)
        #expect(try root.resolve(sandboxed: true).url.resolvingSymlinksInPath() == folder.url.resolvingSymlinksInPath())
        #expect(root.bookmark != (try WorkspaceRoot(url: folder.url, sandboxed: false)).bookmark)
    }
    #endif
}
