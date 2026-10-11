import Foundation

// Plain list commands from org-list.el (Org 9.8.7) on `EmacsBuffer`, matched to Emacs by the
// oracle tests. The ORDERED property is not handled.

extension EmacsBuffer {
    /// `org-insert-item`. False when point isn't in an item.
    func insertListItem(checkbox: Bool) -> Bool {
        guard let start = inItem() else { return false }
        let pos = point
        var structure = saveExcursion { point = start; return listStruct() }
        let prevs = structure.prevs
        let description = structure.listType(start, prevs) == .descriptive ? " :: " : nil
        structure = insertItem(at: pos, structure, prevs, checkbox: checkbox, afterBullet: description, splitLine: options.metaReturnMaySplitLine)
        writeStruct(&structure, structure.parents)
        if checkbox { updateCheckboxCount() }
        forwardLine(0)
        let match = looking(Self.fullItemPattern)!
        if let tag = match[4], substring(match[1]!.lowerBound, match[1]!.upperBound).contains(where: { $0 == "." || $0 == ")" }) {
            point = tag.lowerBound
        } else {
            point = match[0]!.upperBound
        }
        if description != nil { point -= 1 }
        return true
    }

    /// `org-list-indent-item-generic` without a region.
    func indentItem(_ direction: Int, subtree: Bool) throws {
        guard atItem else { throw UserError(message: "Not at an item") }
        var structure = listStruct()
        try saveExcursion {
            let top = structure.top
            let parents = structure.parents
            let prevs = structure.prevs
            let line = lineStart(point)
            let special = top == line
            if special, !subtree { throw UserError(message: "At first item: use S-M-<left/right> to move the whole list") }
            let begin = line
            let end = special ? structure.bottom : !subtree ? line + 1 : structure.end(line)
            if special {
                let offset = direction < 0 ? -1 : 1
                let topInd = structure.ind(begin)
                let old = structure
                guard topInd + offset >= 0 else { throw UserError(message: "Cannot outdent beyond margin") }
                if topInd + offset == 0, structure.bullet(begin).contains("*") {
                    structure.set(begin) { $0.bullet = bulletString("-") }
                }
                for i in structure.indices { structure[i].ind += offset }
                fixBullets(&structure, prevs)
                applyStruct(structure, old)
            } else if direction < 0,
                      (!subtree && structure.hasChild(begin) != nil)
                        || structure.hasChild(structure.last { $0.pos < end }!.pos) != nil {
                throw UserError(message: "Cannot outdent an item without its children")
            } else {
                let old = structure
                let newParents = direction < 0
                    ? try structOutdent(begin, end, structure, parents)
                    : try structIndent(begin, end, structure, parents, prevs)
                writeStruct(&structure, newParents, old: old)
                updateCheckboxCount()
            }
        }
    }

    /// `org-move-item-down` and `org-move-item-up`.
    func moveItem(down: Bool) throws {
        guard atItem else { throw UserError(message: "Not at an item") }
        let column = currentColumn
        let item = lineStart(point)
        var structure = listStruct()
        let prevs = structure.prevs
        if down {
            guard let next = structure.nextItem(item, prevs) else { throw UserError(message: "Cannot move this item further down") }
            structure = swapItems(item, next, structure)
            point = structure.nextItem(item, structure.prevs)!
        } else {
            guard let previous = structure.previousItem(item, prevs) else { throw UserError(message: "Cannot move this item further up") }
            structure = swapItems(previous, item, structure)
        }
        writeStruct(&structure, structure.parents)
        moveToColumn(column)
    }

    static let affiliatedKeyword = "^[ \\t]*#\\+(?:attr_[-_A-Za-z0-9]+|caption|data|headers?|label|name|plot|resname|results?|source|srcname|tblname)(?:\\[.*\\])?:"

    /// The first item of the list whose affiliated keywords hold point's line, or nil.
    func affiliatedListStart() -> Int? {
        saveExcursion {
            beginningOfLine()
            guard looking(Self.affiliatedKeyword) != nil else { return nil }
            while looking(Self.affiliatedKeyword) != nil { if forwardLine(1) != 0 { return nil } }
            guard looking(itemPattern) != nil, atItem, inItem() == point else { return nil }
            return point
        }
    }

