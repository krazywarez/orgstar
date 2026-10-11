import OrgApp
import SwiftUI

/// A window of panes alone, as a second Emacs frame: no sidebar or search. It opens on the
/// buffer the focused pane showed, and its panes leave the session when it closes.
struct EditorWindowView: View {
    let session: DocumentSession
    let commands: AppCommands
    let clock: ClockModel
    @AppStorage("showTabBar") private var showTabBar = false
    @State private var window: WindowModel?
    @Environment(\.openWindow) private var openWindow

    /// App commands run in the main window; it comes back if it was closed.
    private func run(_ id: String) {
        if !commands.mainWindowOpen { openWindow(id: "main") }
        commands.run(id)
    }

    var body: some View {
        Group {
            if let window {
                PaneLayoutView(layout: window.layout, window: window) { pane in
                    PaneCell(pane: pane, window: window, session: session, commands: commands, showTabBar: showTabBar) { run($0) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        ModeLine(session: session, commands: commands, clock: clock) { run($0) }
                        EchoArea(commands: commands)
                    }
                }
            }
        }
        .navigationTitle(window?.focusedPane.path.map(session.bufferName) ?? "orgstar")
        .onAppear {
            guard window == nil else { return }
            let pane = session.makePane()
            if let path = session.focused.path { session.open(path, in: pane) }
            let model = WindowModel(session: session, pane: pane)
            window = model
            commands.store.windows.append(model)
            model.focus(pane.id)
        }
        .onDisappear {
            guard let model = window else { return }
            for id in model.layout.panes { commands.store.releasePane(id) }
            model.closeAll()
            commands.store.windows.removeAll { $0 === model }
            commands.editor = nil
            if let main = commands.store.windows.first { main.focus(main.focused) }
        }
    }
}
