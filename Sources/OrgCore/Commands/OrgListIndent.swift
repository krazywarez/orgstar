import Foundation

extension EmacsBuffer {
    // MARK: - Indentation changes

    /// `org-list-struct-outdent`.
    func structOutdent(_ start: Int, _ end: Int, _ structure: ListStruct, _ parents: [(item: Int, parent: Int?)]) throws -> [(item: Int, parent: Int?)] {
        var acc: [Int: Int] = [:]
        return try parents.map { cell in
            let (item, parent) = cell
            if item < start { return cell }
            if item >= end {
                if let parent, let convert = acc[parent] { return (item, convert) }
                return cell
            }
            guard let parent else { throw UserError(message: "Cannot outdent top-level items") }
            if parent >= start {
                acc[parent] = item
                return cell
            }
            acc[parent] = item
            return (item, structure.parent(parent, parents))
        }
    }

    /// `org-list-struct-indent`.
    func structIndent(_ start: Int, _ end: Int, _ structure: ListStruct, _ parents: [(item: Int, parent: Int?)], _ prevs: [Int: Int]) throws -> [(item: Int, parent: Int?)] {
        var acc: [(item: Int, parent: Int?)] = []
        func remember(_ cell: (item: Int, parent: Int?)) -> (item: Int, parent: Int?) {
            acc.insert(cell, at: 0)
            return cell
        }
        return try parents.map { cell in
            let (item, parent) = cell
            if item < start { return cell }
            if item >= end {
                if let convert = acc.first(where: { $0.item == parent }) { return (item, convert.parent) }
                return cell
            }
            let previous = structure.previousItem(item, prevs)
            guard let previous else {
                if parent == nil || parent! < start { throw UserError(message: "Cannot indent the first item of a list") }
                return remember(cell)
            }
            if previous < start { return remember((item, previous)) }
            return remember((item, acc.first { $0.item == previous }?.parent ?? nil))
        }
    }

    // MARK: - Repairs

    /// Records a successful `string-match' on a string in the match data.
    private func stringMatched(_ string: String, _ range: Range<String.Index>) {
        let start = string.utf16.distance(from: string.startIndex, to: range.lowerBound)
        lastMatch = [start..<(start + string[range].utf16.count)]
    }

    /// `org-list-inc-bullet-maybe`.
    func incrementBullet(_ bullet: String) -> String {
        if let range = bullet.range(of: "[0-9]+", options: .regularExpression) {
            stringMatched(bullet, range)
            return bullet.replacingCharacters(in: range, with: String(Int(bullet[range])! + 1))
        }
        if let range = bullet.range(of: "[A-Za-z]", options: .regularExpression) {
            stringMatched(bullet, range)
            let scalar = bullet[range].unicodeScalars.first!.value + 1
            return bullet.replacingCharacters(in: range, with: String(Character(Unicode.Scalar(scalar)!)))
        }
        return bullet
    }

    /// `org-list-struct-fix-bul` (alphabetical bullets off).
    func fixBullets(_ structure: inout ListStruct, _ prevs: [Int: Int]) {
        func find(_ pattern: String, _ string: String) -> Range<String.Index>? {
            guard let range = string.range(of: pattern, options: .regularExpression) else { return nil }
            stringMatched(string, range)
            return range
        }
        for pos in structure.map(\.pos) {
            let previous = prevs[pos]
            let counter = structure.item(pos)!.counter
            let bullet = structure.bullet(pos)
            let previousBullet = previous.map { structure.bullet($0) }
            let alphap = previous == nil && useAlphabeticalBullets(pos, structure, prevs)
            let new: String
            if previous != nil, let counter, let previousBullet, find("[a-zA-Z]", counter) != nil, find("[a-zA-Z]", previousBullet) != nil {
                let lower = find("[a-z]", previousBullet)
                let range = lower ?? find("[A-Z]", previousBullet)!
                new = previousBullet.replacingCharacters(in: range, with: lower != nil ? counter.lowercased() : counter.uppercased())
            } else if previous != nil, let counter, let previousBullet, let counterRange = find("[0-9]+", counter),
                      let range = find("[0-9]+", previousBullet) {
                new = previousBullet.replacingCharacters(in: range, with: counter[counterRange])
            } else if let previousBullet {
                new = incrementBullet(previousBullet)
            } else if let counter, useAlphabeticalBullets(pos, structure, prevs), find("[A-Za-z]", counter) != nil, find("[A-Za-z]", bullet) != nil {
                let lower = find("[a-z]", bullet)
                let range = lower ?? find("[A-Z]", bullet)!
                new = bullet.replacingCharacters(in: range, with: lower != nil ? counter.lowercased() : counter.uppercased())
            } else if let counter, let counterRange = find("[0-9]+", counter), let range = find("[0-9]+", bullet) {
                new = bullet.replacingCharacters(in: range, with: counter[counterRange])
            } else if alphap, let range = find("[A-Z]", bullet) {
                new = bullet.replacingCharacters(in: range, with: "A")
            } else if alphap, let range = find("[a-z]", bullet) {
                new = bullet.replacingCharacters(in: range, with: "a")
            } else if let range = find("([0-9]+|[A-Za-z])", bullet) {
                new = bullet.replacingCharacters(in: range, with: "1")
            } else {
                new = bullet
            }
            structure.set(pos) { $0.bullet = bulletString(new) }
        }
    }

