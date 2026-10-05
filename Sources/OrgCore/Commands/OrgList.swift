import Foundation

// Org's plain list machinery (org-list.el, Org 9.8.7) on `EmacsBuffer`: the list structure,
// its repairs (bullets, indentation, checkboxes) and how changes are written back. Defaults as
// in org: `org-list-allow-alphabetical` nil, `org-plain-list-ordered-item-terminator` t,
// `org-list-indent-offset` 0, `org-list-demote-modify-bullet` nil,
// `org-list-two-spaces-after-bullet-regexp` nil, `org-blank-before-new-entry` items `auto`,
// `org-checkbox-hierarchical-statistics` t, `indent-tabs-mode` nil.

/// One item of `org-list-struct`.
struct ListItem: Equatable {
    var pos: Int
    var ind: Int
    /// With its trailing whitespace.
    var bullet: String
    var counter: String?
    var checkbox: String?
    var tag: String?
    var end: Int
}

/// Items in buffer order.
typealias ListStruct = [ListItem]

extension ListStruct {
    func item(_ pos: Int) -> ListItem? { first { $0.pos == pos } }
    func index(of pos: Int) -> Int? { firstIndex { $0.pos == pos } }
    func ind(_ pos: Int) -> Int { item(pos)!.ind }
    func bullet(_ pos: Int) -> String { item(pos)!.bullet }
    func checkbox(_ pos: Int) -> String? { item(pos)?.checkbox }
    func end(_ pos: Int) -> Int { item(pos)!.end }
    mutating func set(_ pos: Int, _ change: (inout ListItem) -> Void) {
        if let i = index(of: pos) { change(&self[i]) }
    }

    var top: Int { self[0].pos }
    var bottom: Int { map(\.end).max()! }

    /// `org-list-prevs-alist`: item to previous item in its sub-list.
    var prevs: [Int: Int] {
        var byEnd: [Int: Int] = [:]
        for item in self where byEnd[item.end] == nil { byEnd[item.end] = item.pos }
        var result: [Int: Int] = [:]
        for item in self { if let previous = byEnd[item.pos] { result[item.pos] = previous } }
        return result
    }

    /// `org-list-parents-alist`, in buffer order.
    var parents: [(item: Int, parent: Int?)] {
        var indToOri: [(ind: Int, origin: Int?)] = [(self[0].ind, nil)]
        var previousPositions = [top]
        var result: [(Int, Int?)] = [(top, nil)]
        for item in dropFirst() {
            let previousInd = indToOri[0].ind
            previousPositions.insert(item.pos, at: 0)
            if previousInd > item.ind {
                if let i = indToOri.firstIndex(where: { $0.ind == item.ind }) {
                    indToOri.removeFirst(i)
                } else if let i = indToOri.firstIndex(where: { $0.ind < item.ind }) {
                    indToOri.removeFirst(i)
                } else {
                    indToOri = [(item.ind, nil)]
                }
                result.append((item.pos, indToOri[0].origin))
            } else if previousInd < item.ind {
                let origin = previousPositions[1]
                indToOri.insert((item.ind, origin), at: 0)
                result.append((item.pos, origin))
            } else {
                result.append((item.pos, indToOri[0].origin))
            }
        }
        return result
    }

    func nextItem(_ pos: Int, _ prevs: [Int: Int]) -> Int? { first { prevs[$0.pos] == pos }?.pos }
    func previousItem(_ pos: Int, _ prevs: [Int: Int]) -> Int? { prevs[pos] }

    func hasChild(_ pos: Int) -> Int? {
        guard let i = index(of: pos), i + 1 < count, self[i + 1].ind > self[i].ind else { return nil }
        return self[i + 1].pos
    }

    func subtree(_ pos: Int) -> [Int] {
        guard let i = index(of: pos) else { return [] }
        let end = self[i].end
        return self[(i + 1)...].prefix { $0.pos < end }.map(\.pos)
    }

    func children(_ pos: Int, _ parents: [(item: Int, parent: Int?)]) -> [Int] {
        parents.filter { $0.parent == pos }.map(\.item)
    }

    func parent(_ pos: Int, _ parents: [(item: Int, parent: Int?)]) -> Int? {
        parents.first { $0.item == pos }?.parent ?? nil
    }

