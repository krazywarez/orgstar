import Foundation
import OrgIndex
import Testing
@testable import OrgWorkspace

struct WatcherTests {
    @Test func reportsAWrittenFile() throws {
        let folder = try Folder()
        let received = Received()
        let watcher = FSEventsWatcher(roots: [folder.url.resolvingSymlinksInPath()], latency: 0.05) { received.add($0) }
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        try folder.write("a.org", "* a\n")
        #expect(received.wait(for: "a.org", timeout: 5))
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WatchEvent] = []

    func add(_ batch: [WatchEvent]) {
        lock.withLock { events += batch }
    }

    func wait(for name: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let found = lock.withLock {
                events.contains { if case .changed(let url) = $0 { return url.lastPathComponent == name } else { return false } }
            }
            if found { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
