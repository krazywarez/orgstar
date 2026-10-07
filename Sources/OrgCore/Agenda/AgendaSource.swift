import Foundation

/// What the agenda needs from one file, read once from its text: headings with their planning,
/// and the active timestamps and date ranges org's agenda would consider. Positions are UTF-16.
public struct AgendaSource: Sendable {
    public let path: String

    struct Heading: Sendable {
        /// Start of the heading line.
        let start: Int
        let level: Int
        /// In an archived or commented tree, which the agenda skips.
        let skipped: Bool
        /// The title without keyword, priority and tags (`ITEM`).
        let title: String
        /// The priority cookie's value.
        let priority: String?
        let localTags: [String]
        /// Upper-cased keys of the entry's own drawer.
        let properties: [String: String]
        /// Planning timestamps with brackets, for property matches.
        let planning: [String: String]
        /// The first active and inactive timestamps in the entry (`TIMESTAMP`, `TIMESTAMP_IA`).
        let firstActive: String?
        let firstInactive: String?
        /// The heading line without its newline.
        let line: String
        /// The line after the stars.
        let head: String
        let todo: String?
        let isDone: Bool
        /// Inherited tags first; the flag marks inherited ones.
        let tags: [(name: String, inherited: Bool)]
        let category: String
        /// The planning timestamp without brackets, and the position of its `<`.
        let scheduled: (raw: String, offset: Int)?
        let deadline: (raw: String, offset: Int)?
        /// `STYLE: habit`.
        let isHabit: Bool
        /// `org-habit-parse-todo`, nil where it signals an error.
        let habit: Habit?
    }

    struct Stamp: Sendable {
        let offset: Int
        let heading: Int
        /// From the `<` to the end of the line.
        let rest: String
    }

    struct Block: Sendable {
        let start: String
        let end: String
        /// End of the range; org's marker sits there.
        let marker: Int
        let heading: Int
    }

    /// A `CLOSED:`, `CLOCK:` or `- State "…"` line, for log mode (`org-agenda-get-progress`).
    struct Progress: Sendable {
        enum Kind: Sendable { case closed, clock, state }
        let kind: Kind
        let offset: Int
        let heading: Int
        /// `YYYY-MM-DD` of the first timestamp.
        let date: String
        /// The timestamp, from the keyword; a clock's ends with its end time (`[… 10:00-11:30]`).
        let timestamp: String
        /// A clock's duration, or `-`.
        let clocked: String
        /// The state a note records.
        let state: String?
        /// The first line of the note under it.
        let note: String?
    }

    let headings: [Heading]
    let stamps: [Stamp]
    let blocks: [Block]
    let progress: [Progress]
    /// The file's TODO keywords, active and done.
    let keywords: [String]
    let priorities: Priorities

