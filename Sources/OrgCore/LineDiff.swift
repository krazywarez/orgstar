import Foundation

// Line diffs: Myers over line ids, for merges, diffs and commands' edits.

/// Edits, in `old` coordinates and ascending order, that turn `old` into `new` line by line.
public func lineEdits(from old: String, to new: String) -> [TextEdit] {
    let oldLines = textLines(old)
    let newLines = textLines(new)
    var ids = LineIDs()
    let pairs = matchingLines(ids.encode(oldLines), ids.encode(newLines))
    var offsets = [0]
    for line in oldLines { offsets.append(offsets.last! + line.utf16.count) }
    var edits: [TextEdit] = []
    var i = 0, j = 0
    for (pi, pj) in pairs + [(oldLines.count, newLines.count)] {
        if i < pi || j < pj {
            edits.append(TextEdit(range: offsets[i]..<offsets[pi], replacement: newLines[j..<pj].joined()))
        }
        i = pi + 1
        j = pj + 1
    }
    return edits
}

/// Lines with their endings.
public func textLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
        current.unicodeScalars.append(scalar)
        if scalar == "\n" {
            lines.append(current)
            current = ""
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

public struct LineIDs {
    private var ids: [String: Int] = [:]

    public init() {}

    public mutating func encode(_ lines: [String]) -> [Int] {
        lines.map { line in
            if let id = ids[line] { return id }
            let id = ids.count
            ids[line] = id
            return id
        }
    }
}

/// Matched index pairs of a longest common subsequence, ascending. Common prefix and suffix
/// are matched directly; Myers' algorithm handles the middle. When the middle differs by more
/// than the memory budget allows, it is treated as having no matches.
public func matchingLines(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
        suffix += 1
    }
    var pairs = (0..<prefix).map { ($0, $0) }
    let middleA = Array(a[prefix..<(a.count - suffix)])
    let middleB = Array(b[prefix..<(b.count - suffix)])
    pairs += myers(middleA, middleB).map { ($0.0 + prefix, $0.1 + prefix) }
    pairs += (0..<suffix).map { (a.count - suffix + $0, b.count - suffix + $0) }
    return pairs
}

private func myers(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
    let n = a.count, m = b.count
    guard n > 0, m > 0 else { return [] }
    let maxD = n + m
    let offset = maxD + 1
    // Each step keeps a copy of the frontier for backtracking; cap that at ~20M entries.
    let budget = max(1, 20_000_000 / (2 * maxD + 3))
    var v = [Int](repeating: 0, count: 2 * maxD + 3)
    var trace: [[Int]] = []
    var found = false
    search: for d in 0...min(maxD, budget) {
        trace.append(v)
        for k in stride(from: -d, through: d, by: 2) {
            var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
            var y = x - k
            while x < n, y < m, a[x] == b[y] {
                x += 1
                y += 1
            }
            v[offset + k] = x
            if x >= n, y >= m {
                found = true
                break search
            }
        }
    }
    guard found else { return [] }

    var pairs: [(Int, Int)] = []
    var x = n, y = m
    for d in stride(from: trace.count - 1, through: 0, by: -1) {
        let v = trace[d]
        let k = x - y
        let previousK = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? k + 1 : k - 1
        let previousX = v[offset + previousK]
        let previousY = previousX - previousK
        while x > previousX, y > previousY {
            pairs.append((x - 1, y - 1))
            x -= 1
            y -= 1
        }
        if d > 0 {
            x = previousX
            y = previousY
        }
    }
    return pairs.reversed()
}


/// An edit spanning several lines as the lines it changes, so what lies between (a folded
/// heading) is left alone: a command changing the text in two places gives two edits. For
/// editors applying edits; commands still return one.
public func splitByLines(_ edit: TextEdit, in text: String) -> [TextEdit] {
    let ns = text as NSString
    let start = ns.lineRange(for: NSRange(location: edit.range.lowerBound, length: 0)).location
    var end = edit.range.upperBound
    if end < ns.length, end == 0 || ns.character(at: end - 1) != 10 {
        end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0)))
    }
    let old = ns.substring(with: NSRange(start..<end))
    guard old.utf16.lazy.filter({ $0 == 10 }).count >= 2 else { return [edit] }
    let new = ns.substring(with: NSRange(start..<edit.range.lowerBound)) + edit.replacement + ns.substring(with: NSRange(edit.range.upperBound..<end))
    let edits = lineEdits(from: old, to: new).map { TextEdit(range: ($0.range.lowerBound + start)..<($0.range.upperBound + start), replacement: $0.replacement) }
    return edits.isEmpty ? [edit] : edits
}
