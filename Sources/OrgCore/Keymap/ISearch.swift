import Foundation

/// Incremental search (isearch.el, Emacs 31.1) with its defaults: `isearch-lax-whitespace`
/// with `search-whitespace-regexp` `[ \t]+`, `search-upper-case` `not-yanks` (an upper-case
/// letter makes the search case-sensitive) and `isearch-wrap-pause` `t`. The editor feeds it
/// keys; it says where point and the match are and what the echo area shows.
public struct ISearch: Sendable, Equatable {
    public struct State: Sendable, Equatable {
        public var string: String
        public var forward: Bool
        /// Point: the match's end going forward, its start going back.
        public var point: Int
        public var match: Range<Int>?
        public var failing: Bool
        public var wrapped: Bool
        /// Wrapped and gone past where the search began.
        public var overwrapped: Bool
    }

    /// Where the search began, to go back to on C-g.
    public let origin: Int
    public private(set) var state: State
    /// The states before, for DEL (`isearch-cmds`).
    private var history: [State] = []
    /// What a repeat with nothing typed searches for: the previous search.
    public let previous: String?
    /// `isearch-forward-regexp`: the string is an ICU regular expression.
    public let regexp: Bool
    /// `isearch-barrier`: a backward match may not end past it; where the search began, or
    /// where it last changed direction.
    private var barrier: Int

    public init(origin: Int, forward: Bool, previous: String? = nil, regexp: Bool = false) {
        self.origin = origin
        self.previous = previous
        self.regexp = regexp
        barrier = origin
        state = State(string: "", forward: forward, point: origin, match: nil, failing: false, wrapped: false, overwrapped: false)
    }

    public var string: String { state.string }
    public var point: Int { state.point }
    public var match: Range<Int>? { state.failing ? nil : state.match }

    /// `isearch-message-prefix`.
    public var message: String {
        var prefix = ""
        if state.failing { prefix += "Failing " }
        if state.overwrapped { prefix += "overwrapped " } else if state.wrapped { prefix += "wrapped " }
        prefix += regexp ? "regexp I-search" : "I-search"
        if !state.forward { prefix += " backward" }
        prefix = prefix.prefix(1).uppercased() + prefix.dropFirst()
        return prefix + ": " + state.string
    }

    /// The search string as a regular expression: spaces match runs of spaces and tabs; with
    /// `regexp`, as it is. An invalid one is nil, and fails.
    public static func pattern(_ string: String, regexp: Bool = false) -> NSRegularExpression? {
        if regexp { return try? NSRegularExpression(pattern: string, options: string.contains { $0.isUppercase } ? [] : [.caseInsensitive]) }
        let parts = string.split(separator: " ", omittingEmptySubsequences: false).map { NSRegularExpression.escapedPattern(for: String($0)) }
        let caseSensitive = string.contains { $0.isUppercase }
        return try? NSRegularExpression(pattern: parts.joined(separator: "[ \\t]+"), options: caseSensitive ? [] : [.caseInsensitive])
    }

    /// The first match starting at or after `from` going forward; going back, the last one
    /// ending at or before `from`.
    static func find(_ string: String, in text: String, from: Int, forward: Bool, regexp: Bool = false) -> Range<Int>? {
        guard !string.isEmpty, let regex = pattern(string, regexp: regexp) else { return nil }
        let length = (text as NSString).length
        if forward {
            guard from <= length, let m = regex.firstMatch(in: text, range: NSRange(location: from, length: length - from)) else { return nil }
            return m.range.location..<NSMaxRange(m.range)
        }
        // `re-search-backward`: the match starting nearest before `from`, ending by it.
        var start = min(from, length)
        while start >= 0 {
            if let m = regex.firstMatch(in: text, options: .anchored, range: NSRange(location: start, length: min(from, length) - start)), m.range.length > 0 {
                return m.range.location..<NSMaxRange(m.range)
            }
            start -= 1
        }
        return nil
    }

    private mutating func found(_ range: Range<Int>?) {
        if let range {
            state.match = range
            state.point = state.forward ? range.upperBound : range.lowerBound
            state.failing = false
            if state.wrapped, state.forward ? range.lowerBound >= origin : range.upperBound <= origin { state.overwrapped = true }
        } else {
            state.failing = true
        }
    }

    /// A character typed: the search goes on with it, from the current match's start (its end
    /// going back), so the match grows in place when it can.
    public mutating func add(_ characters: String, in text: String) {
        history.append(state)
        state.string += characters
        if state.failing { return }
        if state.forward {
            found(Self.find(state.string, in: text, from: state.match?.lowerBound ?? state.point, forward: true, regexp: regexp))
        } else {
            // `looking-at` at point first, as long as the match ends by the origin; otherwise
            // back from just past the current match's end.
            let start = state.point
            let limit = min(origin, barrier)
            if let regex = Self.pattern(state.string, regexp: regexp), start <= (text as NSString).length,
               let m = regex.firstMatch(in: text, options: .anchored, range: NSRange(location: start, length: (text as NSString).length - start)), m.range.length > 0,
               NSMaxRange(m.range) <= limit {
                found(m.range.location..<NSMaxRange(m.range))
            } else {
                let from = state.match.map { min(limit, $0.upperBound + 1) } ?? state.point
                found(Self.find(state.string, in: text, from: from, forward: false, regexp: regexp))
            }
        }
    }

    /// C-s and C-r (`isearch-repeat`): the next match, the previous search when nothing is
    /// typed yet, the other end of the match when the direction changes, and the other end of
    /// the buffer after a failing search.
    public mutating func again(forward: Bool, in text: String) {
        history.append(state)
        if state.string.isEmpty {
            state.forward = forward
            guard let previous, !previous.isEmpty else { return }
            state.string = previous
            found(Self.find(previous, in: text, from: state.point, forward: forward, regexp: regexp))
            return
        }
        if forward != state.forward {
            state.forward = forward
            barrier = state.point
            guard let match = state.match else { return }
            found(Self.find(state.string, in: text, from: forward ? match.lowerBound : match.upperBound, forward: forward, regexp: regexp))
            return
        }
        if state.failing {
            state.wrapped = true
            found(Self.find(state.string, in: text, from: forward ? 0 : (text as NSString).length, forward: forward, regexp: regexp))
            return
        }
        let from = state.point
        var next = Self.find(state.string, in: text, from: from, forward: forward, regexp: regexp)
        // An empty match at point would find itself again.
        if let range = next, range.isEmpty { next = Self.find(state.string, in: text, from: forward ? from + 1 : from - 1, forward: forward, regexp: regexp) }
        if next == nil {
            state.failing = true
        } else {
            found(next)
        }
    }

    /// DEL (`isearch-delete-char`): back to the state before the last key.
    public mutating func delete() {
        guard let last = history.popLast() else { return }
        state = last
    }

    /// C-g (`isearch-abort`): with a failing search, the part that fails comes off and the
    /// search goes on (true); otherwise the search is over, point back where it began (false).
    public mutating func abort() -> Bool {
        guard state.failing else { return false }
        while state.failing, let last = history.popLast() { state = last }
        return true
    }
}
