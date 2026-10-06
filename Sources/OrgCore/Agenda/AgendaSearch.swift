import Foundation

extension Agenda {
    /// `org-todo-list`: unfinished entries, or with `keywords` (`WAIT|HOLD`) those with any of
    /// the keywords.
    public static func todoList(_ sources: [AgendaSource], keywords: String? = nil, options: AgendaOptions = AgendaOptions()) -> [AgendaItem] {
        let selected = keywords.map { $0.split(separator: "|").map(String.init) }
        var items: [AgendaItem] = []
        for source in sources {
            for heading in source.headings where !heading.skipped {
                guard let todo = heading.todo else { continue }
                if let selected {
                    guard selected.contains(todo) else { continue }
                } else if heading.isDone {
                    continue
                }
                items.append(format(
                    source, heading, kind: .todo, marker: heading.start, extra: "", dotime: .headline, removing: nil,
                    trailing: "", prefix: options.prefix("todo"), urgency: { 1 + $0 }
                ))
            }
        }
        return sortByUrgency(items)
    }

    /// `org-tags-view`: entries matching a tags/property/TODO match string. `todoOnly` keeps
    /// unfinished TODO entries, as `M` does.
    public static func tagsMatch(
        _ sources: [AgendaSource], match: String, todoOnly: Bool = false, now: Date = Date(), calendar: Calendar = .current,
        options: AgendaOptions = AgendaOptions()
    ) -> [AgendaItem] {
        let matcher = TagsMatcher(match, todoOnly: todoOnly)
        var items: [AgendaItem] = []
        for source in sources {
            for heading in source.headings {
                if matcher.todoOnly, heading.todo == nil { continue }
                guard matcher.matches(heading, in: source, now: now, calendar: calendar), !heading.skipped else { continue }
                items.append(format(
                    source, heading, kind: .tagsMatch, marker: heading.start, extra: "", dotime: nil, removing: nil,
                    trailing: "", prefix: options.prefix("tags"), urgency: { $0 }
                ))
            }
        }
        return sortByUrgency(items)
    }

    /// `(urgency-down category-keep)`, stably.
    static func sortByUrgency(_ items: [AgendaItem]) -> [AgendaItem] {
        items.enumerated().sorted { a, b in
            a.element.urgency != b.element.urgency ? a.element.urgency > b.element.urgency : a.offset < b.offset
        }.map(\.element)
    }
}

/// `org-make-tags-matcher`: `+work-boss|LEVEL>2+TODO="WAIT"/!NEXT`.
public struct TagsMatcher: Sendable {
    indirect enum Term: Sendable {
        case tag(String)
        case tagRegex(String)
        case property(name: String, op: String, value: Value, needsValue: Bool)
        case not(Term)
    }

    enum Value: Sendable {
        case regex(String)
        case string(String)
        case time(String)
        case number(Double)
    }

    /// Alternatives of conjunctions; nil matches everything.
    let tags: [[Term]]?
    let todo: [[(regex: Bool, keyword: String, negated: Bool)]]?
    let todoOnly: Bool

    static let term = try! NSRegularExpression(pattern:
        "^&?([-+:])?(\\{[^}]+\\}|(?:((?:[\\p{L}\\p{N}_]|\\\\[^\\s])+)([<=>]=?|[!/]=|<>)(\\*)?(\\{[^}]+\\}|\"[^\"]*\"|-?[.0-9]+(?:[eE][-+]?[0-9]+)?))|[\\p{L}\\p{N}_@#%]+)"
    )
    static let timeValue = try! NSRegularExpression(pattern: "^\"[\\[<](?:[0-9]+|now|today|tomorrow|[+-][0-9]+[dmwy]).*[\\]>]\"$")

    public init(_ match: String, todoOnly: Bool = false) {
        var only = todoOnly
        var tagsPart = match
        var todoPart: String?
        let ns = match as NSString
        let slashes = try! NSRegularExpression(pattern: "/+")
        if let last = slashes.matches(in: match, range: NSRange(location: 0, length: ns.length)).last,
           !ns.substring(from: last.range.location).contains("\"") {
            tagsPart = ns.substring(to: last.range.location)
            var rest = ns.substring(from: NSMaxRange(last.range))
            if rest.hasPrefix("!") {
                only = true
                rest.removeFirst()
            }
            todoPart = rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rest
        }
        self.todoOnly = only

        func terms(_ s: String) -> [(sign: String?, match: NSTextCheckingResult, text: NSString)] {
            var result: [(String?, NSTextCheckingResult, NSString)] = []
            var rest = s
            while let m = Self.term.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                let text = rest as NSString
                let sign = m.range(at: 1).location != NSNotFound ? text.substring(with: m.range(at: 1)) : nil
                result.append((sign, m, text))
                rest = text.substring(from: NSMaxRange(m.range))
                if m.range.length == 0 { break }
            }
            return result
        }

