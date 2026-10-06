import Foundation

/// Agenda filters (`org-agenda-filter`, Org 9.8.7): categories, tags, effort and regexps,
/// each a list of `+x` (keep) and `-x` (drop) terms. Lines without an entry (the time grid)
/// always show.
public struct AgendaFilter: Sendable, Equatable {
    public var categories: [String] = []
    public var tags: [String] = []
    public var efforts: [String] = []
    public var regexps: [String] = []

    public init() {}

    public var isEmpty: Bool { categories.isEmpty && tags.isEmpty && efforts.isEmpty && regexps.isEmpty }

    /// The filter as `/` shows it for editing.
    public var description: String {
        let regexp = regexps.first.map { "/" + $0.dropFirst().replacingOccurrences(of: "^\\+", with: "", options: .regularExpression) + "/" } ?? ""
        return categories.joined() + tags.joined() + (efforts.first.map { String($0.dropFirst()) } ?? "") + regexp
    }

    /// Reads `+cat-tag<0:10-/regexp/`: a word is a tag if a shown line has it, else a category
    /// if a shown line has it, else ignored. A leading `+` before `+` or `-` keeps the current
    /// filter and adds to it. Returns the filter and the words it ignored.
    public func parse(_ input: String, tags shownTags: Set<String>, categories shownCategories: Set<String>) -> (filter: AgendaFilter, ignored: [String]) {
        var s = input
        var keep = false
        if s.range(of: "^\\+[+-]", options: .regularExpression) != nil {
            s.removeFirst()
            keep = true
        }
        // Quoted categories may hold `-`.
        s = s.replacingOccurrences(of: "\"([^\"]*)-([^\"]*)\"", with: "\"$1~~~$2\"", options: .regularExpression)
        var result = keep ? self : AgendaFilter()
        var ignored: [String] = []
        let regex = try! NSRegularExpression(pattern: "^[ \\t]*([-+])?(([^-+<>=/ \\t]+)|([<>=][0-9:]+)|(/([^/]+)/?))")
        func append(_ term: String, to list: inout [String]) { if !list.contains(term) { list.append(term) } }
        while true {
            let ns = s as NSString
            guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { break }
            let sign = m.range(at: 1).location == NSNotFound ? "+" : ns.substring(with: m.range(at: 1))
            if m.range(at: 3).location != NSNotFound {
                let word = ns.substring(with: m.range(at: 3)).replacingOccurrences(of: "~~~", with: "-")
                if shownTags.contains(word) {
                    append(sign + word, to: &result.tags)
                } else if shownCategories.contains(word) {
                    append(sign + word.replacingOccurrences(of: "^\"(.*)\"$", with: "$1", options: .regularExpression), to: &result.categories)
                } else {
                    ignored.append(sign + word)
                }
            } else if m.range(at: 4).location != NSNotFound {
                append(sign + ns.substring(with: m.range(at: 4)), to: &result.efforts)
            } else {
                append(sign + ns.substring(with: m.range(at: 6)), to: &result.regexps)
            }
            s = ns.substring(from: NSMaxRange(m.range))
        }
        return (result, ignored)
    }

    /// Whether `item` stays visible.
    public func keeps(_ item: AgendaItem) -> Bool {
        guard item.path != nil else { return true }
        // Two or more `+` categories: any of them.
        let positive = categories.filter { $0.hasPrefix("+") }
        let categoryOK: Bool
        if positive.count > 1 {
            categoryOK = categories.contains { term($0, item.category == String($0.dropFirst())) }
        } else {
            categoryOK = categories.allSatisfy { term($0, item.category == String($0.dropFirst())) }
        }
        let tagsOK = tags.allSatisfy { term($0, Self.hasTag(String($0.dropFirst()), item.tags)) }
        let effortOK = efforts.allSatisfy { Self.compareEffort($0, item.effort) }
        // `case-fold-search` is on in the agenda.
        let regexpOK = regexps.allSatisfy { term($0, item.text.range(of: String($0.dropFirst()), options: [.regularExpression, .caseInsensitive]) != nil) }
        return categoryOK && tagsOK && effortOK && regexpOK
    }

    private func term(_ term: String, _ holds: Bool) -> Bool { term.hasPrefix("-") ? !holds : holds }

    /// `{regexp}` matches any tag; an empty tag matches lines with tags.
    static func hasTag(_ tag: String, _ tags: [String]) -> Bool {
        if tag.isEmpty { return !tags.isEmpty }
        if tag.hasPrefix("{"), tag.hasSuffix("}"), tag.count >= 2 {
            let pattern = String(tag.dropFirst().dropLast())
            return tags.contains { $0.range(of: pattern, options: .regularExpression) != nil }
        }
        return tags.contains(tag)
    }

    /// `org-agenda-filter-effort-form` and `org-agenda-compare-effort`, with
    /// `org-agenda-sort-noeffort-is-high` t. `-` before the comparison negates nothing, as in org.
    static func compareEffort(_ term: String, _ effort: String?) -> Bool {
        var e = term.dropFirst()
        let op = e.first
        e = e.dropFirst()
        let value = durationMinutes(String(e)) ?? 0
        let minutes = effort.flatMap(durationMinutes) ?? Double(Int.max)
        switch op {
        case "<": return minutes <= value
        case ">": return minutes >= value
        default: return minutes == value
        }
    }

    /// `org-duration-to-minutes` for `H:MM`, `H:MM:SS`, plain minutes and unit durations
    /// (`1h 30min`, `2d`).
    public static func durationMinutes(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let m = t.wholeMatch(of: /([0-9]+):([0-9]{2})(?::([0-9]{2}))?/) {
            return Double(m.1)! * 60 + Double(m.2)! + (m.3.map { Double($0)! / 60 } ?? 0)
        }
        if let n = Double(t) { return n }
        let units: [String: Double] = ["min": 1, "h": 60, "d": 1440, "w": 10080, "m": 43200, "y": 525960]
        var total = 0.0
        var matched = false
        for m in t.matches(of: /([0-9]+(?:\.[0-9]*)?)[ \t]*(min|h|d|w|m|y)\b/) {
            total += Double(m.1)! * units[String(m.2)]!
            matched = true
        }
        return matched ? total : nil
    }
}
