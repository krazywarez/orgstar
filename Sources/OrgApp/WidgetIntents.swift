#if os(iOS)
import AppIntents
import Foundation

/// A capture template, chosen in a widget's or control's settings from the list the app wrote.
public struct CaptureTemplateEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Template"
    public static let defaultQuery = Query()

    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    public struct Query: EntityQuery {
        public init() {}

        private var all: [CaptureTemplateEntity] {
            (TemplateList.read()?.templates ?? []).map { CaptureTemplateEntity(id: $0.key, name: $0.name) }
        }

        public func entities(for identifiers: [String]) async throws -> [CaptureTemplateEntity] {
            all.filter { identifiers.contains($0.id) }
        }

        public func suggestedEntities() async throws -> [CaptureTemplateEntity] { all }
    }
}

/// Opens the capture sheet, with a template or the first one.
public struct OpenCaptureIntent: AppIntent {
    public static let title: LocalizedStringResource = "Capture"
    public static let description = IntentDescription("Opens orgstar's capture sheet.")
    public static let openAppWhenRun = true

    @Parameter(title: "Template")
    public var template: CaptureTemplateEntity?

    /// Shows the capture sheet; set by the app at launch.
    @MainActor public static var handler: (@MainActor @Sendable (String?) -> Void)?

    public init() {}

    public init(template: CaptureTemplateEntity?) {
        self.template = template
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        Self.handler?(template?.id)
        return .result()
    }
}

/// The clock control: off clocks out, on clocks in to the entry clocked last
/// (`org-clock-in-last`). It runs in the app's process.
public struct ClockToggleIntent: SetValueIntent, LiveActivityIntent {
    public static let title: LocalizedStringResource = "Clock In or Out"
    public static let description = IntentDescription("Clocks out of the running clock, or in to the entry clocked last.")
    public static let isDiscoverable = false

    @Parameter(title: "Clocked In")
    public var value: Bool

    /// Clocks in (true) or out (false); set by the app at launch.
    @MainActor public static var handler: (@MainActor @Sendable (Bool) async -> Void)?

    public init() {}

    public func perform() async throws -> some IntentResult {
        let handler = await MainActor.run { Self.handler }
        await handler?(value)
        return .result()
    }
}

/// The capture control's settings.
public struct CaptureControlConfiguration: ControlConfigurationIntent {
    public static let title: LocalizedStringResource = "Capture"
    public static let description = IntentDescription("The template to capture with.")

    @Parameter(title: "Template")
    public var template: CaptureTemplateEntity?

    public init() {}
}

/// The Lock Screen capture widget's settings.
public struct CaptureWidgetConfiguration: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Capture"
    public static let description = IntentDescription("The template to capture with.")

    @Parameter(title: "Template")
    public var template: CaptureTemplateEntity?

    public init() {}
}
#endif
