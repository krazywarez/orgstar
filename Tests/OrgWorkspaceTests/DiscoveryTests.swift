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
        ("a.md", .file(.other)),
        ("photo.jpg", .file(.other)),
        (".hidden.org", .file(.org)),
        (".zshrc", .file(.other)),
        (".#a.org", .ignored),
        (".DS_Store", .ignored),
        (".a.org.orgstar-backup-1", .ignored),
    ])
    func classify(name: String, expected: FileClassification) {
        #expect(WorkspaceScanner.classify(name) == expected)
    }

    @Test func agendaScope() {
        #expect(AgendaScope().contains(relativePath: "a.org", kind: .org))
        #expect(!AgendaScope().contains(relativePath: "a.org_archive", kind: .archive))
        #expect(!AgendaScope().contains(relativePath: "a.org", kind: .conflict))
        #expect(!AgendaScope().contains(relativePath: "sub/.draft.org", kind: .org))
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
        try folder.write(".config/app.toml", "")
        try folder.write(".notes.org", "* n\n")
        try folder.write("node_modules/x/index.js", "")
        let discovery = try WorkspaceScanner.scan(folder.url)
        #expect(discovery.files.map(\.url.lastPathComponent) == ["app.toml", ".notes.org", "a.org", "notes.txt", "b.org_archive"])
        #expect(discovery.files.map(\.kind) == [.other, .org, .org, .other, .archive])
        let visible = try WorkspaceScanner.scan(folder.url, rules: ScanRules(hiddenFiles: false))
        #expect(visible.files.map(\.url.lastPathComponent) == ["a.org", "notes.txt", "b.org_archive"])
        #expect(discovery.placeholders.map(\.lastPathComponent) == ["e.org"])
    }
}