    func listBegin(_ pos: Int, _ prevs: [Int: Int]) -> Int {
        var first = pos
        while let previous = prevs[first] { first = previous }
        return first
    }

    func lastItem(_ pos: Int, _ prevs: [Int: Int]) -> Int {
        var last = pos
        while let next = nextItem(last, prevs) { last = next }
        return last
    }

    func allItems(_ pos: Int, _ prevs: [Int: Int]) -> [Int] {
        var before: [Int] = []
        var item = pos
        while let previous = prevs[item] {
            before.insert(previous, at: 0)
            item = previous
        }
        var after: [Int] = []
        item = pos
        while let next = nextItem(item, prevs) {
            after.append(next)
            item = next
        }
        return before + [pos] + after
    }

    enum ListType { case ordered, descriptive, unordered }

    func listType(_ pos: Int, _ prevs: [Int: Int]) -> ListType {
        let first = item(listBegin(pos, prevs))!
        if first.bullet.contains(where: { $0.isLetter || $0.isNumber }) { return .ordered }
        return first.tag != nil ? .descriptive : .unordered
    }
}

/// `org-list-struct-assoc-end`: gives each item the first ending at its indentation or less.
private func assocEnd(_ structure: inout ListStruct, _ endList: [(ind: Int, pos: Int)]) {
    var endings = endList[...]
    for i in structure.indices {
        let item = structure[i]
        while let first = endings.first, first.pos <= item.pos { endings = endings.dropFirst() }
        structure[i].end = endings.first { $0.ind <= item.ind }?.pos ?? structure[i].end
    }
}

/// `org-list-bullet-string`: one space after the bullet's text.
func bulletString(_ bullet: String) -> String {
    guard let range = bullet.range(of: "\\S+([ \\t]*)", options: .regularExpression) else { return bullet }
    let text = bullet[range]
    let core = text.prefix { !$0.isWhitespace }
    return bullet[..<range.lowerBound] + core + " " + bullet[range.upperBound...]
}

extension EmacsBuffer {
    // MARK: - Lines and searching

    /// `org-current-text-indentation` of the line at point.
    var currentTextIndentation: Int {
        var at = lineStart(point)
        var column = 0
        while let c = character(at: at), c == 32 || c == 9 {
            column = c == 9 ? (column / 8 + 1) * 8 : column + 1
            at += 1
        }
        return column
    }

    private func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression {
        EmacsBuffer.regex(pattern, caseInsensitive: caseInsensitive)
    }

    /// `looking-at`; with `setsMatch` false, `looking-at-p` or inside `save-match-data`.
    func looking(_ pattern: String, caseInsensitive: Bool = true, setsMatch: Bool = true) -> [Range<Int>?]? {
        let match = regex(pattern, caseInsensitive: caseInsensitive).firstMatch(in: string, options: Self.lookingOptions, range: NSRange(point..<length))
        let groups = match.map(ranges)
        if let groups, setsMatch { lastMatch = groups }
        return groups
    }

    private func ranges(_ match: NSTextCheckingResult) -> [Range<Int>?] {
        (0..<match.numberOfRanges).map { i in
            let range = match.range(at: i)
            return range.location == NSNotFound ? nil : range.location..<NSMaxRange(range)
        }
    }

    /// `re-search-forward` with a bound and no error: point to the match end; nil leaves point.
    @discardableResult
    func searchForward(_ pattern: String, bound: Int? = nil, caseInsensitive: Bool = true, move: Bool = false) -> [Range<Int>?]? {
        let limit = min(bound ?? length, length)
        guard point <= limit else { return nil }
        guard let match = regex(pattern, caseInsensitive: caseInsensitive).firstMatch(in: string, options: Self.searchOptions, range: NSRange(point..<limit)) else {
            if move { point = limit }
            return nil
        }
        let groups = ranges(match)
        point = groups[0]!.upperBound
        lastMatch = groups
        return groups
    }

