import OrgCore

public struct MergeConflict: Sendable, Equatable {
    public let base: String
    public let ours: String
    public let theirs: String
}

public enum MergeResult: Sendable, Equatable {
    case merged(String)
    case conflict([MergeConflict])
}

/// Line-based three-way merge. Lines keep their endings, so CRLF and a missing final newline
/// survive. A region changed on one side takes that side; changed the same way on both, takes
/// it once; changed differently, is a conflict.
public func threeWayMerge(base: String, ours: String, theirs: String) -> MergeResult {
    let baseLines = textLines(base)
    let ourLines = textLines(ours)
    let theirLines = textLines(theirs)
    var ids = LineIDs()
    let baseIDs = ids.encode(baseLines)
    let ourIDs = ids.encode(ourLines)
    let theirIDs = ids.encode(theirLines)

    var toOurs = [Int?](repeating: nil, count: baseLines.count)
    for (b, o) in matchingLines(baseIDs, ourIDs) { toOurs[b] = o }
    var toTheirs = [Int?](repeating: nil, count: baseLines.count)
    for (b, t) in matchingLines(baseIDs, theirIDs) { toTheirs[b] = t }

    var merged: [String] = []
    var conflicts: [MergeConflict] = []
    var nextBase = 0, nextOurs = 0, nextTheirs = 0

    func resolve(_ baseEnd: Int, _ oursEnd: Int, _ theirsEnd: Int) {
        let b = baseLines[nextBase..<baseEnd]
        let o = ourLines[nextOurs..<oursEnd]
        let t = theirLines[nextTheirs..<theirsEnd]
        if o.elementsEqual(b) {
            merged += t
        } else if t.elementsEqual(b) || o.elementsEqual(t) {
            merged += o
        } else {
            conflicts.append(MergeConflict(base: b.joined(), ours: o.joined(), theirs: t.joined()))
        }
    }

    // A base line kept by both sides is a fixed point; everything between fixed points is
    // resolved as one region.
    for k in baseLines.indices {
        guard let o = toOurs[k], let t = toTheirs[k], o >= nextOurs, t >= nextTheirs else { continue }
        resolve(k, o, t)
        merged.append(baseLines[k])
        nextBase = k + 1
        nextOurs = o + 1
        nextTheirs = t + 1
    }
    resolve(baseLines.count, ourLines.count, theirLines.count)
    return conflicts.isEmpty ? .merged(merged.joined()) : .conflict(conflicts)
}

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
func textLines(_ text: String) -> [String] {
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

struct LineIDs {
    private var ids: [String: Int] = [:]

    mutating func encode(_ lines: [String]) -> [Int] {
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
func matchingLines(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
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

/// One line of a diff, with its ending.
public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case same, removed, added }
    public let kind: Kind
    public let text: String
}

/// The lines of `old` and `new` in order: kept, removed from `old`, added in `new`.
public func lineDiff(old: String, new: String) -> [DiffLine] {
    let oldLines = textLines(old)
    let newLines = textLines(new)
    var ids = LineIDs()
    let pairs = matchingLines(ids.encode(oldLines), ids.encode(newLines))
    var result: [DiffLine] = []
    var i = 0, j = 0
    for (pi, pj) in pairs + [(oldLines.count, newLines.count)] {
        result += oldLines[i..<pi].map { DiffLine(kind: .removed, text: $0) }
        result += newLines[j..<pj].map { DiffLine(kind: .added, text: $0) }
        if pi < oldLines.count, pj < newLines.count { result.append(DiffLine(kind: .same, text: oldLines[pi])) }
        i = pi + 1
        j = pj + 1
    }
    return result
}

/// `ours` and `theirs` merged against `base` where they don't conflict, as `threeWayMerge`
/// does, with each conflict between git's markers. Without a base, every difference is a
/// conflict.
public func mergeWithMarkers(base: String?, ours: String, theirs: String, oursLabel: String, theirsLabel: String) -> String {
    func block(_ o: String, _ t: String) -> String {
        func ended(_ s: String) -> String { s.isEmpty || s.hasSuffix("\n") ? s : s + "\n" }
        return "<<<<<<< \(oursLabel)\n" + ended(o) + "=======\n" + ended(t) + ">>>>>>> \(theirsLabel)\n"
    }
    guard let base else {
        var out = ""
        var o = "", t = ""
        func flush() {
            if !o.isEmpty || !t.isEmpty { out += block(o, t) }
            o = ""
            t = ""
        }
        for line in lineDiff(old: ours, new: theirs) {
            switch line.kind {
            case .same:
                flush()
                out += line.text
            case .removed: o += line.text
            case .added: t += line.text
            }
        }
        flush()
        return out
    }
    let baseLines = textLines(base)
    let ourLines = textLines(ours)
    let theirLines = textLines(theirs)
    var ids = LineIDs()
    let baseIDs = ids.encode(baseLines)
    var toOurs = [Int?](repeating: nil, count: baseLines.count)
    for (b, o) in matchingLines(baseIDs, ids.encode(ourLines)) { toOurs[b] = o }
    var toTheirs = [Int?](repeating: nil, count: baseLines.count)
    for (b, t) in matchingLines(baseIDs, ids.encode(theirLines)) { toTheirs[b] = t }
    var merged = ""
    var nextBase = 0, nextOurs = 0, nextTheirs = 0
    func resolve(_ baseEnd: Int, _ oursEnd: Int, _ theirsEnd: Int) {
        let b = baseLines[nextBase..<baseEnd], o = ourLines[nextOurs..<oursEnd], t = theirLines[nextTheirs..<theirsEnd]
        if o.elementsEqual(b) {
            merged += t.joined()
        } else if t.elementsEqual(b) || o.elementsEqual(t) {
            merged += o.joined()
        } else {
            merged += block(o.joined(), t.joined())
        }
    }
    for k in baseLines.indices {
        guard let o = toOurs[k], let t = toTheirs[k], o >= nextOurs, t >= nextTheirs else { continue }
        resolve(k, o, t)
        merged += baseLines[k]
        nextBase = k + 1
        nextOurs = o + 1
        nextTheirs = t + 1
    }
    resolve(baseLines.count, ourLines.count, theirLines.count)
    return merged
}