    /// `org-at-radio-list-p`: point's line is an item of a list whose affiliated keywords have
    /// `#+ATTR_ORG: … :radio` other than `nil`.
    func atRadioList() -> Bool {
        guard saveExcursion({ () -> Bool in beginningOfLine(); return looking(itemPattern) != nil }), let item = inItem() else { return false }
        let structure = saveExcursion { point = item; return listStruct() }
        guard structure.item(item) != nil else { return false }
        var line = structure.listBegin(item, structure.prevs)
        while line > 0 {
            let previous = lineStart(line - 1)
            let keyword = substring(previous, line)
            guard keyword.range(of: Self.affiliatedKeyword, options: [.regularExpression, .caseInsensitive]) != nil else { break }
            if let radio = keyword.firstMatch(of: /(?i)^[ \t]*#\+attr_org:.* :radio (\S+)/) { return radio.1 != "nil" }
            line = previous
        }
        return false
    }

    /// `org-toggle-radio-button`: every item of the list at point unchecked, and the item at
    /// point toggled.
    func toggleRadioButton() throws {
        guard atItem, let item = inItem() else { throw UserError(message: "Cannot toggle checkbox outside of a list") }
        saveExcursion {
            point = item
            var structure = listStruct()
            let old = structure
            let parents = structure.parents
            let box = structure.checkbox(item)
            for pos in structure.allItems(structure.listBegin(item, structure.prevs), structure.prevs) {
                structure.set(pos) { $0.checkbox = "[ ]" }
            }
            structure.set(item) { $0.checkbox = box == "[X]" ? "[ ]" : "[X]" }
            fixCheckboxes(&structure, parents)
            applyStruct(structure, old)
        }
        updateCheckboxCount()
    }

    /// `org-toggle-checkbox` on the item at point.
    func toggleCheckbox() throws {
        if atRadioList() { return try toggleRadioButton() }
        guard atItem else { throw UserError(message: "Not at an item or heading, and no active region") }
        saveExcursion {
            let lower = lineStart(point)
            let upper = marker(lineEnd(point))
            defer { release(upper) }
            point = lower
            let current = looking(itemPattern).flatMap { match -> String? in
                let box = saveExcursion { () -> [Range<Int>?]? in
                    point = match[0]!.upperBound
                    if let counter = looking(options.listAllowAlphabetical ? "(?:\\[@(?:start:)?([0-9]+|[A-Za-z])\\][ \\t]*)" : "(?:\\[@(?:start:)?[0-9]+\\][ \\t]*)") { point = counter[0]!.upperBound }
                    return looking("(\\[[- X]\\])[ \\t]+")
                }
                return box.map { substring($0[1]!.lowerBound, $0[1]!.upperBound) }
            }
            let reference = current == "[X]" ? "[ ]" : "[X]"
            point = lower
            while point < upper.position, searchForward(itemBeginningPattern, bound: upper.position, move: true) != nil {
                var structure = listStruct()
                let old = structure
                let parents = structure.parents
                let bottom = marker(structure.bottom)
                for i in structure.indices where structure[i].pos >= lower && structure[i].pos <= upper.position {
                    if structure[i].checkbox != nil { structure[i].checkbox = reference }
                }
                fixCheckboxes(&structure, parents)
                point = bottom.position
                release(bottom)
                applyStruct(structure, old)
            }
        }
        updateCheckboxCount()
    }

    // MARK: - Statistics

    /// `org-update-checkbox-count` for the current section.
    func updateCheckboxCount() {
        saveExcursion {
            let end = saveExcursion { () -> Int in outlineNextHeading(); return point }
            if beforeFirstHeading { point = 0 } else { _ = try? backToHeading() }
            let sectionStart = point
            let section = OrgParser.parse(substring(sectionStart, end))
            let cookies = section.root.descendants().filter { $0.kind == .statisticsCookie }.map { node in
                (range: (node.range.lowerBound + sectionStart)..<(node.range.upperBound + sectionStart), node: node)
            }
            let cookieData = entryProperty("COOKIE_DATA", sectionStart: sectionStart, end: end) ?? ""
            let recursive = cookieData.range(of: "\\brecursive\\b", options: .regularExpression) != nil
            var found: [(begin: Int, end: Int, percent: Bool, checked: Int, total: Int)] = []
            var cache: [Int: (Int, Int)] = [:]
            let cookiePattern = "((\\[[0-9]*%\\])|(\\[[0-9]*/[0-9]*\\]))"
            while let match = searchForward(cookiePattern, bound: end) {
                let last = match[0]!.upperBound - 1
                guard let cookie = cookies.first(where: { $0.range.contains(last) }), cookieData.range(of: "\\btodo\\b", options: .regularExpression) == nil else { continue }
                let container = containerRange(of: cookie.node, sectionStart: sectionStart)
                let begin = container?.contents.lowerBound ?? saveExcursion { () -> Int in
                    point = match[0]!.lowerBound
                    outlinePreviousHeading()
                    return point
                }
                let count: (Int, Int)
                if let cached = cache[begin] {
                    count = cached
                } else {
                    let limit = container?.contents.upperBound ?? end
                    var structures: [ListStruct] = []
                    saveExcursion {
                        point = begin
                        let boxPattern = "^[ \\t]*([-+*]|([0-9]+|[A-Za-z])[.)])[ \\t]+(?:\\[@(?:start:)?([0-9]+|[A-Za-z])\\][ \\t]*)?(\\[[- X]\\])"
                        while searchForward(boxPattern, bound: limit) != nil {
                            guard atItem else { continue }
                            let structure = listStruct()
                            structures.append(structure)
                            point = min(max(structure.bottom, point), limit)
                        }
                    }
                    count = countBoxes(item: container?.item, structures, recursive: recursive)
                    cache[begin] = count
                }
                found.insert((match[1]!.lowerBound, match[1]!.upperBound, match[2] != nil, count.0, count.1), at: 0)
            }
            for cookie in found {
                point = cookie.begin
                let text = cookie.percent ? "[\(Int((100.0 * Double(cookie.checked) / Double(max(1, cookie.total))).rounded(.down)))%]" : "[\(cookie.checked)/\(cookie.total)]"
                insert(text)
                deleteRegion(point, point + (cookie.end - cookie.begin))
                fixTagsOnTheFly()
            }
        }
    }

    /// Checked and total boxes, as `count-boxes` in `org-update-checkbox-count`.
    private func countBoxes(item: Int?, _ structures: [ListStruct], recursive: Bool) -> (Int, Int) {
        var on = 0, all = 0
        for structure in structures {
            let items: [Int]
            if recursive, let item {
                items = structure.subtree(item)
            } else if recursive {
                items = structure.map(\.pos)
            } else if let item {
                items = structure.children(item, structure.parents)
            } else {
                items = structure.allItems(structure.top, structure.prevs)
            }
            let boxes = items.compactMap { structure.checkbox($0) }
            all += boxes.count
            on += boxes.filter { $0 == "[X]" }.count
        }
        return (on, all)
    }

    /// The innermost container org counts a statistics cookie over: its contents range, and its
    /// start when it is an item.
    private func containerRange(of cookie: SyntaxNode, sectionStart: Int) -> (contents: Range<Int>, item: Int?)? {
        var node = cookie.parent
        while let current = node {
            let start = current.range.lowerBound + sectionStart
            let end = current.range.upperBound + sectionStart
            switch current.kind {
            case .item:
                let item = start
                let structure = saveExcursion { point = item; return listStruct() }
                let itemEnd = structure.item(item)?.end ?? end
                let contentsStart = saveExcursion { () -> Int? in
                    point = item
                    let match = looking(Self.fullItemPattern)!
                    let bullet = substring(match[1]!.lowerBound, match[1]!.upperBound)
                    point = match[4] != nil && bullet.contains(where: { $0 == "." || $0 == ")" }) ? match[4]!.lowerBound : match[0]!.upperBound
                    while point < itemEnd, let c = character(at: point), Self.whitespace.contains(c) { point += 1 }
                    if point == itemEnd { return nil }
                    return bolp ? lineStart(point) : point
                }
                guard let contentsStart else { return (item..<item, item) }
                let contentsEnd = saveExcursion { () -> Int in
                    point = itemEnd
                    skipBackward(Self.whitespace)
                    return min(lineEnd(point) + 1, length)
                }
                return (contentsStart..<contentsEnd, item)
            case .drawer, .dynamicBlock:
                return (bodyRange(start, end), nil)
            case .block:
                let firstLine = substring(start, lineEnd(start)).lowercased()
                let name = firstLine.range(of: "#\\+begin_(\\S+)", options: .regularExpression).map { String(firstLine[$0].dropFirst(8)) } ?? ""
                if !["src", "example", "export", "comment"].contains(name) { return (bodyRange(start, end), nil) }
            default:
                break
            }
            node = current.parent
        }
        return nil
    }

    /// Lines between a container's first and last line.
    private func bodyRange(_ start: Int, _ end: Int) -> Range<Int> {
        let contentsStart = lineEnd(start) + 1
        var last = end
        if character(at: last - 1) == Self.newline { last -= 1 }
        let closing = saveExcursion { () -> Int in
            point = last
            skipBackward(Self.whitespace)
            return lineStart(point)
        }
        return contentsStart..<max(contentsStart, closing)
    }

    /// A property of the entry from its property drawer, without inheritance.
    private func entryProperty(_ name: String, sectionStart: Int, end: Int) -> String? {
        let text = substring(sectionStart, end)
        let pattern = "^[ \\t]*:" + NSRegularExpression.escapedPattern(for: name) + ":[ \\t]+(.*?)[ \\t]*$"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range]).replacingOccurrences(of: "^[ \\t]*:[^:]+:[ \\t]+", with: "", options: .regularExpression)
    }

    /// `org-fix-tags-on-the-fly`.
    private func fixTagsOnTheFly() {
        let line = saveExcursion { () -> [Range<Int>?]? in
            beginningOfLine()
            return looking(SetTags.tagLine)
        }
        guard let tags = line?[1], point < tags.lowerBound else { return }
        alignTags(onLineAt: point)
    }
}

