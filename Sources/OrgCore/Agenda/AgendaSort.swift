import Foundation

/// `org-agenda-sorting-strategy` and `org-entries-lessp` (Org 9.8.7).
public enum AgendaSort {
    /// The strategies `org-entries-lessp` knows, without the user-defined ones.
    public static let keys: Set<String> = [
        "time-up", "time-down", "timestamp-up", "timestamp-down", "scheduled-up", "scheduled-down", "deadline-up", "deadline-down",
        "ts-up", "ts-down", "tsia-up", "tsia-down", "stats-up", "stats-down", "priority-up", "priority-down", "urgency-up", "urgency-down",
        "effort-up", "effort-down", "category-up", "category-down", "category-keep", "tag-up", "tag-down", "todo-state-up",
        "todo-state-down", "habit-up", "habit-down", "alpha-up", "alpha-down",
    ]

    /// Org's, except the agenda sorts by time before habits, so timed habits go among timed entries.
    public static let defaults: [String: [String]] = [
        "agenda": ["time-up", "habit-down", "urgency-down", "category-keep"],
        "todo": ["urgency-down", "category-keep"],
        "tags": ["urgency-down", "category-keep"],
        "search": ["category-keep"],
    ]

    /// `org-entries-lessp` for one strategy: -1, +1, or nil to try the next.
    static func compare(_ key: String, _ a: AgendaItem, _ b: AgendaItem, _ options: AgendaOptions) -> Int? {
        func values<T: Comparable>(_ x: T, _ y: T) -> Int? { x > y ? 1 : x < y ? -1 : nil }
        func ts(_ x: AgendaItem, _ y: AgendaItem, _ type: String) -> Int? {
            func date(_ item: AgendaItem) -> Int {
                (type.isEmpty || item.tsType.contains(type) ? item.tsDate : nil) ?? (options.sortNotimeIsLate ? Int.max : -1)
            }
            return values(date(x), date(y))
        }
        func time(_ x: AgendaItem, _ y: AgendaItem) -> Int? {
            let def = options.sortNotimeIsLate ? 9901 : -1
            return values(x.timeOfDay ?? def, y.timeOfDay ?? def)
        }
        func effort(_ x: AgendaItem, _ y: AgendaItem) -> Int? {
            let def = options.sortNoeffortIsHigh ? Double(Int.max) : -1
            return values(x.effortMinutes ?? def, y.effortMinutes ?? def)
        }
        func category(_ x: AgendaItem, _ y: AgendaItem) -> Int? { values(x.category, y.category) }
        func optional(_ x: String?, _ y: String?) -> Int? {
            switch (x, y) {
            case (nil, nil): return nil
            case (nil, _): return 1
            case (_, nil): return -1
            case let (x?, y?): return values(x, y)
            }
        }
        func todoState(_ x: AgendaItem, _ y: AgendaItem) -> Int? {
            let doneX = x.todoDone, doneY = y.todoDone
            if doneX, !doneY { return -1 }
            if !doneX, doneY { return 1 }
            return x.todoRank < y.todoRank ? -1 : y.todoRank < x.todoRank ? 1 : nil
        }
        func habit(_ x: AgendaItem, _ y: AgendaItem) -> Int? {
            x.habit != nil && y.habit == nil ? -1 : x.habit == nil && y.habit != nil ? 1 : nil
        }
        switch key {
        case "timestamp-up": return ts(a, b, "")
        case "timestamp-down": return ts(b, a, "")
        case "scheduled-up": return ts(a, b, "scheduled")
        case "scheduled-down": return ts(b, a, "scheduled")
        case "deadline-up": return ts(a, b, "deadline")
        case "deadline-down": return ts(b, a, "deadline")
        case "tsia-up": return ts(a, b, "timestamp_ia")
        case "tsia-down": return ts(b, a, "timestamp_ia")
        case "ts-up": return ts(a, b, "timestamp")
        case "ts-down": return ts(b, a, "timestamp")
        case "time-up": return time(a, b)
        case "time-down": return time(b, a)
        case "priority-up": return values(a.priority, b.priority)
        case "priority-down": return values(b.priority, a.priority)
        case "urgency-up": return values(a.urgency, b.urgency)
        case "urgency-down": return values(b.urgency, a.urgency)
        case "effort-up": return effort(a, b)
        case "effort-down": return effort(b, a)
        case "category-up": return category(a, b)
        case "category-down": return category(b, a)
        case "category-keep": return category(a, b).map { _ in 1 }
        case "tag-up": return optional(a.tags.last, b.tags.last)
        case "tag-down": return optional(b.tags.last, a.tags.last)
        case "todo-state-up": return todoState(a, b)
        case "todo-state-down": return todoState(b, a)
        case "habit-up": return habit(a, b)
        case "habit-down": return habit(b, a)
        case "alpha-up": return optional(a.alpha, b.alpha)
        case "alpha-down": return optional(b.alpha, a.alpha)
        // `org-stats` is never set on agenda lines.
        default: return nil
        }
    }

