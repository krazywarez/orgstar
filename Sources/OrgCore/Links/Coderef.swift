import Foundation

// Code references (Org 9.8.7): labels such as `(ref:name)` at the end of lines in src and
// example blocks, the switches that number lines and strip labels, and `[[(name)]]` links.

public enum Coderef {
    /// `org-coderef-label-format`.
    public static let defaultFormat = "(ref:%s)"

    /// A block's switches, as `org-element-src-block-parser` reads them.
    public struct Switches: Sendable, Equatable {
        /// `-n` (`new`) or `+n` (continued) and the lines before the first: `-n 10` is 9.
        public var numberLines: (continued: Bool, before: Int)?
        public var retainLabels = true
        public var useLabels = true
        public var labelFormat = Coderef.defaultFormat

        public static func == (a: Switches, b: Switches) -> Bool {
            a.numberLines?.continued == b.numberLines?.continued && a.numberLines?.before == b.numberLines?.before
                && a.retainLabels == b.retainLabels && a.useLabels == b.useLabels && a.labelFormat == b.labelFormat
        }

        public init(_ switches: String?) {
            guard let switches, !switches.isEmpty else { return }
            if let m = switches.firstMatch(of: /([-+])n(?: *([0-9]+))?\b/) {
                numberLines = (m.1 == "+", m.2.flatMap { Int($0) }.map { $0 - 1 } ?? 0)
            }
            let r = switches.contains(/-r\b/)
            let k = switches.contains(/-k\b/)
            retainLabels = !r || (numberLines != nil && k)
            useLabels = retainLabels && !k
            if let m = switches.firstMatch(of: /-l +"([^"\n]+)"/) { labelFormat = String(m.1) }
        }
    }

    /// A src or example block's switches and its code, commas unescaped, from its lines.
    public static func block(_ lines: [String]) -> (switches: Switches, body: [String])? {
        guard let first = lines.first else { return nil }
        let switches: String?
        if let m = first.firstMatch(of: /^[ \t]*#\+(?i:begin_src)(?: +\S+)?((?: +(?:-(?:l ".+"|[ikr])|[-+]n(?: *[0-9]+)?))+)?/) {
            switches = m.1.map(String.init)
        } else if let m = first.firstMatch(of: /^[ \t]*#\+(?i:begin_example)(?: +(.*))?/) {
            switches = m.1.map(String.init)
        } else {
            return nil
        }
        var body = Array(lines.dropFirst())
        if let last = body.last, last.range(of: "^[ \\t]*#\\+(?i:end_)", options: .regularExpression) != nil { body.removeLast() }
        body = body.map { $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression) }
        return (Switches(switches), body)
    }

    /// `org-src-coderef-regexp`: group 1 the label with the blanks around it, 2 without them,
    /// 3 the name.
    public static func regex(_ format: String, label: String? = nil) -> NSRegularExpression {
        let name = label.map(NSRegularExpression.escapedPattern(for:)) ?? "([-a-zA-Z0-9_][-a-zA-Z0-9_ ]*)"
        let pattern = NSRegularExpression.escapedPattern(for: format).replacingOccurrences(of: "%s", with: name)
        return try! NSRegularExpression(pattern: "([ \\t]*(" + pattern + ")[ \\t]*)$")
    }

    /// `org-export-unravel-code`: the lines without their labels, and the label on each line
    /// that had one, by line (1-based).
    public static func unravel(_ lines: [String], format: String) -> (code: [String], refs: [Int: String]) {
        let re = regex(format)
        var refs: [Int: String] = [:]
        let code = lines.enumerated().map { index, line -> String in
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
            refs[index + 1] = ns.substring(with: m.range(at: 3))
            return ns.replacingCharacters(in: m.range(at: 1), with: "")
        }
        return (code, refs)
    }

    /// The src and example blocks of `text`, in order, as their lines.
    static func blocks(_ tree: OrgTree) -> [[String]] {
        tree.root.descendants().filter { $0.kind == .block }.compactMap { node in
            var lines = node.text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return block(lines) == nil ? nil : lines
        }
    }

    /// `org-export-get-loc` for each block: the lines numbered before its first, or nil.
    public static func locs(_ blocks: [(switches: Switches, body: [String])]) -> [Int?] {
        var loc = 0
        return blocks.map { block in
            guard let numbering = block.switches.numberLines else { return nil }
            let mine = numbering.continued ? loc + numbering.before : numbering.before
            let lines = block.body.count
            loc = numbering.continued ? loc + numbering.before + lines : numbering.before + lines
            return mine
        }
    }

    /// `org-export-resolve-coderef`: the label, or its line's number for blocks that number
    /// lines instead; nil when no block has it.
    public static func resolve(_ ref: String, in tree: OrgTree) -> String? {
        let parsed = blocks(tree).compactMap(block)
        let locs = locs(parsed)
        for (block, loc) in zip(parsed, locs) {
            let lines = trimmedLines(block.body)
            let re = regex(block.switches.labelFormat, label: ref)
            guard let index = lines.lastIndex(where: { re.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }) else { continue }
            return block.switches.useLabels ? ref : String((loc ?? 0) + index + 1)
        }
        return nil
    }

    /// `org-trim` of the block's value, as lines.
    static func trimmedLines(_ body: [String]) -> [String] {
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.components(separatedBy: "\n")
    }

    /// `org-export-get-coderef-format`: a description with `%s` is the format, another one
    /// replaces the reference.
    public static func linkText(_ resolved: String, description: String?) -> String {
        guard let description, !description.isEmpty else { return resolved }
        return description.contains("%s") ? description.replacingOccurrences(of: "%s", with: resolved) : description
    }

    /// `org-link-search` for `(name)`: the start of the label in the block that has it.
    static func search(_ name: String, text: String, tree: OrgTree) -> Int? {
        let ns = text as NSString
        for node in tree.root.descendants() where node.kind == .block {
            var lines = node.text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            guard let parsed = block(lines) else { continue }
            let re = regex(parsed.switches.labelFormat, label: name)
            // The block's lines after its first.
            var start = NSMaxRange(ns.lineRange(for: NSRange(location: node.range.lowerBound, length: 0)))
            while start < node.range.upperBound {
                let range = ns.lineRange(for: NSRange(location: start, length: 0))
                var line = ns.substring(with: range)
                if line.hasSuffix("\n") { line.removeLast() }
                if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    return range.location + m.range(at: 2).location
                }
                start = NSMaxRange(range)
            }
        }
        return nil
    }
}
