#if os(macOS)
import Foundation

/// Where each line of the text starts (UTF-16), kept up to date edit by edit, so line numbers
/// come from a search instead of counting newlines from the top.
final class LineIndex {
    /// Sorted; the first line starts at 0.
    private(set) var starts: [Int] = [0]

    init(_ text: NSString = "") { reset(text) }

    func reset(_ text: NSString) {
        starts = [0]
        appendStarts(in: text, from: 0, to: text.length)
    }

    private func appendStarts(in text: NSString, from: Int, to end: Int) {
        var location = from
        while location < end {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: location, length: end - location))
            guard found.location != NSNotFound else { break }
            starts.append(found.location + 1)
            location = found.location + 1
        }
    }

    var lineCount: Int { starts.count }

    /// The line (from 1) holding `offset`.
    func line(of offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(1, low)
    }

    /// `old` (in the text before) became `newLength` characters of `text` (the text after).
    func replace(_ old: Range<Int>, newLength: Int, in text: NSString) {
        let delta = newLength - old.count
        // Starts after a newline inside the old range go; starts after it move.
        let first = firstIndex(after: old.lowerBound)
        let last = firstIndex(after: old.upperBound)
        var inserted: [Int] = []
        var location = old.lowerBound
        let end = old.lowerBound + newLength
        while location < end {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: location, length: end - location))
            guard found.location != NSNotFound else { break }
            inserted.append(found.location + 1)
            location = found.location + 1
        }
        if delta != 0 {
            for i in last..<starts.count { starts[i] += delta }
        }
        starts.replaceSubrange(first..<last, with: inserted)
    }

    /// The index of the first start greater than `offset`.
    private func firstIndex(after offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
#endif
