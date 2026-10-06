#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Orgstar on iPhone and iPad: the agenda, capture, and the folders they read.
@main
struct OrgstarMobileApp: App {
    @State private var workspace = Result { try WorkspaceModel(directory: WorkspaceModel.defaultDirectory) }
    @State private var session = DocumentSession()

    var body: some Scene {
        WindowGroup {
            switch workspace {
            case .success(let model):
                RootView(workspace: model, session: session)
            case .failure(let error):
                ContentUnavailableView("Can't open the index", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            }
        }
    }
}

/// An org-protocol capture, or a plain one.
struct CaptureRequest: Identifiable {
    let id = UUID()
    var template: String?
    var properties: [String: String] = [:]
}

struct RootView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var agenda: AgendaModel
    @State private var capture: CaptureRequest?

    init(workspace: WorkspaceModel, session: DocumentSession) {
        self.workspace = workspace
        self.session = session
        _agenda = State(initialValue: AgendaModel(workspace: workspace))
    }

    var body: some View {
        TabView {
            Tab("Agenda", systemImage: "calendar") {
                NavigationStack {
                    AgendaScreen(workspace: workspace, session: session, agenda: agenda)
                        .toolbar { captureButton }
                }
            }
            Tab("Folders", systemImage: "folder") {
                NavigationStack {
                    FoldersScreen(workspace: workspace)
                        .toolbar { captureButton }
                }
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
