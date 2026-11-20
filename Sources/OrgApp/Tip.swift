/// One-time consumable tips on iOS. They unlock nothing.
public enum Tip: String, CaseIterable, Sendable {
    case small, medium, large

    /// The App Store product identifier.
    public var productID: String { "sh.krz.orgstar.tip.\(rawValue)" }

    /// Identifiers in the order the tips are listed.
    public static let productIDs = allCases.map(\.productID)
}
