import Foundation

/// A command's title in the app's language: its entry in the string catalog, keyed by the
/// English title (see Sources/OrgApp/CommandTitles.swift), or the title itself.
public enum CommandTitle {
    public static func localized(_ title: String) -> String {
        Bundle.main.localizedString(forKey: title, value: title, table: nil)
    }
}