    /// `org-list-use-alpha-bul-p`: the list starting at `first` fits in the alphabet.
    func useAlphabeticalBullets(_ first: Int, _ structure: ListStruct, _ prevs: [Int: Int]) -> Bool {
        guard options.listAllowAlphabetical else { return false }
        var item: Int? = first
        var ascii = 64
        while let current = item {
            if let counter = structure.item(current)?.counter, let letter = counter.first, letter.isASCII, letter.isLetter {
                ascii = Int(letter.uppercased().unicodeScalars.first!.value)
            } else {
                ascii += 1
            }
            if ascii > 90 { return false }
            item = structure.nextItem(current, prevs)
        }
        return true
    }

    /// `org-list-struct-fix-ind`.
    func fixIndentation(_ structure: inout ListStruct, _ parents: [(item: Int, parent: Int?)], bulletSize: Int? = nil) {
        let topInd = structure.ind(structure.top)
        for pos in structure.dropFirst().map(\.pos) {
            if let parent = structure.parent(pos, parents) {
                let ind = (bulletSize ?? (structure.bullet(parent) as NSString).length) + structure.ind(parent)
                structure.set(pos) { $0.ind = ind }
            } else {
                structure.set(pos) { $0.ind = topInd }
            }
        }
    }

    /// `org-list-struct-fix-box` without ORDERED.
    func fixCheckboxes(_ structure: inout ListStruct, _ parents: [(item: Int, parent: Int?)]) {
        var parentList: [Int] = []
        for pos in structure.map(\.pos) {
            guard let parent = structure.parent(pos, parents), structure.checkbox(parent) != nil, !parentList.contains(parent) else { continue }
            parentList.insert(parent, at: 0)
        }
        // `sort` in Emacs is stable; ties keep their order.
        let ordered = parentList.enumerated().sorted { lhs, rhs in
            let (a, b) = (structure.ind(lhs.element), structure.ind(rhs.element))
            return a != b ? a > b : lhs.offset < rhs.offset
        }.map(\.element)
        for item in ordered {
            let boxes = structure.children(item, parents).map { structure.checkbox($0) }
            let new: String?
            if boxes.contains("[ ]"), boxes.contains("[X]") {
                new = "[-]"
            } else if boxes.contains("[-]") {
                new = "[-]"
            } else if boxes.contains("[X]") {
                new = "[X]"
            } else if boxes.contains("[ ]") {
                new = "[ ]"
            } else {
                new = structure.checkbox(item)
            }
            structure.set(item) { $0.checkbox = new }
        }
    }

    /// `org-list-struct-fix-item-end`.
    func fixItemEnds(_ structure: inout ListStruct) {
        var endList: [(ind: Int, pos: Int)] = []
        var accEnd: [(end: Int, pos: Int)] = []
        for item in structure {
            if structure.item(item.end) == nil {
                let up = accEnd.first { item.end < $0.end }?.pos
                endList.insert((up.map { structure.ind($0) + 2 } ?? 0, item.end), at: 0)
            }
            endList.insert((item.ind, item.pos), at: 0)
            accEnd.insert((item.end, item.pos), at: 0)
        }
        let sorted = endList.enumerated().sorted { $0.element.pos != $1.element.pos ? $0.element.pos < $1.element.pos : $0.offset < $1.offset }.map(\.element)
        assocEnd(&structure, sorted)
    }

    /// The previous match data, with groups it lacks as unmatched.
    private var staleMatch: [Range<Int>?] {
        lastMatch + Array(repeating: nil, count: max(0, 6 - lastMatch.count))
    }

