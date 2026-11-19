import Foundation

/// denote-sequence 0.3: a note's place in a hierarchy, kept as its Denote signature. Numeric
/// sequences (`1=1=2`), alphanumeric ones (`1a2`) and alphanumeric delimited ones (`1=a1b=2`),
/// each level one deeper. Ported as written, quirks included, so the sequences new notes get
/// are the ones Emacs gives.
public struct DenoteSequence: Sendable {
    public enum Scheme: String, Sendable, CaseIterable, Codable {
        case numeric, alphanumeric, alphanumericDelimited = "alphanumeric-delimited"
    }

    /// `denote-sequence-scheme`.
    public var scheme: Scheme

    public init(scheme: Scheme = .numeric) { self.scheme = scheme }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func isLetter(_ c: Character) -> Bool { c.isLetter }
    static func hasLetter(_ s: String) -> Bool { s.contains(where: isLetter) }
    static func allDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isASCIIDigit) }

    // MARK: - Schemes

    /// `denote-sequence-numeric-p`.
    public static func isNumeric(_ s: String) -> Bool {
        s.contains(where: \.isASCIIDigit) && !hasLetter(s) && !s.hasSuffix("=")
    }

    /// `denote-sequence-alphanumeric-p`.
    public static func isAlphanumeric(_ s: String) -> Bool {
        s.first?.isASCIIDigit == true && !s.contains("=")
    }

    /// The parts of an alphanumeric delimited sequence: runs of digits, runs of letters, `=`.
    static func delimitedParts(_ s: String) -> [String] {
        s.matches(of: /[0-9]+|\p{L}+|=/).map { String($0.0) }
    }

    /// `denote-sequence-alphanumeric-delimited-p`.
    public static func isAlphanumericDelimited(_ s: String) -> Bool {
        if allDigits(s) { return true }
        guard s.contains("="), !isNumeric(s) else { return false }
        let parts = delimitedParts(s)
        // Numbers and letters alternate.
        var last: Bool?
        for part in parts where part != "=" {
            let numeric = part.first!.isASCIIDigit
            if last == numeric { return false }
            last = numeric
        }
        // One level before the first `=`, then up to three a stretch, all but the last full.
        var levels: [Int] = [], depth = 0
        for part in parts {
            if part == "=" { levels.append(depth); depth = 0 } else { depth += 1 }
        }
        levels.append(depth)
        guard levels[0] == 1, levels.dropFirst().allSatisfy({ $0 <= 3 }) else { return false }
        if levels.count > 2 { return levels.dropFirst().dropLast().allSatisfy { $0 == 3 } }
        return true
    }

    /// `denote-sequence-p`.
    public static func isSequence(_ s: String) -> Bool { isNumeric(s) || isAlphanumeric(s) || isAlphanumericDelimited(s) }

    /// `denote-sequence-user-selected-scheme-p`.
    func isInScheme(_ s: String) -> Bool { has(s, scheme) }

    func has(_ s: String, _ scheme: Scheme) -> Bool {
        switch scheme {
        case .numeric: Self.isNumeric(s)
        case .alphanumeric: Self.isAlphanumeric(s)
        case .alphanumericDelimited: Self.isAlphanumericDelimited(s)
        }
    }

    static func isNumericPartial(_ s: String) -> Bool { s.contains(where: \.isASCIIDigit) && !s.contains(where: { $0.isLetter || $0.isPunctuation || $0.isSymbol }) }
    static func isAlphaPartial(_ s: String) -> Bool { hasLetter(s) && !s.contains(where: { $0.isASCIIDigit || $0.isPunctuation || $0.isSymbol }) }

    /// `denote-sequence-and-scheme-p`: the sequence's scheme.
    func schemeOf(_ s: String, partial: Bool = false) throws -> Scheme {
        if !partial, Self.allDigits(s) { return scheme }
        if !partial, !Self.hasLetter(s), scheme == .numeric { return .numeric }
        if partial ? Self.isAlphaPartial(s) : Self.isAlphanumeric(s) { return .alphanumeric }
        if partial ? Self.isNumericPartial(s) : Self.isNumeric(s) { return .numeric }
        if partial ? (Self.isNumericPartial(s) || Self.isAlphaPartial(s)) : Self.isAlphanumericDelimited(s) { return .alphanumericDelimited }
        throw Failure(description: "The sequence `\(s)' does not pass `denote-sequence-and-scheme-p'")
    }

    /// `denote-sequence-split`: a level of depth each.
    func split(_ s: String, partial: Bool = false) throws -> [String] {
        switch try schemeOf(s, partial: partial) {
        case .numeric:
            return s.split(separator: "=").map(String.init)
        case .alphanumeric, .alphanumericDelimited:
            let plain = s.replacingOccurrences(of: "=", with: "")
            var parts: [String] = []
            for match in plain.matches(of: /([0-9]+)(\p{L}+)?/) {
                parts.append(String(match.1))
                if let letters = match.2 { parts.append(String(letters)) }
            }
            return parts.isEmpty ? plain.map(String.init) : parts
        }
    }

    /// `denote-sequence-join`.
    static func join(_ parts: [String], _ scheme: Scheme) -> String {
        switch scheme {
        case .numeric: return parts.joined(separator: "=")
        case .alphanumeric: return parts.joined()
        case .alphanumericDelimited:
            var out = ""
            for (count, part) in parts.enumerated() {
                out += part
                if count % 3 == 0, count + 1 < parts.count { out += "=" }
            }
            return out
        }
    }

    public func depth(_ s: String) throws -> Int { try split(s).count }

    // MARK: - Counting

    /// `denote-sequence-increment-partial`.
    static func increment(_ s: String) throws -> String {
        if isNumericPartial(s) { return String((Int(s) ?? 0) + 1) }
        guard isAlphaPartial(s) else { throw Failure(description: "The string `\(s)' must contain only numbers or letters") }
        let letters = Array(s)
        if letters.count == 1 { return letters[0] == "z" ? "za" : String(UnicodeScalar(letters[0].unicodeScalars.first!.value + 1)!) }
        if letters.last == "z" { return s + "a" }
        return String(letters.dropLast()) + String(UnicodeScalar(letters.last!.unicodeScalars.first!.value + 1)!)
    }

    /// `denote-sequence-decrement-partial`; nil below the first.
    static func decrement(_ s: String) throws -> String? {
        if isNumericPartial(s) { let n = Int(s) ?? 0; return n == 1 ? nil : String(n - 1) }
        guard isAlphaPartial(s) else { throw Failure(description: "The string `\(s)' must contain only numbers or letters") }
        let letters = Array(s)
        if letters.count == 1 { return letters[0] == "a" ? nil : String(UnicodeScalar(letters[0].unicodeScalars.first!.value - 1)!) }
        if letters.last == "a" { return String(letters.dropLast()) }
        return String(letters.dropLast()) + String(UnicodeScalar(letters.last!.unicodeScalars.first!.value - 1)!)
    }

    /// `denote-sequence--alpha-to-number`.
    func alphaToNumber(_ s: String) throws -> String {
        let total = try split(s, partial: true).reduce(0) { sum, letter in
            let n = Int(letter.unicodeScalars.first!.value) - 96
            if n > 0, n <= 26 { return sum + n }
            let times = n / 26, mod = n % 26
            return sum + times * 26 + (mod > 0 ? mod + 96 : 0)
        }
        return String(total)
    }

    /// `denote-sequence--number-to-alpha`.
    static func numberToAlpha(_ s: String) -> String {
        let n = Int(s) ?? 0
        if n == 0 { return "a" }
        if n <= 26 { return String(UnicodeScalar(UInt8(n + 96))) }
        let times = n / 26, mod = n % 26
        return String(repeating: "z", count: times) + (mod > 0 ? String(UnicodeScalar(UInt8(mod + 96))) : "")
    }

    /// `denote-sequence-make-conversion` of a whole sequence to `target`.
    public func converted(_ s: String, to target: Scheme) throws -> String {
        if target == .numeric {
            if Self.isNumeric(s) { return s }
            return Self.join(try split(s).map { Self.isNumericPartial($0) ? $0 : try alphaToNumber($0) }, .numeric)
        }
        if Self.isAlphanumeric(s) { return s }
        let parts = try split(s).enumerated().map { index, part in
            index % 2 == 0 || Self.isAlphaPartial(part) ? part : Self.numberToAlpha(part)
        }
        return Self.join(parts, target)
    }

    // MARK: - Ordering

    /// `combine-and-quote-strings`' quoting of one string.
    static func quoted(_ s: String) -> String {
        guard s.contains(where: { $0 == "\"" || $0 == "\\" || $0 == " " || $0 == "\t" || $0 == "\n" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func padded(_ s: String, _ width: Int) -> String { s.count >= width ? s : String(repeating: " ", count: width - s.count) + s }

    enum Kind { case all, parent, sibling, child }

    /// `denote-sequence--pad`: the key sequences sort by.
    func pad(_ s: String, _ kind: Kind) throws -> String {
        let parts = try split(s)
        let list: [String]?, single: String?
        switch (kind, parts.count > 1) {
        case (.all, _): (list, single) = (parts, nil)
        case (.parent, true): (list, single) = (nil, parts[0])
        case (.sibling, true): (list, single) = (parts, nil)
        case (.child, true): (list, single) = (nil, parts.last!)
        default: (list, single) = (nil, s)
        }
        if let list { return list.map { Self.quoted(Self.padded($0, 5)) }.joined(separator: "=") }
        return Self.padded(single!, 32)
    }

    /// What `denote-sequence-sort-files` compares: the sequence with every level padded.
    public func sortKey(_ s: String) -> String { (try? pad(s, .all)) ?? s }

    /// `denote-sequence-sort-sequences`.
    public func sorted(_ sequences: [String]) -> [String] {
        stableSorted(sequences) { (try? pad($0, .all)) ?? $0 }
    }

    func stableSorted(_ items: [String], by key: (String) -> String) -> [String] {
        let keys = items.map(key)
        return items.indices.sorted { keys[$0] == keys[$1] ? $0 < $1 : keys[$0] < keys[$1] }.map { items[$0] }
    }

    func largestByOrder(_ sequences: [String], _ kind: Kind) -> String? {
        stableSorted(sequences) { (try? pad($0, kind)) ?? $0 }.last
    }

    /// `denote-sequence--get-largest`.
    func largest(_ sequences: [String], _ kind: Kind) -> String? {
        guard kind == .child else { return largestByOrder(sequences, kind) }
        func length(_ s: String) -> Int { scheme == .alphanumeric ? s.count : s.replacingOccurrences(of: "=", with: "").count }
        guard let longest = sequences.map(length).max() else { return nil }
        let tied = sequences.filter { length($0) == longest }
        return tied.count == 1 ? tied[0] : largestByOrder(tied, .child)
    }

    /// `denote-sequence--get-start`.
    func start(_ sequence: String? = nil) -> String {
        guard scheme != .numeric, let last = sequence?.last else { return "1" }
        return last.isLetter ? "1" : "a"
    }

    /// `denote-sequence--sequence-prefix-p`.
    func hasPrefix(_ prefix: [String], _ sequence: String) -> Bool {
        guard isInScheme(sequence), let parts = try? split(sequence) else { return false }
        return parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    func withPrefix(_ sequence: String, _ sequences: [String]) -> [String] {
        guard !sequence.isEmpty, let prefix = try? split(sequence) else { return [] }
        return sequences.filter { hasPrefix(prefix, $0) }
    }

    /// `denote-sequence-get-all-sequences-with-max-depth`: each cut to `depth` levels.
    func withMaxDepth(_ depth: Int, _ sequences: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in sequences {
            guard let parts = try? split(s), parts.count <= depth else { continue }
            let joined = Self.join(Array(parts.prefix(depth)), scheme)
            if seen.insert(joined).inserted { out.append(joined) }
        }
        return out
    }

    // MARK: - New sequences

    /// `denote-sequence-get-new` for `parent`: one after the largest first level.
    public func newParent(among sequences: [String]) throws -> String {
        guard let top = largest(sequences, .parent) else { return start() }
        return String((Int(try split(top)[0]) ?? 0) + 1)
    }

    /// `denote-sequence-get-new` for `child` of `sequence`.
    public func newChild(of sequence: String, among sequences: [String]) throws -> String {
        let depth = try self.depth(sequence) + 1
        let unfiltered = withPrefix(sequence, sequences)
        guard !unfiltered.isEmpty else { throw Failure(description: "Cannot find sequences given sequence `\(sequence)' using scheme `\(scheme.rawValue)'") }
        let first = Self.join(try split(sequence) + [start(sequence)], scheme)
        guard unfiltered.count > 1 else { return first }
        let cut = withMaxDepth(depth, unfiltered)
        guard let largest = largest((cut.isEmpty ? unfiltered : cut).filter(isInScheme), .child) else { return first }
        guard try self.depth(largest) > 1 else { return Self.join(try split(largest) + [start(sequence)], scheme) }
        var parts = try split(largest)
        let last = parts.removeLast()
        return Self.join(parts + [try Self.increment(last)], try schemeOf(largest))
    }

    /// `denote-sequence-get-new` for `sibling` of `sequence`.
    public func newSibling(of sequence: String, among sequences: [String]) throws -> String {
        let parts = try split(sequence)
        let nested = parts.count > 1
        let unfiltered = nested ? withPrefix(Self.join(Array(parts.dropLast()), try schemeOf(sequence)), sequences) : sequences
        let all = withMaxDepth(parts.count, unfiltered).filter(isInScheme)
        guard all.contains(sequence), let largest = largest(all, nested ? .sibling : .parent) else {
            throw Failure(description: "Cannot find sequences given sequence `\(sequence)' using scheme `\(scheme.rawValue)'")
        }
        guard nested else { return String((Int(largest) ?? 0) + 1) }
        var largestParts = try split(largest)
        let last = largestParts.removeLast()
        return Self.join(largestParts + [try Self.increment(last)], try schemeOf(largest))
    }

    /// `denote-sequence--infer-sibling`: the sequence one before or after, existing or not.
    public func neighbor(of sequence: String, next: Bool) throws -> String? {
        var parts = try split(sequence)
        let last = parts.removeLast()
        guard let changed = next ? try Self.increment(last) : try Self.decrement(last) else { return nil }
        return Self.join(parts + [changed], try schemeOf(sequence))
    }

    // MARK: - Relatives

    public enum Relation: String, Sendable, CaseIterable {
        case allParents = "all-parents", parent, siblings, children, allChildren = "all-children"
    }

    /// `denote-sequence-get-relative` among `files` (path and sequence), in their order.
    public func relatives(of sequence: String, _ relation: Relation, in files: [(path: String, sequence: String)]) throws -> [String] {
        let depth = try self.depth(sequence), sequenceScheme = try schemeOf(sequence)
        let parts = try split(sequence)
        func common(_ compare: (Int, Int) -> Bool, _ prefix: String) -> [(path: String, sequence: String)] {
            let pool = prefix.isEmpty ? files : (try? split(prefix)).map { prefix in files.filter { hasPrefix(prefix, $0.sequence) } } ?? []
            return pool.filter { compare((try? self.depth($0.sequence)) ?? 0, depth) }
        }
        switch relation {
        case .allParents:
            var likely = Set<String>(), cut = Array(parts.dropLast())
            while !cut.isEmpty { likely.insert(Self.join(cut, sequenceScheme)); cut.removeLast() }
            return files.filter { likely.contains($0.sequence) }.map(\.path)
        case .parent:
            let parent = Self.join(Array(parts.dropLast()), sequenceScheme)
            return files.first { $0.sequence == parent }.map { [$0.path] } ?? []
        case .siblings:
            let siblings = common(==, Self.join(Array(parts.dropLast()), sequenceScheme))
            guard let current = Self.path(of: sequence, in: files) else { return [] }
            return siblings.map(\.path).filter { $0 != current }
        case .allChildren:
            return common(>, sequence).map(\.path)
        case .children:
            return common(>, sequence).filter { (try? self.depth($0.sequence)) == depth + 1 }.map(\.path)
        }
    }

    /// `denote-sequence-get-path`: the file with `sequence`, an Org one when there are several.
    public static func path(of sequence: String, in files: [(path: String, sequence: String)]) -> String? {
        let matches = files.filter { $0.sequence == sequence }.map(\.path)
        return matches.count < 2 ? matches.first : matches.first { ($0 as NSString).pathExtension == "org" } ?? matches.first
    }

    /// The files with sequences among `paths`: their signatures that are sequences.
    public static func files(_ paths: [String]) -> [(path: String, sequence: String)] {
        paths.compactMap { path in
            guard let signature = Denote.name(ofFile: path).signature, isSequence(signature) else { return nil }
            return (path, signature)
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