    public init(path: String, text: String, defaults: OrgSettings = .default) {
        self.path = path
        let tree = OrgParser.parse(text, defaults: defaults)
        let model = DocumentModel(tree: tree)
        let ns = text as NSString
        let settings = tree.settings
        keywords = settings.todoSequences.flatMap { $0.active.map(\.name) + $0.done.map(\.name) }
        priorities = settings.priorities

        var stampsByHeading: [Int: [String]] = [:]
        var headingIndex = -1
        func collect(_ node: SyntaxNode) {
            for child in node.children {
                if child.kind == .heading { headingIndex += 1 }
                if child.kind == .timestamp, headingIndex >= 0 {
                    stampsByHeading[headingIndex, default: []].append(child.text)
                } else if child.kind != .block, child.kind != .planning {
                    collect(child)
                }
            }
        }
        collect(tree.root)
        func sectionStamps(_ index: Int) -> [String] { stampsByHeading[index] ?? [] }

        var keywordCategory = SetupFile.keywords(tree.settings.setupKeywords).last { $0.key == "CATEGORY" }?.value.trimmingCharacters(in: .whitespaces)
        var srcBodies: [Range<Int>] = []
        var planningLines: [Range<Int>] = []
        var timestampNodes: [Int] = []
        var propertyLines: [Range<Int>] = []
        func walk(_ node: SyntaxNode) {
            for child in node.children {
                switch child.kind {
                case .keyword:
                    let line = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.uppercased().hasPrefix("#+CATEGORY:") {
                        keywordCategory = line.dropFirst("#+CATEGORY:".count).trimmingCharacters(in: .whitespaces)
                    }
                case .block:
                    if DocumentModel.isSrcBlock(child) {
                        let lines = child.range
                        let firstEnd = ns.range(of: "\n", range: NSRange(location: lines.lowerBound, length: lines.count)).location
                        let lastStart = ns.lineRange(for: NSRange(location: max(lines.lowerBound, lines.upperBound - 1), length: 0)).location
                        if firstEnd != NSNotFound, firstEnd + 1 <= lastStart { srcBodies.append((firstEnd + 1)..<lastStart) }
                    }
                case .planning:
                    planningLines.append(child.range)
                case .clock:
                    break
                case .nodeProperty:
                    propertyLines.append(child.range)
                case .timestamp:
                    if child.text.hasPrefix("<") { timestampNodes.append(child.offset) }
                default:
                    walk(child)
                }
            }
        }
        walk(tree.root)

        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let fileCategory = keywordCategory ?? model.property("CATEGORY", of: nil)?.value ?? fileName
        let fileTags = model.fileTags
        let fileArchived = fileTags.contains("ARCHIVE")

        // Archived and commented trees are skipped whole, as `org-agenda-skip` does.
        var skipped: [Bool] = []
        var headings: [Heading] = []
        for (index, info) in model.headings.enumerated() {
            let own = info.localTags.contains("ARCHIVE") || Self.isCommented(info.title)
            skipped.append(fileArchived || own || (info.parent.map { skipped[$0] } ?? false))
            let line = ns.substring(with: NSRange(location: info.headingRange.lowerBound, length: info.headingRange.count))
            let head = line.replacingOccurrences(of: "^\\*+[ \\t]+", with: "", options: .regularExpression)
                .trimmingCharacters(in: .newlines)

            var itags: [String] = fileTags
            for ancestor in model.ancestors(of: index) { itags += model.headings[ancestor].localTags }
            var tags: [(String, Bool)] = itags.map { ($0, true) } + info.localTags.map { ($0, false) }
            // `delete-dups` over the reversed list: the most local copy of a tag stays.
            var seen: Set<String> = []
            tags = tags.reversed().filter { seen.insert($0.0).inserted }.reversed()

            var category = fileCategory
            for layer in ([index] + model.ancestors(of: index).reversed()) {
                if let value = model.headings[layer].properties.last(where: { $0.key.uppercased() == "CATEGORY" && !$0.additive })?.value {
                    category = value
                    break
                }
            }

            var scheduled: (String, Int)?
            var deadline: (String, Int)?
            var planningValues: [String: String] = [:]
            let afterHeading = info.headingRange.upperBound
            if let planning = planningLines.first(where: { $0.lowerBound == afterHeading }) {
                let planningText = ns.substring(with: NSRange(location: planning.lowerBound, length: planning.count))
                let regex = try! NSRegularExpression(pattern: "\\b(SCHEDULED|DEADLINE): *<([^>]+)>")
                let pns = planningText as NSString
                for m in regex.matches(in: planningText, range: NSRange(location: 0, length: pns.length)) {
                    let value = (pns.substring(with: m.range(at: 2)), planning.lowerBound + m.range(at: 2).location - 1)
                    if pns.substring(with: m.range(at: 1)) == "SCHEDULED" { scheduled = scheduled ?? value } else { deadline = deadline ?? value }
                }
                let any = try! NSRegularExpression(pattern: "\\b(SCHEDULED|DEADLINE|CLOSED): *([\\[<]\(Self.tsInternal)[\\]>])")
                for m in any.matches(in: planningText, range: NSRange(location: 0, length: pns.length)) {
                    let key = pns.substring(with: m.range(at: 1))
                    if planningValues[key] == nil { planningValues[key] = pns.substring(with: m.range(at: 2)) }
                }
            }
            var properties: [String: String] = [:]
            for property in info.properties {
                let key = property.key.uppercased()
                if property.additive, let value = properties[key] {
                    properties[key] = value + " " + property.value
                } else {
                    properties[key] = property.value
                }
            }
            let ownStamps = sectionStamps(index)
            let isHabit = properties["STYLE"]?.trimmingCharacters(in: .whitespaces) == "habit"
            var habit: Habit?
            if isHabit, let scheduled {
                let end = index + 1 < model.headings.count ? model.headings[index + 1].headingRange.lowerBound : ns.length
                let entry = ns.substring(with: NSRange(location: info.headingRange.lowerBound, length: end - info.headingRange.lowerBound))
                habit = Habit.parse(entry: entry, scheduled: scheduled.0, doneKeywords: settings.todoSequences.flatMap { $0.done.map(\.name) })
            }
            headings.append(Heading(
                start: info.headingRange.lowerBound, level: info.level, skipped: skipped[index],
                title: info.title.trimmingCharacters(in: .whitespaces), priority: info.priority, localTags: info.localTags,
                properties: properties, planning: planningValues,
                firstActive: ownStamps.first { $0.hasPrefix("<") }, firstInactive: ownStamps.first { $0.hasPrefix("[") },
                line: line.trimmingCharacters(in: .newlines), head: head, todo: info.todo, isDone: info.isDone,
                tags: tags, category: category, scheduled: scheduled, deadline: deadline, isHabit: isHabit, habit: habit
            ))
        }
        self.headings = headings

        let starts = model.headings.map(\.headingRange.lowerBound)
        func heading(at offset: Int) -> Int? {
            var low = 0
            var high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= offset { low = mid + 1 } else { high = mid }
            }
            return low == 0 ? nil : low - 1
        }
        func restOfLine(_ offset: Int) -> String {
            let line = ns.lineRange(for: NSRange(location: offset, length: 0))
            return ns.substring(with: NSRange(location: offset, length: NSMaxRange(line) - offset)).trimmingCharacters(in: .newlines)
        }

