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

    init() {
        #if DEBUG
        Perf.watchMainThread()
        #endif
        LiveClock.install()
    }

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
    /// An agenda day (a `Days` number) the entry is scheduled on.
    var day: Int?
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

    /// Reminders, widgets and Spotlight following the files. Its own view, so that edits redraw
    /// only it, not the tabs.
    private struct BackgroundWork: View {
        let model: MobileModel
        let workspace: WorkspaceModel
        let agenda: AgendaModel
        let active: Bool
        let hour: Int

        private var session: DocumentSession { model.session }

        var body: some View {
            Color.clear
                // Reminders follow the files, the settings, coming back to the app and the hour.
                .task(id: ReminderKey(files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion,
                                      settings: model.settingsVersion, active: active, hour: hour)) {
                    guard active else { return }
                    try? await Task.sleep(for: .seconds(1))
                    // After the agenda's refresh, whose parsed files these share.
                    while agenda.isComputing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                    guard !Task.isCancelled else { return }
                    await model.updateReminders()
                    await model.updateWidgets()
                }
                // Spotlight follows the files and saved edits.
                .task(id: SpotlightKey(files: workspace.files.count, changed: workspace.changedFile?.version, saved: session.dirtyPaths.count)) {
                    await model.spotlight.update(workspace.files)
                }
        }
    }

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
                        .equatable()
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
        .clockAccessory(model.clock, perform: clock)
        .sheet(item: Binding(get: { model.clockPrompts.pending }, set: { if $0 == nil { model.clockPrompts.answer(nil) } })) { pending in
            ClockPromptSheet(prompt: pending.prompt) { model.clockPrompts.answer($0) }
        }
        // Above the tab bar, clear of every screen's toolbar.
        .overlay(alignment: .bottom) {
            if let message {
                Text(message).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 150)
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
        .onChange(of: model.agendaRequest) {
            guard let request = model.agendaRequest else { return }
            model.agendaRequest = nil
            agenda.mode = .agenda(span: request.count, startOffset: nil)
            agenda.start = request.start
            tab = .agenda
            agendaPath = NavigationPath()
        }
        .onChange(of: workspace.changedFile?.version) {
            // An open file takes in what changed on disk.
            if let path = workspace.changedFile?.path { session.fileChanged(path) }
        }
        .onChange(of: model.captureRequest?.id) {
            guard let request = model.captureRequest else { return }
            model.captureRequest = nil
            capture = request
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
        .background { BackgroundWork(model: model, workspace: workspace, agenda: agenda, active: scenePhase == .active, hour: hour) }
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
            if let link = AppLink(url: url) {
                open(link)
            } else if let request = CaptureRequest(link: url.absoluteString) {
                capture = request
            } else if case .storeLink(let link, let title)? = OrgProtocol.parse(url.absoluteString) {
                message = StoredLink.add(StoredLink(link: link, description: title), to: &model.storedLinks)
                UIPasteboard.general.string = link
            }
        }
        // The Live Activity follows the clock, wherever it starts or stops.
        .task { await LiveClock.sync(model.clock.running) }
        .onChange(of: model.clock.running) {
            Task { await LiveClock.sync(model.clock.running) }
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

    /// A widget's or the Live Activity's link.
    private func open(_ link: AppLink) {
        switch link {
        case .agenda:
            tab = .agenda
            agendaPath = NavigationPath()
        case .entry(let path, let offset):
            model.openRequest = .offset(path, offset)
        case .clock:
            clock("app.clock.goto")
        }
    }

    private func clock(_ id: String) {
        if id == "app.clock.report" {
            showingClockReport = true
        } else {
            _ = MobileClock.run(id, model: model, workspace: workspace) { message = $0 }
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
