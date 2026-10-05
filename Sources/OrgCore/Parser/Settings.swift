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

    public init(todoSequences: [TodoSequence], priorities: Priorities) {
        self.todoSequences = todoSequences
        self.priorities = priorities
    }

    public static let `default` = OrgSettings(
        todoSequences: [TodoSequence(kind: .sequence, active: [TodoKeyword(name: "TODO")], done: [TodoKeyword(name: "DONE")])],
        priorities: Priorities(highest: "A", lowest: "C", default: "B")
    )

    public var todoKeywordNames: Set<String> {
        Set(todoSequences.flatMap { ($0.active + $0.done).map(\.name) })
    }

    /// These settings with TODO keywords from `#+TODO:` syntax (`TODO NEXT | DONE`); nil when
    /// the line has no keywords.
    public func withTodoKeywords(_ line: String) -> OrgSettings? {
        guard let sequence = SettingsScanner.todoSequence(Substring(line), kind: .sequence) else { return nil }
        var copy = self
        copy.todoSequences = [sequence]
        return copy
    }

    public func isDone(_ name: String) -> Bool {
        todoSequences.contains { $0.done.contains { $0.name == name } }
    }
}

enum SettingsScanner {
    /// Reads `#+TODO`, `#+SEQ_TODO`, `#+TYP_TODO` and `#+PRIORITIES` outside blocks. Any TODO
    /// line replaces the default sequences, as in org.
    static func scan(lines: [RawLine], info: [ClassifiedLine], blockEnds: [Int: Int], defaults: OrgSettings) -> OrgSettings {
        var sequences: [TodoSequence] = []
        var priorities = defaults.priorities
        var k = 0
        while k < lines.count {
            switch info[k].cls {
            case .blockBegin, .dynamicBegin:
                if let end = blockEnds[k] { k = end }
            case .keyword(let key):
                let value = keywordValue(lines[k].content)
                switch key {
                case "TODO", "SEQ_TODO":
                    if let s = todoSequence(value, kind: .sequence) { sequences.append(s) }
                case "TYP_TODO":
                    if let s = todoSequence(value, kind: .type) { sequences.append(s) }
                case "PRIORITIES":
                    let words = value.split(whereSeparator: \.isWhitespace)
                    if words.count == 3 {
                        priorities = Priorities(highest: String(words[0]), lowest: String(words[1]), default: String(words[2]))
                    }
                default:
                    break
                }
            default:
                break
            }
            k += 1
        }
        return OrgSettings(todoSequences: sequences.isEmpty ? defaults.todoSequences : sequences, priorities: priorities)
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
