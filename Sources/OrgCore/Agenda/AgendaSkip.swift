import Foundation

/// `org-agenda-skip-entry-if` and `org-agenda-skip-subtree-if` (Org 9.8.7) as
/// `org-agenda-skip-function`: an entry, or a whole subtree, is left out of a view when any
/// of the conditions holds.
public struct AgendaSkip: Sendable, Hashable {
    public enum Condition: Sendable, Hashable {
        case scheduled, notScheduled, deadline, notDeadline, timestamp, notTimestamp
        /// Emacs regexps.
        case regexp(String), notRegexp(String)
        case todo(Keywords), notTodo(Keywords)
    }

    /// What `todo` and `nottodo` take: keywords (`*` for any), or the class `todo`, `done`
    /// or `any`.
    public enum Keywords: Sendable, Hashable {
        case list([String])
        case open, done, any
    }

    public enum Failure: Error, Equatable {
        case message(String)
    }

    public var subtree: Bool
    public var conditions: [Condition]

    public init(subtree: Bool, conditions: [Condition]) {
        self.subtree = subtree
        self.conditions = conditions
    }

    /// The arguments as Lisp writes them: `'scheduled 'regexp "\\<IGNORE\\>" 'todo '("DONE")`,
    /// the quotes optional. Nil, with the reason, for what `org-agenda-skip-if` doesn't take.
    public static func parse(_ text: String, subtree: Bool) -> Result<AgendaSkip, Failure> {
        let forms: [Sexp]
        do {
            forms = try LispReader.read("(" + text + ")").first?.sexp.elements ?? []
        } catch {
            return .failure(.message("can't read \(text)"))
        }
        func unquote(_ s: Sexp) -> Sexp {
            if case .list(let items) = s, items.count == 2, items[0].symbol == "quote" { return items[1] }
            return s
        }
        let args = forms.map(unquote)
        var conditions: [Condition] = []
        var i = 0
        while i < args.count {
            guard let name = args[i].symbol else { return .failure(.message("\(args[i].description) isn't a condition")) }
            i += 1
            func next() -> Sexp? {
                defer { i += 1 }
                return i < args.count ? args[i] : nil
            }
            switch name {
            case "scheduled": conditions.append(.scheduled)
            case "notscheduled": conditions.append(.notScheduled)
            case "deadline": conditions.append(.deadline)
            case "notdeadline": conditions.append(.notDeadline)
            case "timestamp": conditions.append(.timestamp)
            case "nottimestamp": conditions.append(.notTimestamp)
            case "regexp", "notregexp":
                guard let re = next()?.string else { return .failure(.message("\(name) needs a string")) }
                conditions.append(name == "regexp" ? .regexp(re) : .notRegexp(re))
            case "todo", "nottodo":
                let keywords: Keywords
                switch next() {
                case .symbol("todo")?: keywords = .open
                case .symbol("done")?: keywords = .done
                case .symbol("any")?: keywords = .any
                case let arg?:
                    guard let items = arg.elements, items.allSatisfy({ $0.string != nil }) else { return .failure(.message("\(name) needs keywords or todo, done or any")) }
                    keywords = .list(items.compactMap(\.string))
                case nil: return .failure(.message("\(name) needs keywords or todo, done or any"))
                }
                conditions.append(name == "todo" ? .todo(keywords) : .notTodo(keywords))
            default:
                return .failure(.message("\(name) isn't supported"))
            }
        }
        return .success(AgendaSkip(subtree: subtree, conditions: conditions))
    }

    /// The conditions as `parse` reads them.
    public var lisp: String {
        conditions.map { condition in
            func keywords(_ k: Keywords) -> String {
                switch k {
                case .list(let words): "(" + words.map { "\"\($0)\"" }.joined(separator: " ") + ")"
                case .open: "todo"
                case .done: "done"
                case .any: "any"
                }
            }
            func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            return switch condition {
            case .scheduled: "scheduled"
            case .notScheduled: "notscheduled"
            case .deadline: "deadline"
            case .notDeadline: "notdeadline"
            case .timestamp: "timestamp"
            case .notTimestamp: "nottimestamp"
            case .regexp(let re): "regexp " + quoted(re)
            case .notRegexp(let re): "notregexp " + quoted(re)
            case .todo(let k): "todo " + keywords(k)
            case .notTodo(let k): "nottodo " + keywords(k)
            }
        }.joined(separator: " ")
    }


