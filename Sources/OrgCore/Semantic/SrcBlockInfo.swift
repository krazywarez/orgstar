public struct SrcBlockInfo: Sendable, Equatable {
    public let range: Range<Int>
    public let heading: Int?
    /// From an attached `#+NAME:` line.
    public let name: String?
    public let language: String?
    /// Words like `-n` or `-r` between the language and the first header argument.
    public let switches: [String]
    /// The lines between the begin and end lines, unchanged.
    public let body: String
    /// Keys keep their leading colon (`:results`).
    public let headerArguments: [String: Resolved<String>]
}

public enum HeaderArguments {
    /// org-babel's global defaults.
    public static let defaults: [String: String] = [
        ":session": "none", ":results": "replace", ":exports": "code", ":cache": "no",
        ":noweb": "no", ":hlines": "no", ":tangle": "no",
    ]

    /// `:key value :other value two` as ordered pairs. Keys are lower-cased and keep their colon;
    /// words before the first key are dropped.
    public static func parse(_ text: some StringProtocol) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            if word.hasPrefix(":"), word.count > 1 {
                pairs.append((word.lowercased(), ""))
            } else if !pairs.isEmpty {
                let current = pairs[pairs.count - 1].value
                pairs[pairs.count - 1].value = current.isEmpty ? String(word) : current + " " + word
            }
        }
        return pairs
    }
}