    /// `re-search-backward` with a bound and no error: the match closest before point that
    /// ends by point; point to its start.
    @discardableResult
    func searchBackward(_ pattern: String, bound: Int? = nil, caseInsensitive: Bool = true) -> [Range<Int>?]? {
        let lower = max(bound ?? 0, 0)
        guard lower <= point else { return nil }
        let expression = regex(pattern, caseInsensitive: caseInsensitive)
        var start = point
        while start >= lower {
            if let match = expression.firstMatch(in: string, options: Self.lookingOptions, range: NSRange(start..<point)) {
                let groups = ranges(match)
                point = start
                lastMatch = groups
                return groups
            }
            start -= 1
        }
        return nil
    }

    /// `indent-to` with spaces.
    func indentTo(_ column: Int) {
        let current = currentColumn
        if column > current { insert(String(repeating: " ", count: column - current)) }
    }

    /// `indent-line-to` with spaces and a tab width of 8.
    func indentLineTo(_ column: Int) {
        beginningOfLine()
        skipForward(Self.blanks)
        let current = currentColumn
        if current < column {
            if column - (current / 8) * 8 >= 8 {
                let end = point
                skipBackward([32])
                deleteRegion(point, end)
            }
            indentTo(column)
        } else if current > column {
            moveToColumn(column, force: true)
            let start = point
            beginningOfLine()
            skipForward(Self.blanks)
            deleteRegion(start, point)
        }
    }

    // MARK: - Context

    static let itemPattern = "([ \\t]*([-+]|(([0-9]+)[.)]))|[ \\t]+\\*)([ \\t]+|$)"
    static let itemBeginningPattern = "^" + itemPattern
    static let fullItemPattern = "^[ \\t]*((?:[-+*]|(?:[0-9]+|[A-Za-z])[.)])(?:[ \\t]+|$))(?:\\[@(?:start:)?([0-9]+|[A-Za-z])\\][ \\t]*)?(?:(\\[[ X-]\\])(?:[ \\t]+|$))?(?:(.*)[ \\t]+::(?:[ \\t]+|$))?"
    static let listEndPattern = "^[ \\t]*\\n[ \\t]*\\n"
    static let drawerPattern = "^[ \\t]*:([-_\\w]+):[ \\t]*$"
    static let forbiddenBlocks = ["example", "verse", "src", "export"]

    enum ListContextKind: Equatable { case none, drawer, block(String), invalid }

    /// `org-list-context`.
    func listContext() -> (up: Int, down: Int, kind: ListContextKind) {
        let savedMatch = lastMatch
        defer { lastMatch = savedMatch }
        return saveExcursion {
            beginningOfLine()
            let pos = point
            var up = saveExcursion { (try? backToHeading()) ?? 0 }
            var down = saveExcursion { outlineNextHeading() ? point : length }
            var kind = ListContextKind.none
            let drawerEnd = "^[ \\t]*:END:"
            if looking(Self.drawerPattern) == nil, looking(drawerEnd) == nil {
                let found = saveExcursion { () -> (Int, Int)? in
                    guard searchBackward(Self.drawerPattern, bound: up) != nil else { return nil }
                    let begin = lineEnd(point) + 1
                    let end = searchForward(drawerEnd, bound: down).map { $0[0]!.lowerBound - 1 } ?? down
                    return end >= pos ? (begin, end) : nil
                }
                if let (begin, end) = found {
                    (up, down, kind) = (begin, end, .drawer)
                }
            }
            let blockPattern = "^[ \\t]*#\\+(begin|end)_"
            if looking(blockPattern) == nil {
                let found = saveExcursion { () -> (Int, Int, String)? in
                    guard searchBackward(blockPattern, bound: up) != nil else { return nil }
                    let begin = lineEnd(point) + 1
                    guard let open = looking("^[ \\t]*#\\+begin_(\\S+)") else { return nil }
                    let type = substring(open[1]!.lowerBound, open[1]!.upperBound).lowercased()
                    point = begin
                    let close = searchForward(blockPattern, bound: down)
                    let end = close.map { _ in lineStart(point) - 1 } ?? down
                    guard end >= pos else { return nil }
                    let word = close.map { substring($0[1]!.lowerBound, $0[1]!.upperBound) } ?? type
                    return word.lowercased() == "end" ? (begin, end, type) : nil
                }
                if let (begin, end, type) = found {
                    (up, down, kind) = (begin, end, Self.forbiddenBlocks.contains(type) ? .invalid : .block(type))
                }
            }
            return (up, down, kind)
        }
    }

