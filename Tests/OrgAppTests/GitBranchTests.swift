import Foundation
import Testing
@testable import OrgApp

struct GitBranchTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("notes/sub"), withIntermediateDirectories: true)
        return url
    }

    @Test func branchDetachedWorktreeAndNone() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes/sub/a.org").path
        #expect(GitBranch.current(for: file) == nil)

        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/feature/x\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        #expect(GitBranch.current(for: file) == "feature/x")

        try "0123456789abcdef0123456789abcdef01234567\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        #expect(GitBranch.current(for: file) == "0123456")

        let worktree = root.appendingPathComponent("notes/.git")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/worktrees/w"), withIntermediateDirectories: true)
        try "ref: refs/heads/wt\n".write(to: root.appendingPathComponent(".git/worktrees/w/HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: ../.git/worktrees/w\n".write(to: worktree, atomically: true, encoding: .utf8)
        #expect(GitBranch.current(for: file) == "wt")
    }
}