    /// `org-list-struct-apply-struct`.
    func applyStruct(_ structure: ListStruct, _ old: ListStruct) {
        let origin = marker(point)
        defer {
            point = origin.position
            release(origin)
        }
        func shiftBody(end: Int, begin: Int, delta: Int, ind: Int?) {
            point = end
            skipBackward(Self.whitespace)
            beginningOfLine()
            while point > begin || (point == begin && looking(itemPattern) == nil) {
                if looking("^[ \\t]*\\S", setsMatch: false) != nil {
                    indentLineTo(max(currentTextIndentation + delta, ind.map { $0 + 1 } ?? -1))
                }
                if point == 0 { break }
                forwardLine(-1)
            }
        }
        func modify(_ item: Int) {
            point = item
            let newInd = structure.ind(item)
            let oldInd = currentTextIndentation
            let newBullet = bulletString(structure.bullet(item))
            let oldBullet = old.bullet(item)
            let newBox = structure.checkbox(item)
            // A failed `looking-at' leaves the previous match data, which org then uses; this
            // happens when a split item takes a sub-list with it.
            var match = looking(Self.fullItemPattern) ?? staleMatch
            if oldBullet != newBullet {
                var keepSpace = ""
                saveExcursion {
                    let bulletRange = match[1]!
                    if bulletRange.lowerBound <= origin.position, origin.position <= bulletRange.upperBound {
                        let spaces = saveExcursion { () -> String? in
                            point = origin.position
                            return looking("[ \\t]+", setsMatch: false).map { substring($0[0]!.lowerBound, $0[0]!.upperBound) }
                        }
                        keepSpace = spaces ?? ""
                    }
                    replace(bulletRange, with: "")
                    point = bulletRange.lowerBound
                    insertBeforeMarkers(newBullet)
                    insert(keepSpace)
                }
            }
            point = item
            match = looking(Self.fullItemPattern) ?? staleMatch
            let oldBox = match[3].map { substring($0.lowerBound, $0.upperBound) }
            if oldBox == newBox {
            } else if let boxRange = match[3], let newBox {
                replace(boxRange, with: newBox)
            } else if oldBox != nil {
                let box = looking(".*?([ \\t]*\\[[ X-]\\])")!
                replace(box[1]!, with: "")
            } else if let newBox {
                let counterEnd = match[2]?.upperBound
                point = counterEnd.map { $0 + 1 } ?? match[1]!.upperBound
                insert(newBox + (counterEnd == nil ? " " : ""))
            }
            if newInd != oldInd {
                point = lineStart(point)
                let start = point
                skipForward(Self.blanks)
                deleteRegion(start, point)
                indentTo(newInd)
            }
        }
        var endList: [(end: Int, up: Int?)] = []
        var accEnd: [(end: Int, pos: Int)] = []
        var shifts: [Int: (delta: Int, ind: Int)] = [:]
        for entry in old {
            let pos = entry.pos
            let indNew = structure.ind(pos), indOld = entry.ind
            let delta = (indNew + (structure.bullet(pos) as NSString).length) - (indOld + (entry.bullet as NSString).length)
            shifts[pos] = (delta, indNew)
            if old.item(entry.end) == nil {
                endList.insert((entry.end, accEnd.first { entry.end < $0.end }?.pos), at: 0)
            }
            accEnd.insert((entry.end, pos), at: 0)
        }
        var uniqueEnds: [Int] = []
        for end in endList.map(\.end) where !uniqueEnds.contains(end) { uniqueEnds.append(end) }
        var allEnds = (old.map(\.pos) + uniqueEnds).sorted()
        accEnd.reverse()
        var slices: [(down: Int, up: Int, delta: Int, ind: Int?)] = []
        while allEnds.count > 1 {
            let up = allEnds.removeFirst()
            let down = allEnds[0]
            let isItem = structure.item(up) != nil
            let delta: Int
            if isItem {
                delta = shifts[up]!.delta
            } else {
                let child = accEnd.first { $0.end == up }!.pos
                let ind = structure.ind(child)
                var minInd = Int.max
                saveExcursion {
                    point = up
                    while point < down {
                        if looking("[ \\t]*$", setsMatch: false) == nil {
                            minInd = min(currentTextIndentation, minInd)
                            if let open = looking("#\\+BEGIN(:|_\\S+)") {
                                let name = NSRegularExpression.escapedPattern(for: substring(open[1]!.lowerBound, open[1]!.upperBound))
                                searchForward("^[ \\t]*#\\+END\(name)[ \\t]*$", bound: down)
                            } else if looking(Self.drawerPattern) != nil {
                                searchForward("^[ \\t]*:END:[ \\t]*$", bound: down)
                            }
                        }
                        if forwardLine(1) != 0 { break }
                    }
                }
                delta = ind - minInd
            }
            slices.insert((down, up, delta, isItem ? shifts[up]!.ind : nil), at: 0)
        }
        for slice in slices {
            if slice.delta != 0 { shiftBody(end: slice.down, begin: slice.up, delta: slice.delta, ind: slice.ind) }
            if let cell = structure.item(slice.up), cell != old.item(slice.up) { modify(slice.up) }
        }
    }

    /// `org-list-write-struct`.
    func writeStruct(_ structure: inout ListStruct, _ parents: [(item: Int, parent: Int?)], old: ListStruct? = nil) {
        let old = old ?? structure
        fixIndentation(&structure, parents, bulletSize: 2)
        fixItemEnds(&structure)
        let prevs = structure.prevs
        fixBullets(&structure, prevs)
        fixIndentation(&structure, parents)
        fixCheckboxes(&structure, parents)
        applyStruct(structure, old)
    }
}
