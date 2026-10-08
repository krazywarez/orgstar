import Foundation

// Fast TODO and tag selection (`org-fast-todo-selection`, `org-fast-tag-selection`, Org 9.8.7)
// with `org-use-fast-*-selection` `auto`, `org-fast-tag-selection-single-key` nil and no TODO
// keywords among the tags. The editor shows the keys; the answer is the keys pressed, which
// `FastSelection` replays as org does.

/// What a fast selection prompt shows and how its keys act.
public struct FastSelection: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        case option(key: Character, name: String)
        /// `{`: the options up to `endGroup` exclude each other (tags).
        case startGroup
        case endGroup
        /// `[`, `]` and `:` of a group tag; shown, without effect on selection.
        case startTagGroup, endTagGroup, groupTags
        case newline
        /// A line of text above the options that follow (`org-clock-select-task`'s sections).
        case label(String)
    }

    public let items: [Item]
    /// Tags: keys toggle until Return. TODO keywords: one key answers.
    public let multiple: Bool
    public let current: [String]
    public let inherited: [String]

    public init(items: [Item], multiple: Bool, current: [String] = [], inherited: [String] = []) {
        self.items = items
        self.multiple = multiple
        self.current = current
        self.inherited = inherited
    }

    public var options: [(key: Character, name: String)] {
        items.compactMap { if case .option(let key, let name) = $0 { (key, name) } else { nil } }
    }

    /// The `{ }` groups' members.
    var groups: [[String]] {
        var groups: [[String]] = []
        var inGroup = false
        for item in items {
            switch item {
            case .startGroup: groups.append([]); inGroup = true
            case .endGroup: inGroup = false
            case .option(_, let name) where inGroup: groups[groups.count - 1].append(name)
            default: break
            }
        }
        return groups
    }

    /// A key pressed in a tag selection, or a tag typed after Tab.
    public enum Input: Sendable, Equatable {
        case key(Character)
        case typed(String)
    }

    /// The answer a prompt sends: keys as themselves, a typed tag between Tab and newline.
    public static func encode(_ inputs: [Input]) -> String {
        inputs.map { input in
            switch input {
            case .key(let c): String(c)
            case .typed(let tag): "\t" + tag + "\n"
            }
        }.joined()
    }

    public static func decode(_ answer: String) -> [Input] {
        var inputs: [Input] = []
        var rest = Substring(answer)
        while let c = rest.first {
            rest = rest.dropFirst()
            if c == "\t" {
                let tag = rest.prefix { $0 != "\n" }
                inputs.append(.typed(String(tag)))
                rest = rest.dropFirst(tag.count + 1)
            } else {
                inputs.append(.key(c))
            }
        }
        return inputs
    }

    /// The tags after `inputs`, or nil when they quit (`q` with no binding, or C-g).
    public func tags(after inputs: [Input]) -> [String]? {
        var current = self.current
        var groupsOn = true
        let order = options.map(\.name)
        for input in inputs {
            switch input {
            case .key("!"): groupsOn.toggle()
            case .key(" "): current = []
            case .key("\u{7}"): return nil
            case .key(let c):
                if let tag = options.first(where: { $0.key == c })?.name {
                    current = Self.toggle(tag, current, groups: groupsOn ? groups : [])
                } else if c == "q" {
                    return nil
                }
            case .typed(let tag):
                guard tag.contains(where: { !$0.isWhitespace }) else { continue }
                current = Self.toggle(tag, current, groups: groupsOn ? groups : [])
            }
            // Sorted by the table's order; tags not in it keep theirs, after.
            current = current.enumerated().sorted { a, b in
                let ia = order.firstIndex(of: a.element) ?? Int.max
                let ib = order.firstIndex(of: b.element) ?? Int.max
                return ia != ib ? ia < ib : a.offset < b.offset
            }.map(\.element)
        }
        return current
    }

    /// `org--add-or-remove-tag`.
    static func toggle(_ tag: String, _ current: [String], groups: [[String]]) -> [String] {
        if current.contains(tag) { return current.filter { $0 != tag } }
        var current = current
        for group in groups where group.contains(tag) { current.removeAll { group.contains($0) } }
        return [tag] + current
    }

    // MARK: - TODO keywords

    /// `org-todo-key-alist` after `org-assign-fast-keys`, when any keyword has a key.
    static func todo(_ settings: OrgSettings) -> FastSelection? {
        guard settings.todoSequences.contains(where: { ($0.active + $0.done).contains { $0.fastKey != nil } }) else { return nil }
        var items: [Item] = []
        let all = settings.todoSequences.flatMap { $0.active + $0.done }
        var used = Set(all.compactMap(\.fastKey))
        var assigned: [Character] = []
        var alternative = Character("0")
        for keyword in all {
            if let key = keyword.fastKey { assigned.append(key); continue }
            var letters = Array(keyword.name.lowercased())
            if letters.first == "@" { letters.removeFirst() }
            let key = letters.first { !used.contains($0) } ?? {
                while used.contains(alternative) { alternative = Character(UnicodeScalar(alternative.unicodeScalars.first!.value + 1)!) }
                return alternative
            }()
            used.insert(key)
            assigned.append(key)
        }
        var index = 0
        for sequence in settings.todoSequences {
            items.append(.startGroup)
            for keyword in sequence.active + sequence.done {
                items.append(.option(key: assigned[index], name: keyword.name))
                index += 1
            }
            items.append(.endGroup)
        }
        return FastSelection(items: items, multiple: false)
    }

    /// The keyword for `key`, preferring the sequence of `current`; `.some(nil)` clears it,
    /// nil quits.
    func keyword(for key: Character, current: String?) -> String?? {
        if key == " " { return .some(nil) }
        var sequences: [[(key: Character, name: String)]] = []
        for item in items {
            switch item {
            case .startGroup: sequences.append([])
            case .option(let k, let name): sequences[sequences.count - 1].append((k, name))
            default: break
            }
        }
        if let current, let preferred = sequences.first(where: { $0.contains { $0.name == current } }),
           let match = preferred.first(where: { $0.key == key }) {
            return .some(match.name)
        }
        return options.first { $0.key == key }.map { .some($0.name) } ?? nil
    }

    // MARK: - Tags

    /// `org-tag-string-to-alist` of the file's `#+TAGS` lines, or nil without any.
    static func tagTable(_ text: String) -> [Item]? {
        let regex = try! NSRegularExpression(pattern: "^[ \\t]*#\\+TAGS:[ \\t]*(.*?)[ \\t]*$", options: [.anchorsMatchLines, .caseInsensitive])
        let ns = text as NSString
        let lines = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        guard !lines.isEmpty else { return nil }
        var items: [Item] = []
        var names: Set<String> = []
        var inGroup = false
        for line in lines.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: true) {
            items.append(.newline)
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            for (i, token) in tokens.enumerated() {
                switch token {
                case "{":
                    items.append(.startGroup)
                    if i + 2 < tokens.count, tokens[i + 2] == ":" { inGroup = true }
                case "}": items.append(.endGroup); inGroup = false
                case "[":
                    items.append(.startTagGroup)
                    if i + 2 < tokens.count, tokens[i + 2] == ":" { inGroup = true }
                case "]": items.append(.endTagGroup); inGroup = false
                case ":": items.append(.groupTags)
                default:
                    guard let match = token.firstMatch(of: /^([\p{L}\p{N}_@#%]+|\{.+?\})(?:\((.)\))?$/) else { continue }
                    let name = String(match.1)
                    if inGroup || !names.contains(name) {
                        names.insert(name)
                        items.append(.option(key: match.2.flatMap(\.first) ?? "\0", name: name))
                    }
                }
            }
        }
        items.removeFirst()
        return items
    }

    /// The selection `org-fast-tag-selection` shows for `table` (keys given as `\0` are
    /// assigned), or nil when no tag in the table has a key.
    static func tags(table: [Item], current: [String], inherited: [String]) -> FastSelection? {
        let given = table.compactMap { if case .option(let key, _) = $0, key != "\0" { key } else { nil } }
        guard !given.isEmpty else { return nil }
        let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ{|}~")
        var spare = pool[...]
        var assigned: [Character] = []
        var items: [Item] = []
        for item in table {
            guard case .option(let key, let name) = item else { items.append(item); continue }
            if key != "\0" {
                assigned.append(key)
                items.append(item)
                continue
            }
            var letters = Array(name.lowercased())
            if letters.first == "@" { letters.removeFirst() }
            let taken = { (c: Character) in given.contains(c) || assigned.contains(c) }
            var chosen: Character = " "
            if let first = letters.first, !taken(first) {
                chosen = first
            } else {
                while let c = spare.first, taken(c) { spare = spare.dropFirst() }
                chosen = spare.first ?? " "
            }
            assigned.append(chosen)
            items.append(.option(key: chosen, name: name))
        }
        return FastSelection(items: items, multiple: true, current: current, inherited: inherited)
    }
}
