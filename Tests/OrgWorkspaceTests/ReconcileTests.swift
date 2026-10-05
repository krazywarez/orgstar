import Foundation
import OrgIndex
import Testing
@testable import OrgWorkspace

struct ReconcileTests {
    @Test func indexesUpdatesMovesAndRemoves() throws {
        let folder = try Folder()
        let index = try IndexStore()
        let reconciler = Reconciler(index: index, settings: IndexSettings())
        let a = try folder.write("a.org", "* Alpha\n")
        try folder.write("b.org", "* Beta\n")

        var report = try reconciler.reconcile(root: folder.url)
        #expect(report.indexed.count == 2)
        #expect(try index.search("alpha").map(\.path) == [a.path])

        report = try reconciler.reconcile(root: folder.url)
        #expect(report.unchanged == 2 && report.indexed.isEmpty)

        try FileManager.default.moveItem(at: folder.url.appendingPathComponent("b.org"), to: folder.url.appendingPathComponent("c.org"))
        try folder.write("a.org", "* Gamma\n")
        report = try reconciler.reconcile(root: folder.url)
        #expect(report.moved.map { URL(fileURLWithPath: $0).lastPathComponent } == ["c.org"])
        #expect(report.indexed == [a.path])
        #expect(try index.search("gamma").count == 1)
        #expect(try index.search("beta").map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["c.org"])

        try FileManager.default.removeItem(at: a)
        report = try reconciler.reconcile(root: folder.url)
        #expect(report.removed == [a.path])
        #expect(try index.search("gamma").isEmpty)
    }

    @Test func touchedFileWithSameContentIsNotReparsed() throws {
        let folder = try Folder()
        let index = try IndexStore()
        let reconciler = Reconciler(index: index, settings: IndexSettings())
        let a = try folder.write("a.org", "* Alpha\n")
        _ = try reconciler.reconcile(root: folder.url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: a.path)
        #expect(try reconciler.reconcile(root: folder.url).touched == [a.path])
    }

    @Test func newSettingsVersionReindexes() throws {
        let folder = try Folder()
        let index = try IndexStore()
        try folder.write("a.org", "* Alpha\n")
        _ = try Reconciler(index: index, settings: IndexSettings(version: 1)).reconcile(root: folder.url)
        #expect(try Reconciler(index: index, settings: IndexSettings(version: 2)).reconcile(root: folder.url).indexed.count == 1)
    }

    @Test func conflictCopiesAreListedButNotSearchable() throws {
        let folder = try Folder()
        let index = try IndexStore()
        try folder.write("a.sync-conflict-1.org", "* Alpha\n")
        _ = try Reconciler(index: index, settings: IndexSettings()).reconcile(root: folder.url)
        #expect(try index.files().map(\.kind) == [.conflict])
        #expect(try index.search("alpha").isEmpty)
    }

    @Test func reconcilingChangedPaths() throws {
        let folder = try Folder()
        let index = try IndexStore()
        let reconciler = Reconciler(index: index, settings: IndexSettings())
        let a = try folder.write("a.org", "* Alpha\n")
        let b = try folder.write("b.org", "* Beta\n")
        _ = try reconciler.reconcile(root: folder.url)
        try folder.write("a.org", "* Delta\n")
        try FileManager.default.removeItem(at: b)
        let report = try reconciler.reconcile(root: folder.url, paths: [a, b])
        #expect(report.indexed == [a.path])
        #expect(report.removed == [b.path])
    }

    @Test func rootBookmarkResolves() throws {
        let folder = try Folder()
        let root = try WorkspaceRoot(url: folder.url)
        #expect(try root.resolve().url.resolvingSymlinksInPath() == folder.url.resolvingSymlinksInPath())
    }
}