private func listCommand(_ context: EditContext, _ body: (EmacsBuffer) throws -> Void) -> CommandStep {
    commitBuffer(context, body)
}

/// M-RET in a list: `org-insert-item`.
public struct InsertItem: OrgCommand {
    public init() {}
    public var id: String { "org.item.insert" }
    public var title: String { "Insert Item" }
    public func applies(in context: EditContext) -> Bool { KeyContext.holds("item", in: context) }
    public func run(in context: EditContext) -> CommandStep {
        // A timer list's items are added by `org-timer-item`.
        if EmacsBuffer.atTimerList(context) { return InsertTimerItem().run(in: context) }
        return listCommand(context) { buffer in
            guard buffer.insertListItem(checkbox: false) else { throw EmacsBuffer.UserError(message: "Not in an item") }
        }
    }
}

/// M-S-RET in a list: `org-insert-item` with a checkbox.
public struct InsertCheckboxItem: OrgCommand {
    public init() {}
    public var id: String { "org.item.insert-checkbox" }
    public var title: String { "Insert Checkbox Item" }
    public func applies(in context: EditContext) -> Bool { KeyContext.holds("item", in: context) }
    public func run(in context: EditContext) -> CommandStep {
        // A timer list's items are added by `org-timer-item`.
        if EmacsBuffer.atTimerList(context) { return InsertTimerItem().run(in: context) }
        return listCommand(context) { buffer in
            guard buffer.insertListItem(checkbox: true) else { throw EmacsBuffer.UserError(message: "Not in an item") }
        }
    }
}