    static func lessp(_ a: AgendaItem, _ b: AgendaItem, _ strategy: [String], _ options: AgendaOptions) -> Bool {
        for key in strategy {
            if let result = compare(key, a, b, options) { return result < 0 }
        }
        return false
    }

    /// `(sort list #'org-entries-lessp)` with the strategy for `view`. Emacs's sort is timsort,
    /// which for lists this short takes the leading run and binary-inserts the rest; done the
    /// same way, strategies that end comparisons early (`category-keep`) order as in Emacs.
    static func sort(_ items: [AgendaItem], view: String, options: AgendaOptions) -> [AgendaItem] {
        let strategy = options.sortingStrategy[view] ?? defaults[view] ?? []
        guard items.count > 1, !strategy.isEmpty else { return items }
        func lt(_ a: AgendaItem, _ b: AgendaItem) -> Bool { lessp(a, b, strategy, options) }
        var list = items
        // `count_run`: an ascending run, or a strictly descending one reversed.
        var run = 2
        if lt(list[1], list[0]) {
            while run < list.count, lt(list[run], list[run - 1]) { run += 1 }
            list[0..<run].reverse()
        } else {
            while run < list.count, !lt(list[run], list[run - 1]) { run += 1 }
        }
        // `binarysort`.
        for start in run..<list.count {
            let pivot = list[start]
            var l = 0, r = start
            while l < r {
                let p = l + (r - l) / 2
                if lt(pivot, list[p]) { r = p } else { l = p + 1 }
            }
            list.remove(at: start)
            list.insert(pivot, at: l)
        }
        return list
    }

    /// `org-agenda-entry-get-agenda-timestamp`: the day of the timestamp the TODO and tags
    /// views sort by, from the first ts strategy, and the type it adds.
    static func entryTimestamp(_ heading: AgendaSource.Heading, strategy: [String]) -> (day: Int?, type: String) {
        func has(_ a: String, _ b: String) -> Bool { strategy.contains(a) || strategy.contains(b) }
        let ts: String?
        let type: String
        if has("scheduled-up", "scheduled-down") {
            (ts, type) = (heading.scheduled?.raw, " scheduled")
        } else if has("deadline-up", "deadline-down") {
            (ts, type) = (heading.deadline?.raw, " deadline")
        } else if has("ts-up", "ts-down") {
            (ts, type) = (heading.firstActive, " timestamp")
        } else if has("tsia-up", "tsia-down") {
            (ts, type) = (heading.firstInactive, " timestamp_ia")
        } else if has("timestamp-up", "timestamp-down") {
            (ts, type) = (heading.scheduled?.raw ?? heading.deadline?.raw ?? heading.firstActive ?? heading.firstInactive, "")
        } else {
            (ts, type) = (nil, "")
        }
        return (ts.flatMap(Days.absolute(of:)), type)
    }

    /// The heading text `alpha-up` compares: from `org-heading` on, without the TODO keyword
    /// and a `[x]` cookie, lower-cased. Sexp entries have no keyword regexp (`keywords` empty).
    static func alpha(_ text: String, keywords: [String]) -> String {
        var t = text
        let todo = keywords.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = "^[ \\t]*" + (todo.isEmpty ? "" : "(?:" + todo + ")") + "([ \\t]*\\[[a-zA-Z0-9]\\])? *"
        if let r = t.range(of: pattern, options: .regularExpression) { t = String(t[r.upperBound...]) }
        return t.lowercased()
    }
}
