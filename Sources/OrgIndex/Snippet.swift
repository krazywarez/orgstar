import Foundation

/// A short passage around the first word a search matched, on one line, with the matched words
/// marked: what a search result shows under its title.
public struct Snippet: Sendable, Hashable {
    public let text: String
    /// The matched words, as UTF-16 ranges of `text`.
    public let matches: [Range<Int>]

    /// The passage of `text` around the first word starting with one of `prefixes`, compared
    /// without case or diacritics as the full-text index compares them; nil when none does.
    public init?(text: String, prefixes: [String], width: Int = 160) {
        let folded = prefixes.map(Self.fold).filter { !$0.isEmpty }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ") as NSString
        guard !folded.isEmpty, line.length > 0 else { return nil }
        var words: [(range: NSRange, matches: Bool)] = []
        let pattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
        for match in pattern.matches(in: line as String, range: NSRange(location: 0, length: line.length)) {
            let word = Self.fold(line.substring(with: match.range))
            words.append((match.range, folded.contains { word.hasPrefix($0) }))
        }
        guard let first = words.first(where: \.matches) else { return nil }
        // Start a few words before the match, at a word's start; end at the last whole word.
        var start = max(0, first.range.location - 50)
        if start > 0 { start = words.first { $0.range.location >= start }?.range.location ?? first.range.location }
        var end = min(line.length, start + width)
        if end < line.length { end = words.last { NSMaxRange($0.range) <= end }.map { NSMaxRange($0.range) } ?? end }
        let lead = start > 0 ? "…" : ""
        self.text = lead + line.substring(with: NSRange(location: start, length: end - start)) + (end < line.length ? "…" : "")
        let shift = lead.utf16.count - start
        matches = words.filter { $0.matches && $0.range.location >= start && NSMaxRange($0.range) <= end }
            .map { ($0.range.location + shift)..<(NSMaxRange($0.range) + shift) }
    }

    static func fold(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// `text` with the matched words strongly emphasized, for a SwiftUI `Text`.
    public var attributed: AttributedString {
        var result = AttributedString(text)
        let utf16 = text.utf16
        for match in matches {
            let lower = String.Index(utf16.index(utf16.startIndex, offsetBy: match.lowerBound), within: text)
            let upper = String.Index(utf16.index(utf16.startIndex, offsetBy: match.upperBound), within: text)
            guard let lower, let upper, let range = Range(lower..<upper, in: result) else { continue }
            result[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}