        // Timestamps: those the parser sees as timestamp objects, and dates in property lines.
        var stampOffsets = timestampNodes
        let datePattern = try! NSRegularExpression(pattern: "<[0-9]{4}-[0-9]{2}-[0-9]{2}")
        for line in propertyLines {
            for m in datePattern.matches(in: text, range: NSRange(location: line.lowerBound, length: line.count)) {
                stampOffsets.append(m.range.location)
            }
        }
        var stamps: [Stamp] = []
        for offset in stampOffsets.sorted() {
            guard let owner = heading(at: offset), !skipped[owner] else { continue }
            let rest = restOfLine(offset)
            guard rest.range(of: "^<[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) != nil else { continue }
            if Self.inDateRange(offset, ns) { continue }
            stamps.append(Stamp(offset: offset, heading: owner, rest: rest))
        }
        self.stamps = stamps

        // Ranges: org scans the raw text, skipping comment lines, skipped trees and src blocks.
        var blocks: [Block] = []
        let range = try! NSRegularExpression(pattern: "<(\(Self.tsInternal))>--?-?<(\(Self.tsInternal))>")
        for m in range.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let point = NSMaxRange(m.range)
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: point, length: 0)))
            if line.range(of: "^\\s*#( |$|\\n)", options: .regularExpression) != nil { continue }
            guard let owner = heading(at: max(0, point - 1)), !skipped[owner] else { continue }
            if srcBodies.contains(where: { $0.contains(point) }) { continue }
            blocks.append(Block(start: ns.substring(with: m.range(at: 1)), end: ns.substring(with: m.range(at: 2)), marker: point, heading: owner))
        }
        self.blocks = blocks

        // Log lines: org searches the raw text, then the heading above each match.
        let keywordPattern = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let logLine = try! NSRegularExpression(pattern: "(\\bCLOSED:|\\bCLOCK:|- +State \"(\(keywordPattern.isEmpty ? "(?!)" : keywordPattern))\".*?) *\\[([0-9]{4}-[0-9]{2}-[0-9]{2})")
        let inactive = try! NSRegularExpression(pattern: "\\[([0-9]{4}-[0-9]{2}-[0-9]{2}( +[^\\]+0-9>\\r\\n -]+)?( +([0-9]{1,2}):([0-9]{2}))?)\\]")
        let clockEnd = try! NSRegularExpression(pattern: "([0-9]{1,2}:[0-9]{2})\\].*?([0-9]{1,2}:[0-9]{2})")
        let stateNote = try! NSRegularExpression(pattern: ".*\\\\\\n[ \\t]*([^-\\n \\t].*?)[ \\t]*$", options: .anchorsMatchLines)
        let clockNote = try! NSRegularExpression(pattern: ".*\\n[ \\t]*-[ \\t]+([^-\\n \\t].*?)[ \\t]*$", options: .anchorsMatchLines)
        var progress: [Progress] = []
        for m in logLine.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let owner = heading(at: m.range.location), !skipped[owner] else { continue }
            let keyword = ns.substring(with: m.range(at: 1))
            let kind: Progress.Kind = keyword == "CLOSED:" ? .closed : keyword == "CLOCK:" ? .clock : .state
            var timestamp = restOfLine(m.range.location)
            var clocked = "-"
            let tns = timestamp as NSString
            if let ts = inactive.firstMatch(in: timestamp, range: NSRange(location: 0, length: tns.length)) {
                let rest = tns.substring(from: NSMaxRange(ts.range))
                timestamp = tns.substring(to: NSMaxRange(ts.range))
                let rns = rest as NSString
                if kind == .clock, let end = clockEnd.firstMatch(in: rest, range: NSRange(location: 0, length: rns.length)) {
                    timestamp = String(timestamp.dropLast()) + "-" + rns.substring(with: end.range(at: 1)) + "]"
                    clocked = rns.substring(with: end.range(at: 2))
                }
            }
            // The note: after a state line ending in `\\`, or a list item under a clock line.
            var note: String?
            let after = NSMaxRange(m.range)
            let notePattern: NSRegularExpression? = switch kind {
            case .state: stateNote
            case .clock: clockNote
            case .closed: nil
            }
            if let notePattern, let n = notePattern.firstMatch(in: text, options: .anchored, range: NSRange(location: after, length: ns.length - after)) {
                note = ns.substring(with: n.range(at: 1))
            }
            progress.append(Progress(
                kind: kind, offset: m.range.location, heading: owner, date: ns.substring(with: m.range(at: 3)), timestamp: timestamp,
                clocked: clocked, state: m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2)), note: note
            ))
        }
        self.progress = progress
    }

    /// `org-ts--internal-regexp`.
    static let tsInternal = "[0-9]{4}-[0-9]{2}-[0-9]{2}(?: .*?)?"

    /// `org-element` reads a title starting with `COMMENT` as a commented heading.
    static func isCommented(_ title: String) -> Bool {
        title == "COMMENT" || title.hasPrefix("COMMENT ")
    }

    /// `org-at-date-range-p` with point just after the date that starts at `offset`.
    static func inDateRange(_ offset: Int, _ ns: NSString) -> Bool {
        let point = offset + 11
        let line = ns.lineRange(for: NSRange(location: offset, length: 0))
        let regex = try! NSRegularExpression(pattern: "[\\[<](\(tsInternal))[\\]>]--?-?[\\[<](\(tsInternal))[\\]>]")
        for m in regex.matches(in: ns as String, range: line) {
            if m.range.location > point { break }
            if NSMaxRange(m.range) >= point { return true }
        }
        return false
    }
}
