import Foundation
import Testing
@testable import OrgApp

@MainActor
struct FolderGrantsTests {
    func defaults() -> UserDefaults {
        let name = "orgstar-folder-grants-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func grantsComeBackAtLaunch() throws {
        let store = defaults()
        let folder = try Folder()
        let grants = FolderGrants(defaults: store, sandboxed: false)
        #expect(grants.folders.isEmpty)
        grants.add(folder.url)
        grants.add(folder.url)
        #expect(grants.folders == [folder.url])
        #expect((store.array(forKey: FolderGrants.key) as? [Data])?.count == 1)
        let relaunched = FolderGrants(defaults: store, sandboxed: false)
        #expect(relaunched.folders.map { $0.resolvingSymlinksInPath().path } == [folder.url.resolvingSymlinksInPath().path])
    }

    @Test func bookmarksThatDontResolveAreKept() {
        let store = defaults()
        store.set([Data("not a bookmark".utf8)], forKey: FolderGrants.key)
        #expect(FolderGrants(defaults: store, sandboxed: false).folders.isEmpty)
        #expect((store.array(forKey: FolderGrants.key) as? [Data])?.count == 1)
    }

    @Test func fileBookmarkRoundTrip() throws {
        let folder = try Folder()
        let file = try folder.write("a.org", "* a\n")
        let data = try #require(SecurityBookmark.make(file, sandboxed: false))
        let resolved = try #require(SecurityBookmark.resolve(data, sandboxed: false))
        #expect(resolved.url.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
    }

    @Test func foldersToGrantSkipReachablePaths() {
        let reachable = [URL(fileURLWithPath: "/notes"), URL(fileURLWithPath: "/container")]
        let existing: Set<String> = ["/", "/notes", "/container", "/other", "/other/site"]
        let folders = WorkspaceModel.foldersToGrant(
            for: ["/notes/a.org", "/container/x", "/other/setup.org", "/other/inc.org", "", "/other/site/new/out.html"],
            directories: false, reachable: reachable, exists: existing.contains)
        #expect(folders.map(\.path) == ["/other", "/other/site"])
    }

    @Test func foldersToGrantForFolders() {
        let folders = WorkspaceModel.foldersToGrant(
            for: ["/out/public", "/out/missing/deep"], directories: true, reachable: [],
            exists: ["/", "/out", "/out/public"].contains)
        #expect(folders.map(\.path) == ["/out/public", "/out"])
    }
}