    /// `org-in-item-p`: the start of the item holding point, or nil.
    func inItem() -> Int? {
        saveExcursion {
            beginningOfLine()
            let context = listContext()
            var reference = looking("^[ \\t]*$") != nil ? 10000 : currentTextIndentation
            if context.kind == .invalid { return nil }
            if looking(Self.itemPattern) != nil { return point }
            // Inside `org-list-end-re`: start above it.
            let windowStart = saveExcursion { forwardLine(-2); return point }
            let windowEnd = saveExcursion { forwardLine(2); return lineEnd(point) }
            let expression = regex(Self.listEndPattern, caseInsensitive: true)
            for match in expression.matches(in: string, options: Self.searchOptions, range: NSRange(windowStart..<windowEnd)) {
                let range = match.range.location..<NSMaxRange(match.range)
                if point >= range.lowerBound, point < range.upperBound {
                    point = range.lowerBound
                    forwardLine(-1)
                    break
                }
            }
            while true {
                let ind = currentTextIndentation
                if looking(Self.itemPattern) != nil, ind < reference { return point }
                if point <= context.up { return nil }
                if looking(Self.listEndPattern) != nil { return nil }
                if looking("^[ \\t]*#\\+end_") != nil, searchBackward("^[ \\t]*#\\+begin_", bound: context.up) != nil {
                    continue
                }
                if looking("^[ \\t]*:END:") != nil, searchBackward(Self.drawerPattern, bound: context.up) != nil {
                    beginningOfLine()
                    continue
                }
                if looking("^[ \\t]*$") != nil {
                    forwardLine(-1)
                    continue
                }
                if ind == 0 { return nil }
                if ind < reference { reference = ind }
                forwardLine(-1)
            }
        }
    }

    /// `org-at-item-p`: an item line where the element parser sees one, so not in blocks
    /// whose contents aren't elements.
    var atItem: Bool {
        saveExcursion {
            beginningOfLine()
            switch listContext().kind {
            case .invalid, .block("comment"), .block("verse"): return false
            default: return looking(Self.itemPattern) != nil
            }
        }
    }

    // MARK: - Structure

    private func assocAtPoint(_ ind: Int) -> ListItem {
        let match = looking(Self.fullItemPattern)!
        func group(_ i: Int) -> String? { match[i].map { substring($0.lowerBound, $0.upperBound) } }
        let bullet = group(1) ?? ""
        let tag = bullet.range(of: "[-+*]", options: .regularExpression) != nil ? group(4) : nil
        return ListItem(pos: point, ind: ind, bullet: bullet, counter: group(2), checkbox: group(3), tag: tag, end: 0)
    }

