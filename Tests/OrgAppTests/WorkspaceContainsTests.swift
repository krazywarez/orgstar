import Foundation
import Testing
@testable import OrgApp

struct WorkspaceContainsTests {
    @Test func insideByWholeComponents() {
        let root = URL(fileURLWithPath: "/tmp/notes")
        #expect(WorkspaceModel.isInside(URL(fileURLWithPath: "/tmp/notes"), roots: [root]))
        #expect(WorkspaceModel.isInside(URL(fileURLWithPath: "/tmp/notes/a/b.html"), roots: [root]))
        #expect(WorkspaceModel.isInside(URL(fileURLWithPath: "/tmp/notes/../notes/b.html"), roots: [root]))
        #expect(!WorkspaceModel.isInside(URL(fileURLWithPath: "/tmp/notes2/b.html"), roots: [root]))
        #expect(!WorkspaceModel.isInside(URL(fileURLWithPath: "/tmp/b.html"), roots: [root]))
        #expect(!WorkspaceModel.isInside(URL(fileURLWithPath: "/tmp/notes/b.html"), roots: []))
    }

    @Test func insideThroughSymbolicLinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try Data().write(to: real.appendingPathComponent("a.org"))
        #expect(WorkspaceModel.isInside(link.appendingPathComponent("a.org"), roots: [real]))
        #expect(WorkspaceModel.isInside(real.appendingPathComponent("a.org"), roots: [link]))
    }
}
