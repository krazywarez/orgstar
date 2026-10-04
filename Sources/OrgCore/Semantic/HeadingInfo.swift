import Foundation

public struct Property: Sendable, Equatable {
    public let key: String
    public let value: String
    /// `:KEY+:` appends to the value instead of replacing it.
    public let additive: Bool

    public init(key: String, value: String, additive: Bool = false) {
        self.key = key
        self.value = value
        self.additive = additive
    }

    /// A `:KEY: value` or `:KEY+: value` drawer line.
    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(":") else { return nil }
        let rest = trimmed.dropFirst()
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        var key = rest[..<colon]
        guard !key.isEmpty else { return nil }
        let additive = key.hasSuffix("+")
        if additive { key = key.dropLast() }
        let value = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        self.init(key: String(key), value: value, additive: additive)
    }
}

public struct Clock: Sendable, Equatable {
    public let start: Timestamp.Point
    /// Nil while the clock is running.
    public let end: Timestamp.Point?
    /// From `=> H:MM`, when present.
    public let minutes: Int?
}

/// One heading and the facts that belong to it directly, not to its children.
public struct HeadingInfo: Sendable, Equatable {
    public internal(set) var sectionRange: Range<Int>
    public internal(set) var headingRange: Range<Int>
    public internal(set) var level: Int
    /// Index of the parent heading in `DocumentModel.headings`.
    public internal(set) var parent: Int?
    public internal(set) var todo: String?
    public internal(set) var isDone: Bool
    /// The cookie's value (`A`, `10`), when the heading has one.
    public internal(set) var priority: String?
    /// The title as written, markup included.
    public internal(set) var title: String
    public internal(set) var localTags: [String]
    /// Property drawer lines in order.
    public internal(set) var properties: [Property]
    public internal(set) var scheduled: Timestamp?
    public internal(set) var deadline: Timestamp?
    public internal(set) var closed: Timestamp?
    public internal(set) var clocks: [Clock]
    /// Timestamps in the title and body, excluding planning and clock lines.
    public internal(set) var timestamps: [Timestamp]
    /// Link targets in the title and body.
    public internal(set) var links: [String]

    /// The heading's own `ID`. Never inherited.
    public var id: String? {
        properties.last { $0.key.uppercased() == "ID" && !$0.additive }?.value
    }
}