/// An item command that needs point on an item's first line.
private func atItemLine(_ context: EditContext) -> Bool {
    EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options).atItem
}

/// M-right on an item: `org-indent-item`.
public struct IndentItem: OrgCommand {
    public init() {}
    public var id: String { "org.item.indent" }
    public var title: String { "Indent Item" }
    public func applies(in context: EditContext) -> Bool { atItemLine(context) }
    public func run(in context: EditContext) -> CommandStep { listCommand(context) { try $0.indentItem(1, subtree: false) } }
}

/// M-left on an item: `org-outdent-item`.
public struct OutdentItem: OrgCommand {
    public init() {}
    public var id: String { "org.item.outdent" }
    public var title: String { "Outdent Item" }
    public func applies(in context: EditContext) -> Bool { atItemLine(context) }
    public func run(in context: EditContext) -> CommandStep { listCommand(context) { try $0.indentItem(-1, subtree: false) } }
}

/// M-S-right on an item: `org-indent-item-tree`.
public struct IndentItemTree: OrgCommand {
    public init() {}
    public var id: String { "org.item.indent-tree" }
    public var title: String { "Indent Item and Children" }
    public func applies(in context: EditContext) -> Bool { atItemLine(context) }
    public func run(in context: EditContext) -> CommandStep { listCommand(context) { try $0.indentItem(1, subtree: true) } }
}

/// M-S-left on an item: `org-outdent-item-tree`.
public struct OutdentItemTree: OrgCommand {
    public init() {}
    public var id: String { "org.item.outdent-tree" }
    public var title: String { "Outdent Item and Children" }
    public func applies(in context: EditContext) -> Bool { atItemLine(context) }
    public func run(in context: EditContext) -> CommandStep { listCommand(context) { try $0.indentItem(-1, subtree: true) } }
}

/// M-up on an item: `org-move-item-up`.
public struct MoveItemUp: OrgCommand {
    public init() {}
    public var id: String { "org.item.up" }
    public var title: String { "Move Item Up" }
    public func applies(in context: EditContext) -> Bool { atItemLine(context) }
    public func run(in context: EditContext) -> CommandStep { listCommand(context) { try $0.moveItem(down: false) } }
}

/// M-down on an item: `org-move-item-down`.
public struct MoveItemDown: OrgCommand {
    public init() {}
    public var id: String { "org.item.down" }
    public var title: String { "Move Item Down" }
    public func applies(in context: EditContext) -> Bool { atItemLine(context) }
    public func run(in context: EditContext) -> CommandStep { listCommand(context) { try $0.moveItem(down: true) } }
}

/// C-c C-c on an item: `org-toggle-checkbox`.
public struct ToggleCheckbox: OrgCommand {
    public init() {}
    public var id: String { "org.checkbox.toggle" }
    public var title: String { "Toggle Checkbox" }
    public func applies(in context: EditContext) -> Bool { atItemLine(context) }
    public func run(in context: EditContext) -> CommandStep { listCommand(context) { try $0.toggleCheckbox() } }
}
