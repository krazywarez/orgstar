import AppIntents
import AppKit
import OrgApp
import OrgCore

/// Shortcuts' "Capture to Orgstar": files text with a capture template without the capture
/// window. Prompts in the template take their defaults.
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to orgstar"
    static let description = IntentDescription("Files text with one of your capture templates.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Template Key", description: "A template's key in capture.toml; the first template when empty.")
    var template: String?

    /// The app's models, once its window is up.
    @MainActor static var environment: (workspace: WorkspaceModel, session: DocumentSession, clock: ClockModel, commands: AppCommands)?

    struct Failure: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Launched for the intent, the window sets the models up shortly.
        for _ in 0..<50 where Self.environment == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let (workspace, session, clock, commands) = Self.environment else { throw Failure(message: "orgstar isn't ready") }
        let placed = session.capture(
            text, templateKey: template, templates: CaptureTemplates.load().templates, workspace: workspace, clock: clock,
            clipboard: NSPasteboard.general.string(forType: .string) ?? "", userName: NSFullUserName()
        )
        switch placed {
        case .failure(let error):
            throw Failure(message: error.message)
        case .success(let chosen):
            let message = "Captured to \(CaptureView.target(chosen))"
            commands.show(message)
            return .result(value: message, dialog: "\(message)")
        }
    }
}

struct OrgstarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureIntent(), phrases: ["Capture to \(.applicationName)"], shortTitle: "Capture", systemImageName: "tray.and.arrow.down")
    }
}