        if tagsPart.contains(where: { !$0.isWhitespace }) {
            var alternatives: [[Term]] = []
            var parts = Self.split(tagsPart)
            var i = 0
            while i < parts.count {
                var part = parts[i]
                // A `\|` inside a term is not a separator.
                while part.hasSuffix("\\"), i + 1 < parts.count {
                    i += 1
                    part += "|" + parts[i]
                }
                var conjunction: [Term] = []
                for (sign, m, text) in terms(part) {
                    let whole = text.substring(with: m.range(at: 2))
                    var term: Term
                    if whole.hasPrefix("{") {
                        term = .tagRegex(String(whole.dropFirst().dropLast()))
                    } else if m.range(at: 3).location != NSNotFound {
                        let name = text.substring(with: m.range(at: 3))
                            .replacingOccurrences(of: "\\\\(.)", with: "$1", options: .regularExpression).uppercased()
                        let raw = text.substring(with: m.range(at: 6))
                        let value: Value
                        if raw.hasPrefix("{") {
                            value = .regex(String(raw.dropFirst().dropLast()))
                        } else if raw.hasPrefix("\"") {
                            let inner = String(raw.dropFirst().dropLast())
                            let isTime = Self.timeValue.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) != nil
                            value = isTime ? .time(inner) : .string(inner)
                        } else {
                            value = .number(Self.number(raw))
                        }
                        term = .property(name: name, op: text.substring(with: m.range(at: 4)), value: value, needsValue: m.range(at: 5).location != NSNotFound)
                    } else {
                        term = .tag(whole)
                    }
                    if sign == "-" { term = .not(term) }
                    conjunction.append(term)
                }
                alternatives.append(conjunction)
                i += 1
            }
            tags = alternatives
        } else {
            tags = nil
        }

        if let todoPart {
            todo = Self.split(todoPart).map { part in
                terms(part).map { sign, m, text in
                    let keyword = text.substring(with: m.range(at: 2))
                    return keyword.hasPrefix("{")
                        ? (true, String(keyword.dropFirst().dropLast()), sign == "-")
                        : (false, keyword, sign == "-")
                }
            }
        } else {
            todo = nil
        }
    }

    /// `org-split-string` on `|`: empty strings between separators stay.
    static func split(_ s: String) -> [String] {
        var parts = s.components(separatedBy: "|")
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "", !parts.isEmpty { parts.removeLast() }
        return parts.isEmpty ? [""] : parts
    }

    /// `string-to-number`: the leading number, or 0.
    static func number(_ s: String) -> Double {
        let trimmed = s.drop { $0 == " " || $0 == "\t" }
        guard let r = trimmed.range(of: "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?", options: .regularExpression) else { return 0 }
        return Double(trimmed[r]) ?? 0
    }

    func matches(_ heading: AgendaSource.Heading, in source: AgendaSource, now: Date, calendar: Calendar) -> Bool {
        let todoKeyword = heading.todo
        if todoOnly {
            guard let todoKeyword, !heading.isDone else { return false }
            _ = todoKeyword
        }
        let tagList = heading.tags.map(\.name)
        func value(_ name: String) -> String? {
            switch name {
            case "LEVEL": return String(heading.level)
            case "CATEGORY": return heading.category
            case "TODO": return heading.todo
            case "ITEM": return heading.title
            case "PRIORITY": return heading.priority ?? source.priorities.default
            case "FILE": return source.path
            case "TAGS": return heading.localTags.isEmpty ? nil : ":" + heading.localTags.joined(separator: ":") + ":"
            case "ALLTAGS": return tagList.isEmpty ? nil : ":" + tagList.joined(separator: ":") + ":"
            case "SCHEDULED", "DEADLINE", "CLOSED": return heading.planning[name]
            case "TIMESTAMP": return heading.firstActive
            case "TIMESTAMP_IA": return heading.firstInactive
            default: return heading.properties[name]
            }
        }
        func evaluate(_ term: Term) -> Bool {
            switch term {
            case .not(let inner):
                return !evaluate(inner)
            case .tag(let tag):
                return tagList.contains(tag)
            case .tagRegex(let pattern):
                return tagList.contains { EmacsRegex.matches(pattern, $0) }
            case .property(let name, let op, let expected, let needsValue):
                let found = value(name)
                if needsValue, found == nil { return false }
                let actual = found ?? ""
                switch expected {
                case .regex(let pattern):
                    let hit = EmacsRegex.matches(pattern, actual)
                    return op == "/=" ? !hit : hit
                case .string(let string):
                    return Self.compare(op, actual, string)
                case .number(let number):
                    return Self.compare(op, Self.number(actual), number)
                case .time(let time):
                    let a = Self.seconds(actual, now: now, calendar: calendar)
                    let b = Self.matcherTime(time, now: now, calendar: calendar)
                    guard a > 0, b > 0 else { return false }
                    // `org-time<>` compares with `=`.
                    return op == "<>" || op == "!=" || op == "/=" ? a == b : Self.compare(op, a, b)
                }
            }
        }
        if let tags, !tags.contains(where: { $0.allSatisfy(evaluate) }) { return false }
        if let todo {
            let ok = todo.contains { conjunction in
                conjunction.allSatisfy { term in
                    let hit = term.regex
                        ? todoKeyword.map { EmacsRegex.matches(term.keyword, $0) } ?? false
                        : todoKeyword == term.keyword
                    return term.negated ? !hit : hit
                }
            }
            if !ok { return false }
        }
        return true
    }

    static func compare<T: Comparable>(_ op: String, _ a: T, _ b: T) -> Bool {
        switch op {
        case "<": a < b
        case ">": a > b
        case "<=", "=<": a <= b
        case ">=", "=>": a >= b
        case "=", "==": a == b
        default: a != b
        }
    }

    /// `org-2ft`: a timestamp string as seconds, or 0.
    static func seconds(_ s: String, now: Date, calendar: Calendar) -> Double {
        let ns = s as NSString
        guard let m = Days.dateRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return 0 }
        var c = DateComponents(year: Int(ns.substring(with: m.range(at: 1))), month: Int(ns.substring(with: m.range(at: 2))), day: Int(ns.substring(with: m.range(at: 3))))
        let hour = Days.hour(of: s)
        c.hour = hour
        if let time = try? NSRegularExpression(pattern: " ([0-9]{1,2}):([0-9]{2})").firstMatch(in: s, range: NSRange(location: NSMaxRange(m.range), length: ns.length - NSMaxRange(m.range))), Int(ns.substring(with: time.range(at: 1))) == hour {
            c.minute = Int(ns.substring(with: time.range(at: 2)))
        }
        return calendar.date(from: c)?.timeIntervalSince1970 ?? 0
    }

    /// `org-matcher-time`.
    static func matcherTime(_ s: String, now: Date, calendar: Calendar) -> Double {
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        switch s {
        case "<now>": return now.timeIntervalSince1970
        case "<today>": return today
        case "<tomorrow>": return today + 86400
        case "<yesterday>": return today - 86400
        default: break
        }
        let ns = s as NSString
        if let m = try! NSRegularExpression(pattern: "^<([-+][0-9]+)([hdwmy])>$").firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            let n = Double(ns.substring(with: m.range(at: 1)))!
            let unit = ns.substring(with: m.range(at: 2))
            let size: Double = ["h": 3600, "d": 86400, "w": 604800, "m": 2678400, "y": 31557600][unit]!
            return (unit == "h" ? now.timeIntervalSince1970 : today) + n * size
        }
        return seconds(s, now: now, calendar: calendar)
    }
}

