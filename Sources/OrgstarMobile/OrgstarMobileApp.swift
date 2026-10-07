#if os(iOS)
import CoreSpotlight
import OrgApp
import OrgCore
import SwiftUI
import UserNotifications

/// Orgstar on iPhone and iPad: the agenda, capture, and the folders they read.
@main
struct OrgstarMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = MobileModel.shared

    var body: some Scene {
        WindowGroup {
            if let workspace = model.workspace, let agenda = model.agenda {
                RootView(model: model, workspace: workspace, agenda: agenda)
                    .environment(model)
                    .environment(model.clock)
                    .onAppear { delegate.model = model }
            } else {
                ContentUnavailableView("Can't open the index", systemImage: "exclamationmark.triangle", description: Text(model.failure ?? ""))
            }
        }
    }
}

/// Reminders show while the app is open too, and open their entry when tapped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var model: MobileModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let path = info["path"] as? String, let offset = info["offset"] as? Int else { return }
        await MainActor.run { model?.openRequest = .offset(path, offset) }
    }
}

enum AppTab: Hashable { case agenda, folders, settings, search }

extension View {
    /// Readers pushed for `ReaderRoute`s.
    func readerDestination(workspace: WorkspaceModel, session: DocumentSession) -> some View {
        navigationDestination(for: ReaderRoute.self) { route in
            ReaderScreen(route: route, workspace: workspace, session: session)
        }
        .navigationDestination(for: EditorRoute.self) { route in
            EditorScreen(path: route.path, offset: route.offset, workspace: workspace, session: session)
        }
    }
}

/// An org-protocol capture, or a plain one.
struct CaptureRequest: Identifiable {
    let id = UUID()
    var template: String?
    var properties: [String: String] = [:]
}

extension CaptureRequest {
    /// An `org-protocol://capture` link's request.
    init?(link: String) {
        guard case .capture(let template, let properties)? = OrgProtocol.parse(link) else { return nil }
        self.init(template: template, properties: properties)
    }
}

struct RootView: View {
    let model: MobileModel
    let workspace: WorkspaceModel
    let agenda: AgendaModel
    @State private var capture: CaptureRequest?
    /// Captures from the share extension after the one showing.
    @State private var waiting: [CaptureRequest] = []
    @State private var tab = AppTab.agenda
    @State private var agendaPath = NavigationPath()
    @State private var hour = 0
    @State private var showingClockReport = false
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase

    private var session: DocumentSession { model.session }

    private struct SpotlightKey: Equatable {
        var files: Int
        var changed: Int?
        var saved: Int
    }

    private struct ReminderKey: Equatable {
        var files: Int
        var changed: Int?
        var edits: Int
        var settings: Int
        var active: Bool
        var hour: Int
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Agenda", systemImage: "calendar", value: .agenda) {
                NavigationStack(path: $agendaPath) {
                    AgendaScreen(workspace: workspace, session: session, agenda: agenda, scheduler: model.scheduler)
                        .toolbar { captureButton }
                        .readerDestination(workspace: workspace, session: session)
                }
            }
            Tab("Folders", systemImage: "folder", value: .folders) {
                NavigationStack {
                    FoldersScreen(workspace: workspace)
                        .toolbar { captureButton }
                        .readerDestination(workspace: workspace, session: session)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack { SettingsScreen(model: model) }
            }
            Tab(value: .search, role: .search) {
                NavigationStack {
                    SearchScreen(workspace: workspace, session: session)
                        .readerDestination(workspace: workspace, session: session)
                }
            }
        }
        .clockAccessory(model.clock.running, perform: clock)
        .overlay(alignment: .top) {
            if let message {
                Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
                    .onTapGesture { self.message = nil }
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        if self.message == message { self.message = nil }
                    }
            }
        }
        .sheet(isPresented: $showingClockReport) { ClockReportScreen(workspace: workspace) }
        .onChange(of: model.openRequest) {
            guard let route = model.openRequest else { return }
            model.openRequest = nil
            tab = .agenda
            agendaPath.append(route)
        }
        .onChange(of: workspace.changedFile?.version) {
            // An open file takes in what changed on disk.
            if let path = workspace.changedFile?.path { session.fileChanged(path) }
        }
        .sheet(item: $capture, onDismiss: showWaiting) { request in
            CaptureScreen(workspace: workspace, session: session, request: request)
        }
        .task {
            takeShared()
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
        // Spotlight follows the files and saved edits.
        .task(id: SpotlightKey(files: workspace.files.count, changed: workspace.changedFile?.version, saved: session.dirtyPaths.count)) {
            await model.spotlight.update(workspace.files)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let path = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { model.openRequest = .file(path) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Unsaved edits are written before the app may be stopped.
            if phase == .background {
                for path in session.dirtyPaths { _ = session.save(path) }
            }
            // Files and settings synced while away; not every sync tool tells file presenters.
            guard phase == .active else { return }
            takeShared()
            model.reloadConfig()
            Task { await workspace.refresh() }
        }
        .onOpenURL { url in
            if let request = CaptureRequest(link: url.absoluteString) { capture = request }
        }
    }

    /// What the share extension left, one capture sheet at a time.
    private func takeShared() {
        waiting += (model.inbox?.take() ?? []).compactMap(CaptureRequest.init(link:))
        if capture == nil { showWaiting() }
    }

    private func showWaiting() {
        if !waiting.isEmpty { capture = waiting.removeFirst() }
    }

    private func clock(_ id: String) {
        switch id {
        case "app.clock.out": message = model.clock.clockOut(session)
        case "app.clock.cancel": message = model.clock.clockOut(session, cancel: true)
        case "app.clock.goto":
            if let location = model.clock.location(session) { model.openRequest = .offset(location.path, location.offset) }
        case "app.clock.report": showingClockReport = true
        default: break
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
