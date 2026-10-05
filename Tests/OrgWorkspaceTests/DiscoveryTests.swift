import Foundation
import OrgIndex
import Testing
@testable import OrgWorkspace

struct ClassificationTests {
    @Test(arguments: [
        ("a.org", FileClassification.file(.org)),
        ("a.org_archive", .file(.archive)),
        ("a.sync-conflict-20261004-120000-ABCDEFG.org", .file(.conflict)),
        (".a.org.icloud", .placeholder("a.org")),
        (".syncthing.a.org.tmp", .ignored),
        (".a.org.orgstar-1234", .ignored),
        ("a.org~", .ignored),
        ("#a.org#", .ignored),
        ("a.md", .ignored),
        (".hidden.org", .ignored),
    ])
    func classify(name: String, expected: FileClassification) {
        #expect(WorkspaceScanner.classify(name) == expected)
    }

    @Test func agendaScope() {
        #expect(AgendaScope().contains(relativePath: "a.org", kind: .org))
        #expect(!AgendaScope().contains(relativePath: "a.org_archive", kind: .archive))
        #expect(!AgendaScope().contains(relativePath: "a.org", kind: .conflict))
        let work = AgendaScope(globs: ["work/*"])
        #expect(work.contains(relativePath: "work/deep/a.org", kind: .org))
        #expect(!work.contains(relativePath: "home/a.org", kind: .org))
    }
}

struct ScanTests {
    @Test func skipsHiddenFoldersAndFindsPlaceholders() throws {
        let folder = try Folder()
        try folder.write("a.org", "* a\n")
        try folder.write("sub/b.org_archive", "* b\n")
        try folder.write(".git/c.org", "* c\n")
        try folder.write(".stversions/d.org", "* d\n")
        try folder.write("sub/.e.org.icloud", "")
        try folder.write("notes.txt", "")
        let discovery = try WorkspaceScanner.scan(folder.url)
        #expect(discovery.files.map(\.url.lastPathComponent) == ["a.org", "b.org_archive"])
        #expect(discovery.placeholders.map(\.lastPathComponent) == ["e.org"])
    }
}
