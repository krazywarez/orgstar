/// The app icons `scripts/make-icon.swift` draws, by id, in its order.
public enum AppIcons {
    public static let ids = [
        "default", "midnight", "paper", "org", "sunset", "forest", "mono", "rainbow", "outline", "terminal",
        "unicorn", "unicorn-night", "unicorn-pastel",
    ]

    private static func words(_ id: String) -> [String] { id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() } }

    public static func name(_ id: String) -> String { words(id).joined(separator: " ") }

    /// The iOS alternate icon's name; nil for the primary icon.
    public static func alternateName(_ id: String) -> String? {
        id == "default" ? nil : "AppIcon-" + words(id).joined()
    }

    public static func id(alternateName: String?) -> String {
        ids.first { self.alternateName($0) == alternateName && alternateName != nil } ?? "default"
    }
}
