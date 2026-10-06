import Foundation

// Moving subtrees as text and sorting them (Org 9.8.7): `org-copy-subtree`, `org-cut-subtree`,
// `org-paste-subtree`, `org-clone-subtree-with-time-shift` and `org-sort-entries`. The kill
// ring is the clipboard: cutting and copying hand the text to the app (`Effect.copy`), and
// pasting takes the clipboard's text as `text`.

/// C-c C-x M-w and C-c C-x C-w: `org-copy-subtree` and `org-cut-subtree`.
public struct CopySubtree: OrgCommand {
    public let cut: Bool
    public init(cut: Bool) { self.cut = cut }
    public var id: String { cut ? "org.subtree.cut" : "org.subtree.copy" }
    public var title: String { cut ? "Cut Subtree" : "Copy Subtree" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings)
        guard !buffer.beforeFirstHeading, let range = try? buffer.subtreeRange(), !range.isEmpty else { return .failed("Before first headline") }
        let text = buffer.substring(range.lowerBound, range.upperBound)
        let effects: [Effect] = [.copy(text), .message("\(cut ? "Cut" : "Copied"): Subtree(s) with \(text.count) characters")]
        let edits = cut ? [TextEdit(range: range, replacement: "")] : []
        let caret = cut ? range.lowerBound : context.caret
        return .commit(EditResult(baseRevision: context.revision, edits: edits, selection: [caret..<caret], effects: effects))
    }
}

