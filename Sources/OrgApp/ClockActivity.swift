#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// The running clock's Live Activity, which the app starts and the widget extension draws.
public struct ClockActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var heading: String
        public var startedAt: Date

        public init(heading: String, startedAt: Date) {
            self.heading = heading
            self.startedAt = startedAt
        }
    }

    /// The clock's file and the stamp in its `CLOCK: [start]` line, which name the clock.
    public var path: String
    public var start: String

    public init(path: String, start: String) {
        self.path = path
        self.start = start
    }
}

/// The Live Activity's Clock Out button. It runs in the app's process, which sets `handler`.
public struct ClockOutIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Clock Out"
    public static let description = IntentDescription("Stops the running clock.")
    public static let isDiscoverable = false

    /// Clocks out; set by the app at launch.
    @MainActor public static var handler: (@MainActor @Sendable () async -> Void)?

    public init() {}

    public func perform() async throws -> some IntentResult {
        let handler = await MainActor.run { Self.handler }
        await handler?()
        return .result()
    }
}

/// OrgApp's App Intents, for the app and the widget extension to include.
public struct OrgAppIntents: AppIntentsPackage {}
#endif