/// Emacs regular expressions run through ICU, case-insensitively as the matcher binds
/// `case-fold-search`.
enum EmacsRegex {
    static func translate(_ pattern: String) -> String {
        var out = ""
        var chars = Array(pattern)
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if inClass {
                if c == "]" { inClass = false }
                if c == "[" , i + 1 < chars.count, chars[i + 1] == ":" {
                    // `[:alpha:]` passes through.
                    if let end = String(chars[i...]).range(of: ":]") {
                        let length = String(chars[i...]).distance(from: String(chars[i...]).startIndex, to: end.upperBound)
                        out += String(chars[i..<(i + length)])
                        i += length
                        continue
                    }
                }
                out += c == "\\" ? "\\\\" : String(c)
                i += 1
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "(":
                    if i + 3 < chars.count, chars[i + 2] == "?", chars[i + 3] == ":" {
                        out += "(?:"
                        i += 4
                        continue
                    }
                    out += "("
                case ")": out += ")"
                case "|": out += "|"
                case "{": out += "{"
                case "}": out += "}"
                case "<", ">": out += "\\b"
                case "`": out += "^"
                case "'": out += "$"
                case "w": out += "[\\p{L}\\p{N}]"
                case "W": out += "[^\\p{L}\\p{N}]"
                default: out += "\\" + String(n)
                }
                i += 2
                continue
            }
            switch c {
            case "(", ")", "|", "{", "}": out += "\\" + String(c)
            case "[":
                inClass = true
                out += "["
                if i + 1 < chars.count, chars[i + 1] == "^" { out += "^"; i += 1 }
                if i + 1 < chars.count, chars[i + 1] == "]" { out += "\\]"; i += 1 }
            default: out += String(c)
            }
            i += 1
        }
        chars = []
        return out
    }

    static func matches(_ pattern: String, _ string: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: translate(pattern), options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }
}