/// `org-kill-is-subtree-p`: starts with a heading, and no later heading is above it.
func isSubtree(_ text: String) -> Bool {
    guard let first = text.firstMatch(of: #/^(?:[ \t\n\r]*?\n)?(\*+) /#) else { return false }
    let level = first.1.count
    for match in text.matches(of: #/(?m)^(\*+) /#) where match.1.count < level { return false }
    return true
}

/// C-c C-x C-y: `org-paste-subtree` with the clipboard's text, its levels shifted to fit
/// between the headings around point.
public struct PasteSubtree: OrgCommand {
    public let text: String
    public init(text: String) { self.text = text }
    public var id: String { "org.subtree.paste" }
    public var title: String { "Paste Subtree" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        guard isSubtree(text) else { return .failed("The kill is not a (set of) tree(s).  Use `C-y' to yank anyway") }
        var newLevel = 0
        let step = commitBuffer(context) { buffer in
            let oldLevel = text.firstMatch(of: #/(?m)^(\*+) /#).map { $0.1.count } ?? -1
            var indicator: Int?
            var forced: Int?
            if buffer.lookingAtLine("^\\*+[ \\t]*$"), buffer.point >= buffer.length || buffer.character(at: buffer.point) != 42 {
                indicator = buffer.substring(buffer.lineStart(buffer.point), buffer.lineEnd(buffer.point)).prefix { $0 == "*" }.count
                forced = indicator
            } else if buffer.bolp, buffer.lookingAt("\\*+ ") != nil {
                forced = buffer.outlineLevel
            }
            let previous = buffer.saveExcursion { () -> Int in
                if !buffer.atHeading { buffer.point = Self.previousHeading(buffer) ?? buffer.point }
                return buffer.atHeading ? buffer.outlineLevel : 1
            }
            let next = buffer.saveExcursion { () -> Int in
                buffer.point = Self.nextHeading(buffer)
                return buffer.atHeading ? buffer.outlineLevel : 1
            }
            newLevel = forced ?? max(0, previous, next)
            let shift = oldLevel == -1 || oldLevel == newLevel ? 0 : newLevel - oldLevel
            if indicator != nil {
                let start = buffer.lineStart(buffer.point)
                buffer.deleteRegion(start, min(buffer.length, buffer.lineEnd(start) + 1))
                buffer.point = start
            }
            if !(buffer.bolp && buffer.atHeading) {
                buffer.point = Self.nextHeading(buffer)
                if !buffer.bolp { buffer.insert("\n") }
            }
            let begin = buffer.point
            var pasted = text.hasSuffix("\n") ? text : text + "\n"
            if shift != 0 {
                pasted = pasted.components(separatedBy: "\n").map { line in
                    guard let stars = line.firstMatch(of: #/^(\*+) /#) else { return line }
                    return String(repeating: "*", count: max(1, stars.1.count + shift)) + line.dropFirst(stars.1.count)
                }.joined(separator: "\n")
            }
            buffer.insert(pasted)
            buffer.point = begin
            buffer.skipForward([32, 9, 10, 13])
        }
        guard case .commit(let result) = step else { return step }
        return .commit(EditResult(baseRevision: result.baseRevision, edits: result.edits, selection: result.selection,
                                  effects: [.message("Clipboard pasted as level \(newLevel) subtree")]))
    }

    /// `org-previous-visible-heading` 1: the heading line before point's line.
    static func previousHeading(_ buffer: EmacsBuffer) -> Int? {
        buffer.saveExcursion {
            buffer.point = buffer.lineStart(buffer.point)
            return buffer.searchBackward("^\\*+ ", caseInsensitive: false)?[0]?.lowerBound
        }
    }

    /// `org-next-visible-heading` 1: the next heading's start, or the end of the text.
    static func nextHeading(_ buffer: EmacsBuffer) -> Int {
        buffer.saveExcursion {
            buffer.point = buffer.lineEnd(buffer.point)
            return buffer.searchForward("^\\*+ ", caseInsensitive: false)?[0]?.lowerBound ?? buffer.length
        }
    }
}

/// C-c C-x c: `org-clone-subtree-with-time-shift`. Asks how many clones and, when the subtree
/// has timestamps, the shift per clone (`+1w`). Clones get new IDs (`org-clone-delete-id`
/// nil) and no clock lines; a repeating entry ends up after its clones, its dates moved past
/// them.
public struct CloneSubtree: OrgCommand {
    let newID: @Sendable () -> String
    public init(newID: @escaping @Sendable () -> String = { UUID().uuidString }) { self.newID = newID }
    public var id: String { "org.subtree.clone" }
    public var title: String { "Clone Subtree with Time Shift" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        let probe = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings)
        guard !probe.beforeFirstHeading, let range = try? probe.subtreeRange() else { return .failed("No subtree to clone") }
        guard let countText = context.answers["count"] else { return .prompt(Prompt(key: "count", message: "Number of clones to produce:")) }
        guard let count = Int(countText.trimmingCharacters(in: .whitespaces)), count >= 0 else {
            return .failed("Invalid number of replications \(countText)")
        }
        let hasStamp = probe.saveExcursion { () -> Bool in
            probe.point = range.lowerBound
            return probe.searchForward("[\\[<][0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]>\\n]*[\\]>]", bound: range.upperBound, caseInsensitive: false) != nil
        }
        var shift = ""
        if hasStamp {
            guard let answer = context.answers["shift"] else {
                return .prompt(Prompt(key: "shift", message: "Date shift per clone (e.g. +1w, empty to copy unchanged):"))
            }
            shift = answer
        }
        var shiftN = 0
        var unit: EmacsBuffer.TimestampUnit?
        if shift.contains(where: { !$0.isWhitespace }) {
            guard let m = shift.wholeMatch(of: /[ \t]*([+-]?[0-9]+)([hdwmy])[ \t]*/) else { return .failed("Invalid shift specification \(shift)") }
            shiftN = Int(m.1.replacingOccurrences(of: "+", with: ""))!
            switch m.2 {
            case "h": unit = .hour
            case "d": unit = .day
            case "w": unit = .day; shiftN *= 7
            case "m": unit = .month
            default: unit = .year
            }
        }
        return commitBuffer(context) { buffer in
            buffer.point = range.upperBound
            if !buffer.bolp { buffer.insert("\n") }
            var end = buffer.point
            let template = buffer.substring(range.lowerBound, end)
            let hasID = buffer.saveExcursion { () -> Bool in
                buffer.point = range.lowerBound
                return buffer.entryID() != nil
            }
            var first = 1
            var last = count
            var keepRepeater = -1
            if unit != nil, template.range(of: "<[^<>\\n]+ [.+]?\\+[0-9]+[hdwmy][^<>\\n]*>", options: .regularExpression) != nil {
                buffer.deleteRegion(range.lowerBound, end)
                end = range.lowerBound
                first = 0
                last = count + 1
                keepRepeater = last
            }
            buffer.point = end
            guard first <= last else { return }
            for n in first...last {
                let clone = EmacsBuffer(template, point: 0, settings: buffer.settings, options: buffer.options)
                clone.now = buffer.now
                clone.calendar = buffer.calendar
                if hasID {
                    // `org-id-get-create` with FORCE: the old ID goes, a new one is added.
                    clone.saveExcursion {
                        if let line = clone.searchForward("^[ \\t]*:ID:.*\\n", caseInsensitive: true) {
                            clone.deleteRegion(line[0]!.lowerBound, line[0]!.upperBound)
                        }
                    }
                    clone.point = 0
                    clone.entryPut("ID", newID())
                }
                if n != 0 {
                    clone.point = 0
                    while let line = clone.searchForward("^[ \\t]*CLOCK:.*$", caseInsensitive: false) {
                        let start = clone.lineStart(line[0]!.lowerBound)
                        clone.deleteRegion(start, min(clone.length, clone.lineEnd(start) + 1))
                        clone.point = start
                    }
                    clone.point = 0
                    while let drawer = clone.searchForward("^[ \\t]*:[\\w-]+:[ \\t]*$", caseInsensitive: false) {
                        let at = drawer[0]!.upperBound
                        clone.removeEmptyDrawer(at: at)
                        clone.point = min(at, clone.length)
                        if clone.point < clone.length { clone.point = min(clone.length, clone.lineEnd(clone.point) + 1) } else { break }
                    }
                }
                if let unit {
                    clone.point = 0
                    while let stamp = clone.searchForward("[\\[<][0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]>\\n]*[\\]>]", caseInsensitive: false) {
                        clone.point = stamp[0]!.lowerBound + 1
                        try clone.changeTimestamp(n * shiftN, what: unit)
                        clone.point = clone.lineStart(clone.point)
                        clone.point = min(clone.length, (clone.searchForward("[\\]>]", bound: clone.lineEnd(clone.point), caseInsensitive: false)?[0]?.upperBound) ?? clone.lineEnd(clone.point))
                        if let after = clone.searchForward("[\\[<][0-9]{4}", bound: clone.lineEnd(clone.point), caseInsensitive: false), after[0]!.lowerBound > 0 {
                            clone.point = after[0]!.lowerBound
                        } else {
                            clone.point = min(clone.length, clone.lineEnd(clone.point) + 1)
                        }
                    }
                    if n != keepRepeater {
                        clone.point = 0
                        while let repeater = clone.searchForward("<[^<>\\n]+?( +[.+]?\\+[0-9]+[hdwmy])", caseInsensitive: false) {
                            clone.deleteRegion(repeater[1]!.lowerBound, repeater[1]!.upperBound)
                        }
                    }
                }
                buffer.insert(clone.string)
            }
            buffer.point = range.lowerBound
        }
    }
}

/// C-c ^ on headings: `org-sort-entries`. The children of the heading at point (all top-level
/// headings before the first one, or the region's headings) sort by a key: [a]lpha,
/// [n]umeric, [p]riority, p[r]operty, todo[o]rder, [t]ime, [s]cheduled, [d]eadline,
/// [c]reated, cloc[k]ing; the capital letter reverses.
public struct SortEntries: OrgCommand {
    public init() {}
    public var id: String { "org.sort" }
    public var title: String { "Sort Entries" }
    public func applies(in context: EditContext) -> Bool { true }

    static let keys: [(Character, String)] = [
        ("a", "alpha"), ("n", "numeric"), ("p", "priority"), ("r", "property"), ("o", "todo order"),
        ("t", "time"), ("s", "scheduled"), ("d", "deadline"), ("c", "created"), ("k", "clocking"),
    ]

    public func run(in context: EditContext) -> CommandStep {
        // `org-sort` sorts table lines and list items there; those aren't here yet.
        if KeyContext.holds("table", in: context) { return SortTableLines().run(in: context) }
        if EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).inItem() != nil {
            return .failed("Sorting list items isn't supported yet")
        }
        let probe = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings)
        guard let bounds = Self.bounds(probe, context.selection.first ?? context.caret..<context.caret) else { return .failed("Nothing to sort") }
        guard let answer = context.answers["sort"], let key = answer.first else {
            var items: [FastSelection.Item] = Self.keys.map { .option(key: $0.0, name: $0.1) }
            items.append(.newline)
            items += Self.keys.map { .option(key: Character($0.0.uppercased()), name: $0.1 + " (reversed)") }
            return .prompt(Prompt(key: "sort", message: "Sort \(bounds.what): [a]lpha [n]umeric [p]riority p[r]operty todo[o]rder [t]ime [s]cheduled [d]eadline [c]reated cloc[k]ing; capitals reverse",
                                  fast: FastSelection(items: items, multiple: false)))
        }
        let kind = Character(key.lowercased())
        guard Self.keys.contains(where: { $0.0 == kind }) else { return .failed("Invalid sorting type `\(key)'") }
        var property = ""
        if kind == "r" {
            guard let name = context.answers["property"] else {
                return .prompt(Prompt(key: "property", message: "Property:", choices: Self.propertyKeys(context.text)))
            }
            property = name
        }
        return commitBuffer(context) { buffer in
            try Self.sort(buffer, key: kind, reverse: key.isUppercase, property: property, selection: context.selection.first ?? context.caret..<context.caret)
        }
    }

    /// `org-buffer-property-keys`, roughly: the property names in the text.
    static func propertyKeys(_ text: String) -> [String] {
        var names: [String] = []
        for match in text.matches(of: #/(?m)^[ \t]*:([^\s:]+):[ \t]/#) where !names.contains(String(match.1)) && String(match.1).uppercased() != "END" {
            names.append(String(match.1))
        }
        return names
    }

    /// The text to sort and what it is: a region's headings, a heading's children, or the
    /// top-level headings. Nil when there's nothing.
    static func bounds(_ buffer: EmacsBuffer, _ selection: Range<Int>) -> (start: Int, end: Int, first: Int, what: String)? {
        buffer.saveExcursion {
            var start: Int
            var end: Int
            let what: String
            if !selection.isEmpty {
                buffer.point = selection.lowerBound
                if buffer.atHeading { buffer.point = buffer.lineStart(buffer.point) } else { Capture.nextHeading(buffer) }
                start = buffer.point
                buffer.point = selection.upperBound
                if !buffer.beforeFirstHeading, (try? buffer.backToHeading()) != nil { Capture.endOfSubtree(buffer, heading: buffer.point) }
                end = buffer.point
                what = "region"
            } else if !buffer.beforeFirstHeading {
                _ = try? buffer.backToHeading()
                start = buffer.point
                Capture.endOfSubtree(buffer, heading: start)
                end = buffer.point
                // Without the blank lines after the subtree, but with one.
                var back = end
                while back > start, let c = buffer.character(at: back - 1), c == 10 || c == 32 || c == 9 {
                    if c == 10, back - 1 > start, buffer.character(at: back - 2) == 10 { back -= 1 } else if c != 10 { back -= 1 } else { break }
                }
                end = back
                what = "children"
                buffer.point = start
                buffer.point = min(buffer.length, buffer.lineEnd(start) + 1)
                if !buffer.atHeading { Capture.nextHeading(buffer) }
                return buffer.point < end ? (start, end, buffer.point, what) : nil
            } else {
                buffer.point = 0
                if !buffer.atHeading { Capture.nextHeading(buffer) }
                start = buffer.point
                end = buffer.length
                what = "top-level"
            }
            return start < end ? (start, end, start, what) : nil
        }
    }

    static func sort(_ buffer: EmacsBuffer, key: Character, reverse: Bool, property: String, selection: Range<Int>) throws {
        guard let bounds = bounds(buffer, selection) else { throw EmacsBuffer.UserError(message: "Nothing to sort") }
        var end = bounds.end
        // The sorted text ends with a newline.
        if end > 0, buffer.character(at: end - 1) != 10 {
            buffer.point = end
            buffer.insert("\n")
            end += 1
        }
        let begin = bounds.first
        guard begin < end else { throw EmacsBuffer.UserError(message: "Nothing to sort") }
        let stars = buffer.substring(begin, buffer.lineEnd(begin)).prefix { $0 == "*" }
        let level = stars.count
        let text = buffer.substring(begin, end)
        if level > 1, text.range(of: "(?m)^\\*{1,\(level - 1)}[ \\t\\n]", options: .regularExpression) != nil {
            throw EmacsBuffer.UserError(message: "Region to sort contains a level above the first entry")
        }
        // Records: from each heading at the first one's level to the next.
        var starts: [Int] = []
        buffer.point = begin
        while let match = buffer.searchForward("^\\*{\(level)} +", bound: end, caseInsensitive: false) {
            starts.append(match[0]!.lowerBound)
            buffer.point = match[0]!.upperBound
        }
        guard !starts.isEmpty else { return }
        let records = starts.enumerated().map { i, s in s..<(i + 1 < starts.count ? starts[i + 1] : end) }
        let now = buffer.now.timeIntervalSince1970
        let keys = records.map { record -> SortKey in
            buffer.point = record.lowerBound
            return sortKey(buffer, kind: key, record: record, property: property, now: now)
        }
        var order = Array(records.indices)
        if reverse { order.reverse() }
        order = order.enumerated().sorted { a, b in
            let less = keys[a.element] < keys[b.element]
            let greater = keys[b.element] < keys[a.element]
            return less != greater ? less : a.offset < b.offset
        }.map(\.element)
        if reverse { order.reverse() }
        let sorted = order.map { buffer.substring(records[$0].lowerBound, records[$0].upperBound) }.joined()
        buffer.deleteRegion(records.first!.lowerBound, end)
        buffer.point = records.first!.lowerBound
        buffer.insert(sorted)
        buffer.point = bounds.start
    }

    enum SortKey: Comparable {
        case number(Double)
        case text(String)

        static func < (a: SortKey, b: SortKey) -> Bool {
            switch (a, b) {
            case (.number(let x), .number(let y)): x < y
            case (.text(let x), .text(let y)): x < y
            case (.number, .text): true
            case (.text, .number): false
            }
        }
    }

    static func sortKey(_ buffer: EmacsBuffer, kind: Character, record: Range<Int>, property: String, now: Double) -> SortKey {
        let entryEnd = buffer.saveExcursion { () -> Int in
            Capture.nextHeading(buffer)
            return min(buffer.point, record.upperBound)
        }
        let match = buffer.lookingAt(buffer.complexHeadingPattern)
        func group(_ i: Int) -> String? { match?[i].map { buffer.substring($0.lowerBound, $0.upperBound) } }
        func seconds(_ pattern: String, group: Int = 0) -> Double {
            buffer.saveExcursion {
                guard let found = buffer.searchForward(pattern, bound: entryEnd, caseInsensitive: false), let range = found[group] else { return now }
                return TagsMatcher.seconds(buffer.substring(range.lowerBound, range.upperBound), now: buffer.now, calendar: buffer.calendar)
            }
        }
        switch kind {
        case "a":
            return .text(visibleTitle(group(4) ?? "").lowercased())
        case "n":
            return .number(Double(visibleTitle(group(4) ?? "").prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) ?? 0)
        case "p":
            // `org-priority-regexp` anywhere on the heading line.
            let line = buffer.substring(record.lowerBound, buffer.lineEnd(record.lowerBound))
            let cookie = line.firstMatch(of: /\[#([A-Z]|[0-9]+)\]/).map { String($0.1) }
            let value: String = cookie ?? buffer.settings.priorities.default
            return .number(value.allSatisfy(\.isNumber) ? Double(value)! : Double(value.unicodeScalars.first!.value))
        case "r":
            let value = buffer.saveExcursion { () -> String in
                buffer.point = record.lowerBound
                guard let drawer = buffer.searchForward("^[ \\t]*:" + NSRegularExpression.escapedPattern(for: property) + ":[ \\t]+(.*?)[ \\t]*$", bound: entryEnd, caseInsensitive: true) else { return "" }
                return drawer[1].map { buffer.substring($0.lowerBound, $0.upperBound) } ?? ""
            }
            return .text(value)
        case "o":
            let keywords = buffer.keywordsInOrder
            guard let todo = group(2), let index = keywords.firstIndex(of: todo) else { return .number(99) }
            let remaining = Double(keywords.count - index)
            return .number(buffer.settings.isDone(todo) ? 99 + remaining : 99 - remaining)
        case "t":
            let active = seconds("<[0-9]{4}-[0-9]{2}-[0-9]{2}[^>\\n]*>")
            if active != now { return .number(active) }
            return .number(seconds("[\\[<][0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]>\\n]*[\\]>]"))
        case "c":
            return .number(seconds("^[ \\t]*\\[[0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]\\n]*\\]"))
        case "s":
            return .number(seconds("SCHEDULED: *(<[^>]+>)", group: 1))
        case "d":
            return .number(seconds("DEADLINE: *(<[^>]+>)", group: 1))
        default:
            // Clocked minutes in the whole subtree.
            var minutes = 0.0
            buffer.saveExcursion {
                buffer.point = record.lowerBound
                while let line = buffer.searchForward("^[ \\t]*CLOCK:.*=>[ \\t]*([0-9]+):([0-9]{2})", bound: record.upperBound, caseInsensitive: false) {
                    minutes += Double(buffer.substring(line[1]!.lowerBound, line[1]!.upperBound))! * 60 + Double(buffer.substring(line[2]!.lowerBound, line[2]!.upperBound))!
                }
            }
            return .number(minutes)
        }
    }

    /// `org-get-heading t t t t` through `org-sort-remove-invisible`: no COMMENT, links as their
    /// descriptions, emphasis markers gone.
    static func visibleTitle(_ title: String) -> String {
        var t = title
        if t == "COMMENT" { t = "" } else if t.hasPrefix("COMMENT ") { t = String(t.dropFirst(8)) }
        return removeInvisible(t)
    }

    /// `org-sort-remove-invisible`: links as their descriptions, emphasis markers gone.
    static func removeInvisible(_ s: String) -> String {
        Links.displayFormat(s).replacingOccurrences(of: "(^|[\\s(])[*/_+=~]([^\\s*/_+=~](?:.*?[^\\s])?)[*/_+=~](?=$|[\\s.,;:!?)])", with: "$1$2", options: .regularExpression)
    }
}
