import Foundation

public enum WatchEvent: Sendable, Equatable {
    case changed(URL)
    /// Events were dropped or coalesced for this folder, or a root moved: rescan it.
    case rescan(URL)
}

/// Watches a folder as an `NSFilePresenter`: told of coordinated writes inside it, which is
/// how iCloud and File Provider syncing (Möbius Sync for Syncthing) change files on iOS, where
/// there are no FSEvents. Events arrive in batches after `latency`.
public final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue = OperationQueue()
    private let latency: TimeInterval
    private let handler: @Sendable ([WatchEvent]) -> Void
    private let lock = NSLock()
    private var pending: [WatchEvent] = []
    private var scheduled = false

    public init(root: URL, latency: TimeInterval = 0.3, handler: @escaping @Sendable ([WatchEvent]) -> Void) {
        presentedItemURL = root
        self.latency = latency
        self.handler = handler
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    public func start() { NSFileCoordinator.addFilePresenter(self) }

    public func stop() { NSFileCoordinator.removeFilePresenter(self) }

    private func add(_ event: WatchEvent) {
        let schedule: Bool = lock.withLock {
            if !pending.contains(event) { pending.append(event) }
            defer { scheduled = true }
            return !scheduled
        }
        guard schedule else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + latency) { [self] in
            let batch: [WatchEvent] = lock.withLock {
                defer {
                    pending = []
                    scheduled = false
                }
                return pending
            }
            handler(batch)
        }
    }

    public func presentedSubitemDidChange(at url: URL) { add(.changed(url)) }
    public func presentedSubitemDidAppear(at url: URL) { add(.changed(url)) }
    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        add(.changed(oldURL))
        add(.changed(newURL))
    }
    public func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        add(.changed(url))
        completionHandler(nil)
    }
    public func presentedItemDidChange() {
        if let presentedItemURL { add(.rescan(presentedItemURL)) }
    }
    public func presentedItemDidMove(to newURL: URL) { add(.rescan(newURL)) }
}