    /// `org-list-struct` for the list holding point, which is at an item.
    func listStruct() -> ListStruct {
        saveExcursion {
            beginningOfLine()
            let context = listContext()
            var textMinInd = 10000
            var beginCell = (pos: point, ind: currentTextIndentation)
            var items: [ListItem] = []
            var ends: [(ind: Int, pos: Int)] = []
            func endBeforeBlank() -> Int {
                skipBackward(Self.whitespace)
                return min(lineEnd(point) + 1, context.down)
            }
            func trimToBegin() {
                if let i = items.firstIndex(where: { $0.pos == beginCell.pos }) { items = Array(items[i...]) } else { items = [] }
            }
            saveExcursion {
                while true {
                    let ind = currentTextIndentation
                    if point <= context.up {
                        if looking(Self.itemPattern) == nil {
                            trimToBegin()
                        } else {
                            beginCell = (point, ind)
                            items.insert(assocAtPoint(ind), at: 0)
                        }
                        return
                    }
                    if looking(Self.listEndPattern) != nil {
                        trimToBegin()
                        return
                    }
                    if looking(Self.itemPattern) != nil {
                        items.insert(assocAtPoint(ind), at: 0)
                        ends.insert((ind, point), at: 0)
                        if ind < textMinInd { beginCell = (point, ind) }
                        forwardLine(-1)
                    } else if looking("^[ \\t]*#\\+end_") != nil, searchBackward("^[ \\t]*#\\+begin_", bound: context.up) != nil {
                    } else if looking("^[ \\t]*:END:") != nil, searchBackward(Self.drawerPattern, bound: context.up) != nil {
                        beginningOfLine()
                    } else if looking("^[ \\t]*$") != nil {
                        forwardLine(-1)
                    } else if ind == 0 {
                        trimToBegin()
                        return
                    } else {
                        if ind < textMinInd { textMinInd = ind }
                        ends.insert((ind, point), at: 0)
                        forwardLine(-1)
                    }
                }
            }
            var items2: [ListItem] = []
            var ends2: [(ind: Int, pos: Int)] = []
            while true {
                let ind = currentTextIndentation
                if point >= context.down {
                    ends2.append((0, endBeforeBlank()))
                    break
                }
                if looking(Self.listEndPattern) != nil {
                    ends2.append((0, point))
                    break
                }
                if looking(Self.itemPattern) != nil {
                    items2.append(assocAtPoint(ind))
                    ends2.append((ind, point))
                    forwardLine(1)
                } else if looking("^[ \\t]*$") != nil {
                    forwardLine(1)
                } else if ind <= beginCell.ind {
                    ends2.append((0, endBeforeBlank()))
                    break
                } else {
                    if let last = items2.last, ind <= last.ind { ends2.append((ind, point)) }
                    if looking("^[ \\t]*#\\+begin_") != nil, searchForward("^[ \\t]*#\\+end_", bound: context.down) != nil {
                    } else if looking(Self.drawerPattern) != nil, searchForward("^[ \\t]*:END:", bound: context.down) != nil {
                    }
                    forwardLine(1)
                }
            }
            var structure = items + Array(items2.dropFirst())
            assocEnd(&structure, ends + Array(ends2.dropFirst()))
            return structure
        }
    }

    func itemEndBeforeBlank(_ pos: Int, _ structure: ListStruct) -> Int {
        saveExcursion {
            point = structure.end(pos)
            skipBackward(Self.whitespace)
            return lineEnd(point)
        }
    }

    // MARK: - Editing structures

    /// `org-list-swap-items`.
    func swapItems(_ a: Int, _ b: Int, _ structure: ListStruct) -> ListStruct {
        saveExcursion {
            let endANoBlank = itemEndBeforeBlank(a, structure)
            let endBNoBlank = itemEndBeforeBlank(b, structure)
            let endA = structure.end(a), endB = structure.end(b)
            let sizeA = endANoBlank - a, sizeB = endBNoBlank - b
            let bodyA = substring(a, endANoBlank), bodyB = substring(b, endBNoBlank)
            let between = substring(endANoBlank, b)
            let subA = [a] + structure.subtree(a), subB = [b] + structure.subtree(b)
            point = a
            deleteRegion(a, endBNoBlank)
            insert(bodyB + between + bodyA)
            var result = structure
            for i in result.indices {
                let pos = result[i].pos, end = result[i].end
                if pos < a {
                } else if subA.contains(pos) {
                    result[i].pos = pos + (endBNoBlank - endANoBlank)
                    result[i].end = end + (endBNoBlank - endANoBlank)
                    if end == endA { result[i].end = endB }
                } else if subB.contains(pos) {
                    result[i].pos = pos + a - b
                    result[i].end = end + (a - b)
                    if end == endB { result[i].end = a + sizeB + (endA - endANoBlank) }
                } else if pos < b {
                    result[i].pos = pos + (sizeB - sizeA)
                    result[i].end = end + (sizeB - sizeA)
                }
            }
            return result.sorted { $0.pos < $1.pos }
        }
    }

    /// `org-list-separating-blank-lines-number`, with point at the item.
    func separatingBlankLines(_ pos: Int, _ structure: ListStruct, _ prevs: [Int: Int]) -> Int {
        saveExcursion {
            let item = point
            func countBlanks() -> Int {
                saveExcursion {
                    point = lineStart(point)
                    let start = point
                    skipBackward(Self.whitespace)
                    forwardLine(1)
                    return countLines(point, start)
                }
            }
            if let next = structure.nextItem(item, prevs) {
                point = next
                return countBlanks()
            }
            if structure.previousItem(item, prevs) != nil { return countBlanks() }
            if pos > itemEndBeforeBlank(item, structure) {
                let blanks = saveExcursion { point = pos; return countBlanks() }
                if blanks > 0 { return blanks }
            }
            point = structure.top
            if searchForward("^[ \\t]*$", bound: itemEndBeforeBlank(item, structure)) != nil { return 1 }
            return 0
        }
    }

