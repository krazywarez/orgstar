#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI
import UserNotifications

/// Orgstar on iPhone and iPad: the agenda, capture, and the folders they read.
@main
struct OrgstarMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = MobileModel()

    var body: some Scene {
        WindowGroup {
            if let workspace = model.workspace, let agenda = model.agenda {
                RootView(model: model, workspace: workspace, agenda: agenda)
            } else {
                ContentUnavailableView("Can't open the index", systemImage: "exclamationmark.triangle", description: Text(model.failure ?? ""))
            }
        }
    }
}

/// Reminders show while the app is open too.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// An org-protocol capture, or a plain one.
struct CaptureRequest: Identifiable {
    let id = UUID()
    var template: String?
    var properties: [String: String] = [:]
}

struct RootView: View {
    let model: MobileModel
    let workspace: WorkspaceModel
    let agenda: AgendaModel
    @State private var capture: CaptureRequest?
    @State private var hour = 0
    @Environment(\.scenePhase) private var scenePhase

    private var session: DocumentSession { model.session }

    private struct ReminderKey: Equatable {
        var files: Int
        var changed: Int?
        var edits: Int
        var settings: Int
        var active: Bool
        var hour: Int
    }

    var body: some View {
        TabView {
            Tab("Agenda", systemImage: "calendar") {
                NavigationStack {
                    AgendaScreen(workspace: workspace, session: session, agenda: agenda, scheduler: model.scheduler)
                        .toolbar { captureButton }
                }
            }
            Tab("Folders", systemImage: "folder") {
                NavigationStack {
                    FoldersScreen(workspace: workspace)
                        .toolbar { captureButton }
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsScreen(model: model) }
            }
        }
        .sheet(item: $capture) { request in
            CaptureScreen(workspace: workspace, session: session, request: request)
        }
        .task {
            // Development: `ORGSTAR_ROOT` adds a folder at launch, as on the Mac.
            if let root = ProcessInfo.processInfo.environment["ORGSTAR_ROOT"] { try? await workspace.addRoot(URL(fileURLWithPath: root)) }
            workspace.startWatching()
            await workspace.refresh()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                hour += 1
            }
        }
        // Reminders follow the files, the settings, coming back to the app and the hour.
        .task(id: ReminderKey(files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion,
                              settings: model.settingsVersion, active: scenePhase == .active, hour: hour)) {
            guard scenePhase == .active else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await model.updateReminders()
        }
        .onChange(of: scenePhase) { _, phase in
            // Files and settings synced while away; not every sync tool tells file presenters.
            guard phase == .active else { return }
            model.reloadConfig()
            Task { await workspace.refresh() }
        }
        .onOpenURL { url in
            if case .capture(let template, let properties)? = OrgProtocol.parse(url.absoluteString) {
                capture = CaptureRequest(template: template, properties: properties)
            }
        }
    }

    private var captureButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Capture", systemImage: "square.and.pencil") { capture = CaptureRequest() }
        }
    }
}
#else
/// The iOS app has nothing to run elsewhere.
@main
enum OrgstarMobileUnavailable {
    static func main() { print("Orgstar for iOS runs on iPhone and iPad.") }
}
#endif
