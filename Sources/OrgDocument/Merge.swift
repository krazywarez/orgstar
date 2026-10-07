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