    /// `count-lines` between two positions.
    func countLines(_ start: Int, _ end: Int) -> Int {
        let (lower, upper) = (min(start, end), max(start, end))
        guard upper > lower else { return 0 }
        let newlines = substring(lower, upper).utf16.filter { $0 == 10 }.count
        return character(at: upper - 1) == Self.newline ? newlines : newlines + 1
    }

    /// `org-list-insert-item`. Leaves point at the new item.
    func insertItem(at position: Int, _ structure: ListStruct, _ prevs: [Int: Int], checkbox: Bool, afterBullet: String?, splitLine: Bool = true) -> ListStruct {
        var pos = position
        var found: Int?
        var stopped = false
        for entry in structure {
            if entry.pos > pos {
                stopped = true
                break
            }
            if entry.end < pos { continue }
            found = entry.pos
        }
        guard let item = stopped ? found : (found ?? structure.last?.pos) else { return structure }
        let itemEnd = structure.end(item)
        let itemEndNoBlank = itemEndBeforeBlank(item, structure)
        point = item
        let match = looking(Self.fullItemPattern)!
        let bodyStart: Int
        if match[4] == nil {
            bodyStart = match[0]!.upperBound
        } else if substring(match[1]!.lowerBound, match[1]!.upperBound).contains(where: { $0 == "." || $0 == ")" }) {
            bodyStart = match[4]!.lowerBound
        } else {
            bodyStart = saveExcursion { point = match[4]!.upperBound; skipForward(Self.blanks); return point }
        }
        let before = pos <= bodyStart
        let blanks = separatingBlankLines(pos, structure, prevs)
        let ind = structure.ind(item)
        let bullet = bulletString(structure.bullet(item))
        let box = checkbox ? "[ ]" : nil
        var textCut: String?
        if !before, splitLine {
            point = pos
            if itemEnd < pos { deleteRegion(itemEnd - 1, lineEnd(point)) }
            skipBackward(Self.whitespace)
            pos = saveExcursion { skipForward(Self.blanks); return point }
            textCut = substring(point, itemEndNoBlank)
            deleteRegion(point, itemEndNoBlank)
        }
        var body = bullet + (box.map { $0 + " " } ?? "") + (afterBullet ?? "")
        if let textCut {
            // `string-match' sets the match data to the string's blanks.
            let blanks = textCut.prefix { $0 == " " || $0 == "\t" }.utf16.count
            if blanks > 0 { lastMatch = [0..<blanks] }
            body += textCut.replacingOccurrences(of: "^[ \\t]+", with: "", options: .regularExpression)
        }
        let separator = String(repeating: "\n", count: blanks + 1)
        let itemSize = ind + (body as NSString).length + (separator as NSString).length
        let sizeOffset = itemSize - ((textCut ?? "") as NSString).length
        point = item
        indentTo(ind)
        insert(body + separator)
        var result = structure
        for i in result.indices {
            let p = result[i].pos, end = result[i].end
            if p < item {
                if end > item { result[i].end = end + sizeOffset }
            } else if p == item, !before, splitLine {
                result[i].pos = p + itemSize
                result[i].end = end + sizeOffset
            } else if splitLine, !before, p >= pos, p <= itemEndNoBlank {
                let offset = pos - item - ind - (bullet as NSString).length - ((afterBullet ?? "") as NSString).length
                result[i].pos = p - offset
                result[i].end = end - offset
            } else {
                result[i].pos = p + sizeOffset
                result[i].end = end + sizeOffset
            }
        }
        result.append(ListItem(pos: item, ind: ind, bullet: bullet, counter: nil, checkbox: box, tag: nil, end: item + itemSize))
        result.sort { $0.pos < $1.pos }
        if before {
            point = item
        } else {
            result = swapItems(item, item + itemSize, result)
            point = result.nextItem(item, result.prevs)!
        }
        return result
    }

