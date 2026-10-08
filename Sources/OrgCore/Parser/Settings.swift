public struct TodoKeyword: Sendable, Hashable {
    public var name: String
    public var fastKey: Character?
    /// Logging flag when entering the state (`!` or `@`), from `NAME(k!/@)`.
    public var logOnEnter: String?
    /// Logging flag when leaving the state.
    public var logOnLeave: String?

    public init(name: String, fastKey: Character? = nil, logOnEnter: String? = nil, logOnLeave: String? = nil) {
        self.name = name
        self.fastKey = fastKey
        self.logOnEnter = logOnEnter
        self.logOnLeave = logOnLeave
    }
}

public struct TodoSequence: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case sequence, type }

    public var kind: Kind
    public var active: [TodoKeyword]
    public var done: [TodoKeyword]

    public init(kind: Kind, active: [TodoKeyword], done: [TodoKeyword]) {
        self.kind = kind
        self.active = active
        self.done = done
    }
}

public struct Priorities: Sendable, Equatable {
    public var highest: String
    public var lowest: String
    public var `default`: String

    public init(highest: String, lowest: String, default: String) {
        self.highest = highest
        self.lowest = lowest
        self.default = `default`
    }
}

public struct OrgSettings: Sendable, Equatable {
    public var todoSequences: [TodoSequence]
    public var priorities: Priorities
    /// `<<<radio target>>>` texts in the file, longest first: their words elsewhere are links.
    public var radioTargets: [String] = []
    /// `org-list-allow-alphabetical`: `a.` and `A)` are bullets.
    public var listAllowAlphabetical = false
    /// Keyword lines from the file's `#+SETUPFILE`s, as `#+KEY: value` lines: they count as
    /// the file's own, before them.
    public var setupKeywords = ""
    /// Words of the `#+STARTUP` keyword lines outside blocks, setup files' first.
    public var startup: [String] = []

    public init(todoSequences: [TodoSequence], priorities: Priorities, radioTargets: [String] = []) {
        self.todoSequences = todoSequences
        self.priorities = priorities
        self.radioTargets = radioTargets
    }

    public static let `default` = OrgSettings(
        todoSequences: [TodoSequence(kind: .sequence, active: [TodoKeyword(name: "TODO")], done: [TodoKeyword(name: "DONE")])],
        priorities: Priorities(highest: "A", lowest: "C", default: "B")
    )

    public var todoKeywordNames: Set<String> {
        Set(todoSequences.flatMap { ($0.active + $0.done).map(\.name) })
    }

    /// These settings with TODO keywords from `#+TODO:` syntax (`TODO NEXT | DONE`), one
    /// sequence per line; nil when there are no keywords.
    public func withTodoKeywords(_ lines: String) -> OrgSettings? {
        let sequences = lines.split(separator: "\n").compactMap { SettingsScanner.todoSequence($0, kind: .sequence) }
        guard !sequences.isEmpty else { return nil }
        var copy = self
        copy.todoSequences = sequences
        return copy
    }

    public func isDone(_ name: String) -> Bool {
        todoSequences.contains { $0.done.contains { $0.name == name } }
    }
}

enum SettingsScanner {
    /// Reads `#+TODO`, `#+SEQ_TODO`, `#+TYP_TODO`, `#+PRIORITIES` and `#+STARTUP` outside blocks. Any TODO
    /// line replaces the default sequences; as in org, `TYP_TODO` sequences come first, then
    /// `TODO`, then `SEQ_TODO`.
    static func scan(lines: [RawLine], info: [ClassifiedLine], blockEnds: [Int: Int], defaults: OrgSettings) -> OrgSettings {
        var types: [TodoSequence] = [], todos: [TodoSequence] = [], seqs: [TodoSequence] = []
        var priorities = defaults.priorities
        var startup: [String] = []
        func apply(_ key: String, _ value: Substring) {
            switch key {
            case "TODO":
                if let s = todoSequence(value, kind: .sequence) { todos.append(s) }
            case "SEQ_TODO":
                if let s = todoSequence(value, kind: .sequence) { seqs.append(s) }
            case "TYP_TODO":
                if let s = todoSequence(value, kind: .type) { types.append(s) }
            case "STARTUP":
                startup += value.split(whereSeparator: \.isWhitespace).map(String.init)
            case "PRIORITIES":
                let words = value.split(whereSeparator: \.isWhitespace)
                if words.count == 3 {
                    priorities = Priorities(highest: String(words[0]), lowest: String(words[1]), default: String(words[2]))
                }
            default:
                break
            }
        }
        for (key, value) in SetupFile.keywords(defaults.setupKeywords) { apply(key, value) }
        var k = 0
        while k < lines.count {
            switch info[k].cls {
            case .blockBegin, .dynamicBegin:
                if let end = blockEnds[k] { k = end }
            case .keyword(let key):
                apply(key, keywordValue(lines[k].content))
            default:
                break
            }
            k += 1
        }
        let sequences = types + todos + seqs
        var radio: [String] = []
        for line in lines where line.content.contains("<<<") {
            for m in String(line.content).matches(of: /<<<([^<>\n\r \t](?:[^<>\n\r]*[^<>\n\r \t])?)>>>/) where !radio.contains(String(m.1)) {
                radio.append(String(m.1))
            }
        }
        var settings = OrgSettings(todoSequences: sequences.isEmpty ? defaults.todoSequences : sequences, priorities: priorities,
                                   radioTargets: radio.sorted { $0.count > $1.count })
        settings.listAllowAlphabetical = defaults.listAllowAlphabetical
        settings.setupKeywords = defaults.setupKeywords
        settings.startup = startup
        return settings
    }

    static func keywordValue(_ line: Substring) -> Substring {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...]
    }

    static func todoSequence(_ value: Substring, kind: TodoSequence.Kind) -> TodoSequence? {
        let words = value.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        if let bar = words.firstIndex(of: "|") {
            return TodoSequence(kind: kind, active: words[..<bar].map(todoKeyword), done: words[(bar + 1)...].map(todoKeyword))
        }
        return TodoSequence(kind: kind, active: words.dropLast().map(todoKeyword), done: [todoKeyword(words.last!)])
    }

    /// `NAME`, or `NAME(spec)` where spec is an optional fast key followed by `enter/leave`
    /// logging flags.
    static func todoKeyword(_ word: Substring) -> TodoKeyword {
        guard let open = word.firstIndex(of: "("), word.last == ")" else { return TodoKeyword(name: String(word)) }
        var spec = word[word.index(after: open)..<word.index(before: word.endIndex)]
        var fastKey: Character?
        if let first = spec.first, first != "!", first != "@", first != "/" {
            fastKey = first
            spec = spec.dropFirst()
        }
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        let enter = parts.first.flatMap { $0.isEmpty ? nil : String($0) }
        let leave = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return TodoKeyword(name: String(word[..<open]), fastKey: fastKey, logOnEnter: enter, logOnLeave: leave)
    }
}
