#if os(macOS)
import Foundation

/// Hidden ranges, read by TextKit's enumeration callbacks, which may run off the main thread.
final class HiddenRanges: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [Range<Int>] = []

    func set(_ new: [Range<Int>]) {
        lock.withLock { ranges = new }
    }

    var all: [Range<Int>] {
        lock.withLock { ranges }
    }

    func covers(_ start: Int, _ end: Int) -> Bool {
        lock.withLock { ranges.contains { $0.lowerBound <= start && end <= $0.upperBound } }
    }

    func containing(_ offset: Int) -> Range<Int>? {
        lock.withLock { ranges.first { $0.lowerBound <= offset && offset < $0.upperBound } }
    }
}

/// Folded heading starts, read by the layout-fragment callback.
final class FoldedHeadings: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: Set<Int> = []

    func set(_ new: Set<Int>) {
        lock.withLock { starts = new }
    }

    func contains(_ offset: Int) -> Bool {
        lock.withLock { starts.contains(offset) }
    }

    var all: Set<Int> {
        lock.withLock { starts }
    }
}
#endif