    /// `org-list-delete-item`.
    func deleteItem(_ item: Int, _ structure: ListStruct) -> ListStruct {
        let end = structure.end(item)
        let begin = structure.bottom == end ? saveExcursion { () -> Int in
            point = item
            skipBackward(Self.whitespace)
            return min(lineEnd(point) + 1, length)
        } : item
        deleteRegion(begin, end)
        let size = end - begin
        return structure.compactMap { entry in
            var entry = entry
            if entry.pos < item {
                if entry.end == item { entry.end = begin } else if entry.end > item { entry.end -= size }
                return entry
            }
            if entry.pos < end { return nil }
            entry.pos -= size
            entry.end -= size
            return entry
        }
    }

    enum SendDestination { case begin, end }

    /// `org-list-send-item` to the start or end of the item's sub-list.
    func sendItem(_ item: Int, to destination: SendDestination, _ structure: ListStruct) -> ListStruct {
        let prevs = structure.prevs
        let itemEnd = structure.end(item)
        let bulletEnd = saveExcursion { () -> Int in
            point = item
            return looking("[ \\t]*" + NSRegularExpression.escapedPattern(for: structure.bullet(item)))![0]!.upperBound
        }
        let body = substring(bulletEnd, itemEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        let insertion: Int
        switch destination {
        case .begin:
            insertion = structure.listBegin(item, prevs)
        case .end:
            insertion = saveExcursion { () -> Int in
                point = structure.lastItem(item, prevs)
                return lineEnd(point)
            }
        }
        guard item != insertion else { return structure }
        let itemMarker = marker(item)
        defer { release(itemMarker) }
        var result = insertItem(at: insertion, structure, prevs, checkbox: false, afterBullet: body, splitLine: false)
        let moved = [itemMarker.position] + result.subtree(itemMarker.position)
        let newEnd = result.end(point)
        let oldEnd = result.end(itemMarker.position)
        let newItem = point
        let shift = point - itemMarker.position
        result.removeAll { $0.pos == newItem }
        let copies = moved.map { pos -> ListItem in
            var cell = result.item(pos)!
            cell.end = cell.end == oldEnd ? newEnd : cell.end + shift
            cell.pos = pos + shift
            return cell
        }
        result = (result + copies).sorted { $0.pos < $1.pos }
        return deleteItem(itemMarker.position, result)
    }

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
        for pos in structure.map(\.pos) {
            let previous = prevs[pos]
            let counter = structure.item(pos)!.counter
            let bullet = structure.bullet(pos)
            let new: String
            if let previous, let counter, counter.range(of: "[a-zA-Z]", options: .regularExpression) != nil,
               structure.bullet(previous).range(of: "[a-zA-Z]", options: .regularExpression) != nil {
                let previousBullet = structure.bullet(previous)
                let real = previousBullet.range(of: "[a-z]", options: .regularExpression) != nil ? counter.lowercased() : counter.uppercased()
                let range = previousBullet.range(of: "[a-zA-Z]", options: .regularExpression)!
                new = previousBullet.replacingCharacters(in: range, with: real)
            } else if let previous, let counter, let counterRange = counter.range(of: "[0-9]+", options: .regularExpression),
                      let range = structure.bullet(previous).range(of: "[0-9]+", options: .regularExpression) {
                new = structure.bullet(previous).replacingCharacters(in: range, with: counter[counterRange])
            } else if let previous {
                new = incrementBullet(structure.bullet(previous))
            } else if let counter, let counterRange = counter.range(of: "[0-9]+", options: .regularExpression),
                      let range = bullet.range(of: "[0-9]+", options: .regularExpression) {
                new = bullet.replacingCharacters(in: range, with: counter[counterRange])
            } else if let range = bullet.range(of: "([0-9]+|[A-Za-z])", options: .regularExpression) {
                stringMatched(bullet, range)
                new = bullet.replacingCharacters(in: range, with: "1")
            } else {
                new = bullet
            }
            structure.set(pos) { $0.bullet = bulletString(new) }
        }
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
            while point > begin || (point == begin && looking(Self.itemPattern) == nil) {
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
