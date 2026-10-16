import Foundation
import Observation

/// The folders the agenda leaves out on this device, by root path: the ones hidden from the
/// agenda's folder menu and the ones the active Focus filter hides. A folder either hides is
/// hidden. Reminders stay on for both; the Focus filter mutes its folders' through the
/// system, by each notification's `filterCriteria`.
@MainActor
@Observable
public final class HiddenFolders {
    public static let shared = HiddenFolders()

    /// Hidden from the agenda's folder menu.
    public var manual: Set<String> { didSet { defaults.set(manual.sorted(), forKey: Self.manualKey) } }
    /// Hidden by the active Focus filter.
    public var focus: Set<String> { didSet { defaults.set(focus.sorted(), forKey: Self.focusKey) } }

    public var all: Set<String> { manual.union(focus) }

    static let manualKey = "agendaHiddenFolders"
    static let focusKey = "agendaFocusHiddenFolders"
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        manual = Set(defaults.stringArray(forKey: Self.manualKey) ?? [])
        focus = Set(defaults.stringArray(forKey: Self.focusKey) ?? [])
    }

    /// `path` is one of `folders` or inside one.
    public nonisolated static func hides(_ folders: Set<String>, path: String) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// For a Focus filter's app context: notifications whose `filterCriteria` (their folder) is
    /// not one of `folders`.
    public nonisolated static func notificationPredicate(hiding folders: Set<String>) -> NSPredicate {
        NSPredicate(format: "NOT (SELF IN %@)", folders.sorted())
    }
}
