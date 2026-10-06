import Foundation

public struct KeyBinding: Sendable, Equatable {
    public let keys: [KeyChord]
    /// A command id, or `none` to unbind keys an earlier layer bound.
    public let command: String
    /// A context name (`KeyContext`); nil binds everywhere.
    public let when: String?
    /// A modal state; nil binds outside modal editing.
    public let mode: String?

    public init(keys: [KeyChord], command: String, when: String? = nil, mode: String? = nil) {
        self.keys = keys
        self.command = command
        self.when = when
        self.mode = mode
    }

    public var unbinds: Bool { command == "none" }
}

/// Bindings in priority order: later bindings win over earlier ones for the same keys.
/// Layers are concatenated: preset, then the user's file.
public struct Keymap: Sendable, Equatable {
    public private(set) var bindings: [KeyBinding]

    public init(_ bindings: [KeyBinding] = []) {
        self.bindings = bindings
    }

    /// Reads `[[bind]]` tables. Entries that can't be used are skipped and reported in
    /// `problems`; a file that isn't valid TOML throws.
    public init(toml: String, problems: inout [String]) throws {
        bindings = []
        for table in try TOML.parse(toml) where !(table.name.isEmpty && table.values.isEmpty) {
            guard table.name == "bind", table.isArrayElement else {
                problems.append("line \(table.line): unknown table [\(table.name)]")
                continue
            }
            guard let keyText = table.values["keys"]?.string, let keys = KeySequence.parse(keyText) else {
                problems.append("line \(table.line): bad or missing keys")
                continue
            }
            guard let command = table.values["command"]?.string, !command.isEmpty else {
                problems.append("line \(table.line): missing command")
                continue
            }
            let when = table.values["when"]?.string
            if let when, !KeyContext.names.contains(when) {
                problems.append("line \(table.line): unknown context \(when)")
                continue
            }
            bindings.append(KeyBinding(keys: keys, command: command, when: when, mode: table.values["mode"]?.string))
        }
    }

    public static func layered(_ layers: [Keymap]) -> Keymap {
        Keymap(layers.flatMap(\.bindings))
    }

    /// Bindings for exactly `keys` in `mode`, highest priority first. An unbinding with no
    /// context hides everything below it.
    public func candidates(for keys: [KeyChord], mode: String? = nil) -> [KeyBinding] {
        var result: [KeyBinding] = []
        for binding in bindings.reversed() where binding.mode == mode && binding.keys == keys {
            if binding.unbinds {
                if binding.when == nil { break }
                continue
            }
            result.append(binding)
        }
        return result
    }

    /// Whether some live binding in `mode` starts with `keys` and is longer.
    public func isPrefix(_ keys: [KeyChord], mode: String? = nil) -> Bool {
        let longer = Set(bindings.filter { $0.mode == mode && $0.keys.count > keys.count && Array($0.keys.prefix(keys.count)) == keys }.map(\.keys))
        return longer.contains { !candidates(for: $0, mode: mode).isEmpty }
    }

    /// What can follow `prefix`: each next key with the command it runs, or nil when it
    /// leads to a longer sequence. Sorted by key.
    public func continuations(of prefix: [KeyChord], mode: String? = nil) -> [(key: KeyChord, command: String?)] {
        var seen: [KeyChord: String?] = [:]
        for binding in bindings where binding.mode == mode && binding.keys.count > prefix.count && Array(binding.keys.prefix(prefix.count)) == prefix {
            let next = binding.keys[prefix.count]
            let sequence = prefix + [next]
            guard seen[next] == nil else { continue }
            if isPrefix(sequence, mode: mode) {
                seen[next] = .some(nil)
            } else if let command = candidates(for: sequence, mode: mode).first?.command {
                seen[next] = .some(command)
            }
        }
        return seen.map { (key: $0.key, command: $0.value) }.sorted { $0.key.description < $1.key.description }
    }

    /// Live key sequences that run `command`, formatted, at most `limit`: what menus and the
    /// palette show. Earlier `modes` first, then bindings that hold everywhere before those
    /// with a `when`, then shorter ones.
    public func keyLabels(for command: String, modes: [String?] = [nil], limit: Int = 2) -> [String] {
        var found: [(keys: [KeyChord], rank: [Int])] = []
        for (order, mode) in modes.enumerated() {
            for binding in bindings.reversed() where binding.mode == mode && binding.command == command && isLive(binding) {
                found.append((binding.keys, [order, binding.when == nil ? 0 : 1, binding.keys.count, found.count]))
            }
        }
        var seen: Set<String> = []
        return found.sorted { $0.rank.lexicographicallyPrecedes($1.rank) }
            .map { KeySequence.format($0.keys) }
            .filter { seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Whether `binding` can run: no binding that always applies takes its keys first.
    func isLive(_ binding: KeyBinding) -> Bool {
        for candidate in candidates(for: binding.keys, mode: binding.mode) {
            if candidate == binding { return true }
            if candidate.when == nil { return false }
        }
        return false
    }

    /// The first live binding of `command`, for showing its keys.
    public func keys(for command: String, mode: String? = nil) -> [KeyChord]? {
        bindings.reversed().first { $0.mode == mode && $0.command == command && candidates(for: $0.keys, mode: mode).contains($0) }?.keys
    }
}

/// Context names a binding's `when` can use.
public enum KeyContext {
    public static let names: Set<String> = ["heading", "table", "item", "region", "timestamp", "tblfm", "src"]

    public static func holds(_ name: String, in context: EditContext) -> Bool {
        switch name {
        case "heading": return headingOnLine(at: context.caret, in: context.tree) != nil
        case "table": return enclosing(.table, context) != nil
        case "item": return enclosing(.item, context) != nil
        case "region": return context.selection.contains { !$0.isEmpty }
        case "timestamp": return EmacsBuffer(context.text, point: context.caret).atTimestamp() != nil
        case "tblfm": return TableRecalculate.tblfmLine(in: context) != nil
        case "src": return enclosing(.block, context).map(DocumentModel.isSrcBlock) ?? false
        default: return false
        }
    }

    private static func enclosing(_ kind: SyntaxKind, _ context: EditContext) -> SyntaxNode? {
        var node = context.tree.root
        while let child = node.child(containing: context.caret) {
            if child.kind == kind { return child }
            node = child
        }
        return nil
    }
}

/// Turns key presses into bindings, holding a pending prefix between presses.
public struct KeyDispatcher: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// A prefix; waiting for the next key.
        case pending([KeyChord])
        /// Bindings for the completed sequence, highest priority first.
        case complete([KeyChord], [KeyBinding])
        /// A sequence of two or more keys that nothing binds.
        case undefined([KeyChord])
        /// A single key nothing binds: let the text system have it.
        case unbound
        /// C-g during a prefix.
        case cancelled
    }

    public var keymap: Keymap
    public var mode: String?
    public private(set) var pending: [KeyChord] = []

    public init(keymap: Keymap, mode: String? = nil) {
        self.keymap = keymap
        self.mode = mode
    }

    public static let quit = KeyChord("g", .control)

    public mutating func feed(_ chord: KeyChord) -> Outcome {
        if !pending.isEmpty, chord == Self.quit {
            pending = []
            return .cancelled
        }
        let sequence = pending + [chord]
        if keymap.isPrefix(sequence, mode: mode) {
            pending = sequence
            return .pending(sequence)
        }
        pending = []
        let candidates = keymap.candidates(for: sequence, mode: mode)
        if !candidates.isEmpty { return .complete(sequence, candidates) }
        return sequence.count == 1 ? .unbound : .undefined(sequence)
    }

    public mutating func reset() {
        pending = []
    }
}
