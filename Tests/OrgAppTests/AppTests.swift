import Foundation
import OrgCore
import OrgIndex
import Testing
@testable import OrgApp

/// A temporary folder that removes itself.
final class Folder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file.standardizedFileURL
    }
}

struct FileTreeTests {
    @Test func foldersFirstThenFiles() {
        let files = ["b.org", "a/z.org", "a/y.org", "c.sync-conflict-1.org", "a2.org"].map {
            FileEntry(path: "/r/" + $0, root: "/r", kind: $0.contains("conflict") ? .conflict : .org)
        }
        let tree = FileTreeNode.build(root: "/r", files: files)
        #expect(tree.children?.map(\.name) == ["a", "a2.org", "b.org", "c.sync-conflict-1.org"])
        #expect(tree.children?[0].children?.map(\.name) == ["y.org", "z.org"])
        #expect(tree.children?[1].children == nil)
    }

    @Test func fuzzyMatching() {
        #expect(FuzzyMatch.score("wn", "work/notes.org") != nil)
        #expect(FuzzyMatch.score("xyz", "work/notes.org") == nil)
        let files = ["work/notes.org", "notes.org", "personal/wine.org"].map { FileEntry(path: "/r/" + $0, root: "/r", kind: .org) }
        #expect(FuzzyMatch.rank("notes", files).map(\.relativePath) == ["notes.org", "work/notes.org"])
        #expect(FuzzyMatch.rank("", files).count == 3)
    }
}

@MainActor
struct WorkspaceModelTests {
    @Test func addSearchRemoveAndPersist() async throws {
        let notes = try Folder()
        let support = try Folder()
        try notes.write("a.org", "* Groceries\nbuy apples\n")
        try notes.write("sub/b.org", "* Taxes\n")
        try notes.write("c.sync-conflict-1.org", "* Taxes copy\n")

        let model = try WorkspaceModel(directory: support.url)
        try await model.addRoot(notes.url)
        #expect(model.files.count == 3)
        #expect(model.search("apples").map(\.title) == ["Groceries"])
        #expect(model.quickOpen("bo").map(\.name) == ["b.org"])
        let root = try #require(model.rootPaths.first)
        #expect(model.tree(forRoot: root).children?.map(\.name) == ["sub", "a.org", "c.sync-conflict-1.org"])

        let reopened = try WorkspaceModel(directory: support.url)
        #expect(reopened.roots.count == 1)
        #expect(reopened.files.count == 3)

        try reopened.removeRoot(path: root)
        #expect(reopened.roots.isEmpty)
        #expect(reopened.files.isEmpty)
        #expect(reopened.search("apples").isEmpty)
    }

    @Test func changedFilesAreReindexed() async throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* Old\n")
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(notes.url)
        try notes.write("a.org", "* New\n")
        await model.filesChanged([file], rescan: [])
        #expect(model.search("new").count == 1)
        #expect(model.changedFile?.path == file.path)
    }
}

@MainActor
struct DocumentSessionTests {
    @Test func openShowAndReload() throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* One\n* Two\n")
        let session = DocumentSession()
        session.open(file.path)
        #expect(session.outline.map(\.title) == ["One", "Two"])

        let location = HeadingLocation(path: file.path, ordinal: 1, title: "Two", start: 6, contentHash: "stale")
        session.show(location)
        #expect(session.revealRequest?.offset == 6)

        try notes.write("a.org", "intro\n* One\n* Two\n")
        session.fileChanged(file.path)
        #expect(session.outline.map(\.start) == [6, 12])
        #expect(session.diskBytes != nil)
        session.show(location)
        #expect(session.revealRequest?.offset == 12)
    }

    @Test func missingFileReportsAnError() {
        let session = DocumentSession()
        session.open("/nonexistent/a.org")
        #expect(session.lastError != nil)
        #expect(session.document == nil)
    }
}
