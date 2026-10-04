/// App-wide settings that change what a document means without changing how it parses.
public struct SemanticSettings: Sendable, Equatable {
    public enum PropertyInheritance: Sendable, Equatable {
        /// org's default: properties apply only to their own heading.
        case none
        case all
        /// Upper-cased property keys that inherit.
        case only(Set<String>)
    }

    public var tagInheritance: Bool
    public var tagsExcludedFromInheritance: Set<String>
    public var propertyInheritance: PropertyInheritance

    public init(
        tagInheritance: Bool = true,
        tagsExcludedFromInheritance: Set<String> = [],
        propertyInheritance: PropertyInheritance = .none
    ) {
        self.tagInheritance = tagInheritance
        self.tagsExcludedFromInheritance = tagsExcludedFromInheritance
        self.propertyInheritance = propertyInheritance
    }

    public static let `default` = SemanticSettings()
}

/// Where a resolved value came from.
public enum ValueSource: Sendable, Equatable {
    case defaults
    /// A file-level keyword such as `#+FILETAGS` or `#+PROPERTY`.
    case file
    /// A heading, by index into `DocumentModel.headings`.
    case heading(Int)
    /// The element itself: a `#+HEADER` line or a block's begin line.
    case element
}

public struct Resolved<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let source: ValueSource

    public init(_ value: Value, _ source: ValueSource) {
        self.value = value
        self.source = source
    }
}
