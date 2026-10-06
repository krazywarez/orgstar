import Foundation
import Testing
@testable import OrgWorkspace

struct ICloudTests {
    @Test func onlyFilesNotOnTheDeviceWait() {
        #expect(WorkspaceScanner.isPending(isUbiquitous: true, status: .notDownloaded))
        #expect(!WorkspaceScanner.isPending(isUbiquitous: true, status: .current))
        #expect(!WorkspaceScanner.isPending(isUbiquitous: true, status: .downloaded))
        #expect(!WorkspaceScanner.isPending(isUbiquitous: nil, status: nil))
        #expect(!WorkspaceScanner.isPending(isUbiquitous: false, status: .notDownloaded))
    }

    @Test func folderPresenterHearsCoordinatedWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-presenter-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.org")
        try "* A\n".write(to: file, atomically: true, encoding: .utf8)
        let received = Received()
        let presenter = FolderPresenter(root: root, latency: 0.05) { events in received.add(events) }
        presenter.start()
        defer { presenter.stop() }
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forReplacing, error: &error) { url in
            try? "* B\n".write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(received.wait(for: "a.org", timeout: 3))
    }
}

