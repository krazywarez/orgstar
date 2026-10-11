#if os(iOS)
import OrgApp
import OrgCore
import OrgWatchData
import UIKit
import WatchConnectivity

/// The watch, over WatchConnectivity: today's agenda and the clock go to it as the application
/// context, whenever the widgets update or the clock changes; what it asks for (done, clock out
/// or in, a dictated capture) runs here. iOS wakes the app for those when it isn't running.
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    weak var model: MobileModel?
    /// The last agenda sent, so an unchanged one isn't sent again.
    private var sent: Data?

    func activate(_ model: MobileModel) {
        self.model = model
        guard WCSession.isSupported(), WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends `agenda` when a watch is paired and it changed. Without the watch app installed,
    /// updating the context fails, and nothing is kept as sent.
    func send(_ agenda: WatchAgenda) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired,
              let data = try? agenda.data(), data != sent else { return }
        do {
            try session.updateApplicationContext([WatchAgenda.contextKey: data])
            sent = data
        } catch {}
    }

    func perform(_ action: WatchAction) async {
        guard let model, let workspace = model.workspace else { return }
        switch action {
        case .done(let path, let offset, let headingLine, let keyword):
            _ = model.session.perform(SetTodo(keyword: keyword), path: path, at: offset, expect: (offset, headingLine))
        case .clockOut:
            _ = MobileClock.run("app.clock.out", model: model, workspace: workspace) { _ in }
        case .clockInLast:
            _ = MobileClock.run("app.clock.in-last", model: model, workspace: workspace) { _ in }
            // Clocking in finishes after a moment.
            try? await Task.sleep(for: .seconds(1))
        case .capture(let text):
            // As the share extension leaves text: filed with a template when the app is next open.
            var components = URLComponents(string: "org-protocol://capture")!
            components.queryItems = [URLQueryItem(name: "body", value: text)]
            if let link = components.url?.absoluteString { try? model.inbox?.add(link) }
            model.watchCaptures += 1
        }
        await model.updateWidgets()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            guard activationState == .activated else { return }
            await self.model?.updateWidgets()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let action = WatchAction(userInfo: userInfo) else { return }
        Task { @MainActor in await self.perform(action) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let action = WatchAction(userInfo: message) else { return }
        Task { @MainActor in await self.perform(action) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.sent = nil
            await self.model?.updateWidgets()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A different watch was chosen: start again for it.
        session.activate()
    }
}
#endif
