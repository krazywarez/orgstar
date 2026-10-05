import Foundation

/// What the agenda needs from one file, read once from its text: headings with their planning,
/// and the active timestamps and date ranges org's agenda would consider. Positions are UTF-16.
public struct AgendaSource: Sendable {
    public let path: String

    struct Heading: Sendable {
        /// Start of the heading line.
        let start: Int
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

    let headings: [Heading]
    let stamps: [Stamp]
    let blocks: [Block]
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

        var keywordCategory: String?
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
            let afterHeading = info.headingRange.upperBound
            if let planning = planningLines.first(where: { $0.lowerBound == afterHeading }) {
                let planningText = ns.substring(with: NSRange(location: planning.lowerBound, length: planning.count))
                let regex = try! NSRegularExpression(pattern: "\\b(SCHEDULED|DEADLINE): *<([^>]+)>")
                let pns = planningText as NSString
                for m in regex.matches(in: planningText, range: NSRange(location: 0, length: pns.length)) {
                    let value = (pns.substring(with: m.range(at: 2)), planning.lowerBound + m.range(at: 2).location - 1)
                    if pns.substring(with: m.range(at: 1)) == "SCHEDULED" { scheduled = scheduled ?? value } else { deadline = deadline ?? value }
                }
            }
            headings.append(Heading(
                start: info.headingRange.lowerBound, head: head, todo: info.todo, isDone: info.isDone,
                tags: tags, category: category, scheduled: scheduled, deadline: deadline
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
