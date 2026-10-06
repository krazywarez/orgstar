#if os(macOS)
import CoreServices
import Foundation

/// FSEvents with file-level events. Delivers batches on a private queue.
public final class FSEventsWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let handler: @Sendable ([WatchEvent]) -> Void
    private let queue = DispatchQueue(label: "orgstar.fsevents")
    private var stream: FSEventStreamRef?

    public init(roots: [URL], latency: CFTimeInterval = 0.3, handler: @escaping @Sendable ([WatchEvent]) -> Void) {
        paths = roots.map(\.path)
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.deliver(paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: count)))
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(paths eventPaths: [String], flags: [FSEventStreamEventFlags]) {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        var events: [WatchEvent] = []
        for (path, flag) in zip(eventPaths, flags) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if flag & rescanFlags != 0 {
                let root = paths.first { path.hasPrefix($0) } ?? path
                events.append(.rescan(URL(fileURLWithPath: root).standardizedFileURL))
            } else {
                events.append(.changed(url))
            }
        }
        if !events.isEmpty { handler(events) }
    }
}
#endif
