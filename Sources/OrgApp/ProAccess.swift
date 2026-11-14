import Foundation
import Observation

/// Features that need orgstar Pro.
public enum ProFeature: String, CaseIterable, Sendable, Identifiable {
    case babel, export, encryption, roam
    case widgets, watch, liveActivity, calendar, shortcuts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .babel: "Run and tangle source blocks"
        case .export: "PDF, Word and other export, and publishing"
        case .encryption: "Encrypted entries"
        case .roam: "Org-roam nodes and backlinks"
        case .widgets: "Widgets"
        case .watch: "Apple Watch app"
        case .liveActivity: "Clock Live Activity"
        case .calendar: "Calendar and Reminders"
        case .shortcuts: "Shortcuts actions"
        }
    }

    public var systemImage: String {
        switch self {
        case .babel: "play.rectangle"
        case .export: "square.and.arrow.up"
        case .encryption: "lock"
        case .roam: "point.3.connected.trianglepath.dotted"
        case .widgets: "square.grid.2x2"
        case .watch: "applewatch"
        case .liveActivity: "timer"
        case .calendar: "calendar"
        case .shortcuts: "square.stack.3d.up"
        }
    }
}

extension ProFeature {
    /// Export formats that stay free.
    static let freeExports: Set<String> = ["html", "html-open", "markdown"]

    /// The feature an export format needs, if any.
    public static func required(byExport format: String) -> ProFeature? {
        freeExports.contains(format) ? nil : .export
    }

    /// The feature an app command (`app.…`, from a key, menu or the palette) needs, if any.
    /// Decrypting stays free so no one is locked out of their own text.
    public static func required(byCommand id: String) -> ProFeature? {
        switch id {
        case "app.copy-rich-text": .export
        case let id where id.hasPrefix("app.export."): required(byExport: String(id.dropFirst("app.export.".count)))
        case let id where id.hasPrefix("app.publish"): .export
        case "app.crypt.encrypt-entry", "app.crypt.encrypt-entries": .encryption
        case let id where id.hasPrefix("app.dailies.") || id.hasPrefix("app.node."): .roam
        case "app.toggle-backlinks", "app.backlinks": .roam
        default: nil
        }
    }
}

/// Why Pro is unlocked.
public enum ProGrant: String, Codable, Sendable {
    /// Installed before Pro existed.
    case grandfathered
    /// An App Store purchase or subscription.
    case purchase
    /// A Mac license key.
    case license
}

/// Whether Pro is unlocked. The app writes it; the app group's defaults carry it to the widgets,
/// share extension and intents, which only read it.
@MainActor @Observable
public final class ProAccess {
    public static let shared = ProAccess(defaults: ProAccess.groupDefaults)

    nonisolated static let grantKey = "pro.grant"

    /// The app group's defaults, or the standard ones when the app isn't in the group (the Mac app).
    public nonisolated static var groupDefaults: UserDefaults {
        UserDefaults(suiteName: CaptureInbox.group) ?? .standard
    }

    /// For code outside the main actor (widgets, intents): reads the stored grant.
    public nonisolated static var isUnlockedNow: Bool {
        groupDefaults.string(forKey: grantKey).flatMap(ProGrant.init(rawValue:)) != nil
    }

    private let defaults: UserDefaults
    public private(set) var grant: ProGrant?
    /// The feature whose paywall should show, if any.
    public var paywall: ProFeature?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        grant = defaults.string(forKey: Self.grantKey).flatMap(ProGrant.init(rawValue:))
    }

    public var isUnlocked: Bool { grant != nil }

    public func set(_ grant: ProGrant?) {
        self.grant = grant
        defaults.set(grant?.rawValue, forKey: Self.grantKey)
    }

    /// True when `feature` may be used; otherwise shows its paywall and returns false.
    @discardableResult
    public func allows(_ feature: ProFeature) -> Bool {
        if isUnlocked { return true }
        paywall = feature
        return false
    }
}

/// Who installed before Pro and keeps it free.
public enum Grandfathering {
    /// The first iOS build (`CFBundleVersion`, the commit count) that sells Pro: one more than
    /// main's count before Pro merged. An App Store `originalAppVersion` below it means the app was
    /// first downloaded while it was free.
    public static let firstPaidIOSBuild = 569

    /// Whether an App Store original build number predates Pro.
    public static func predatesPro(originalBuild: String, firstPaidBuild: Int = firstPaidIOSBuild) -> Bool {
        guard let build = Int(originalBuild.trimmingCharacters(in: .whitespaces)) else { return false }
        return build < firstPaidBuild
    }

    static let macDecidedKey = "pro.macGrandfatherDecided"

    /// Decides once, on the first launch of a Pro build of the Mac app, whether this Mac ran an
    /// earlier free version: Sparkle marks its first launch, and `marker` (the workspace's list of
    /// folders) exists once folders were added. Later launches return the first answer.
    public static func macPredatesPro(defaults: UserDefaults = .standard, marker: URL?) -> Bool {
        if let decided = defaults.object(forKey: macDecidedKey) as? Bool { return decided }
        let ranBefore = defaults.object(forKey: "SUHasLaunchedBefore") != nil
            || marker.map { FileManager.default.fileExists(atPath: $0.path) } == true
        defaults.set(ranBefore, forKey: macDecidedKey)
        return ranBefore
    }
}