    /// `org-agenda-skip-if` at the heading `index`: where the scan continues when it is skipped
    /// (the next heading, or the end of the subtree), else nil. `caseFold` is the scan's
    /// `case-fold-search`: nil for the day and TODO scans, t for tags and search.
    func skipEnd(_ source: AgendaSource, heading index: Int, caseFold: Bool = false) -> Int? {
        let heading = source.headings[index]
        let ns = source.text as NSString
        let begin = heading.start
        let end: Int
        if subtree {
            // `org-end-of-subtree`: before the line break and blank lines ending it.
            var e = source.headings[(index + 1)...].first { $0.level <= heading.level }?.start ?? ns.length
            if e > begin, ns.character(at: e - 1) == 10 {
                e -= 1
                while e > begin, [10, 13, 9, 32].contains(ns.character(at: e - 1)) { e -= 1 }
            }
            end = e
        } else {
            end = index + 1 < source.headings.count ? source.headings[index + 1].start : ns.length
        }
        // The planning line is the one after the heading.
        var planningEnd = end
        if !subtree {
            let first = NSMaxRange(ns.lineRange(for: NSRange(location: begin, length: 0)))
            let second = first < ns.length ? ns.lineRange(for: NSRange(location: first, length: 0)) : NSRange(location: first, length: 0)
            var lineEnd = NSMaxRange(second)
            if lineEnd > second.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
            planningEnd = min(max(first, lineEnd), ns.length)
        }
        let fold: NSRegularExpression.Options = caseFold ? [.caseInsensitive, .anchorsMatchLines] : .anchorsMatchLines
        let scheduledRegex = try? NSRegularExpression(pattern: "\\bSCHEDULED: *<([^>]+)>", options: fold)
        let deadlineRegex = try? NSRegularExpression(pattern: "\\bDEADLINE: *<([^>]+)>", options: fold)
        let timestampRegex = try? NSRegularExpression(pattern: "<(\(AgendaSource.tsInternal))>", options: fold)
        func found(_ regex: NSRegularExpression?, _ limit: Int) -> Bool {
            guard let regex, limit > begin else { return false }
            return regex.firstMatch(in: source.text, range: NSRange(location: begin, length: limit - begin)) != nil
        }
        func todoRegex(_ keywords: Keywords) -> NSRegularExpression? {
            let done = source.keywords.filter { !source.notDoneKeywords.contains($0) }
            let words: [String] = switch keywords {
            case .open: source.notDoneKeywords
            case .done: done
            case .any: source.keywords
            case .list(let list): list.contains("*") ? source.keywords : list
            }
            guard !words.isEmpty else { return nil }
            let alternatives = words.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            return try? NSRegularExpression(pattern: "^\\*+[ \\t]+\\b(?:" + alternatives + ")\\b", options: .anchorsMatchLines)
        }
        func regex(_ emacs: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: EmacsRegex.translate(emacs), options: fold)
        }
        // `org-agenda-skip-if` tests in this order, whatever order the conditions are in.
        let c = conditions
        let first: (Condition) -> String? = { if case .regexp(let re) = $0 { re } else { nil } }
        let firstNot: (Condition) -> String? = { if case .notRegexp(let re) = $0 { re } else { nil } }
        let todoArgument = c.first { if case .notTodo = $0 { true } else if case .todo = $0 { true } else { false } }
        let notTodo = c.first { if case .notTodo = $0 { true } else { false } }
        var holds = (c.contains(.scheduled) && found(scheduledRegex, planningEnd))
            || (c.contains(.notScheduled) && !found(scheduledRegex, planningEnd))
            || (c.contains(.deadline) && found(deadlineRegex, planningEnd))
            || (c.contains(.notDeadline) && !found(deadlineRegex, planningEnd))
            || (c.contains(.timestamp) && found(timestampRegex, end))
            || (c.contains(.notTimestamp) && !found(timestampRegex, end))
        if !holds, let re = c.lazy.compactMap(first).first { holds = found(regex(re), end) }
        if !holds, let re = c.lazy.compactMap(firstNot).first { holds = !found(regex(re), end) }
        // `nottodo` is looked for before `todo`.
        if !holds, let condition = notTodo ?? todoArgument {
            switch condition {
            case .todo(let k): holds = found(todoRegex(k), end)
            case .notTodo(let k): holds = !found(todoRegex(k), end)
            default: break
            }
        }
        return holds ? end : nil
    }
}

/// `org-agenda-skip` for one scan of one file: candidates come in buffer order, and a skip
/// moves the scan past the entry or subtree, leaving out the candidates there too.
struct Skipper {
    let skip: AgendaSkip?
    let source: AgendaSource
    let caseFold: Bool
    var until = 0

    init(_ skip: AgendaSkip?, _ source: AgendaSource, caseFold: Bool = false) {
        self.skip = skip
        self.source = source
        self.caseFold = caseFold
    }

    /// Whether the candidate at `position`, in the heading `index`, is skipped.
    mutating func skips(_ position: Int, heading index: Int) -> Bool {
        guard let skip else { return false }
        if position < until { return true }
        if let end = skip.skipEnd(source, heading: index, caseFold: caseFold) {
            until = end
            return true
        }
        return false
    }
}
