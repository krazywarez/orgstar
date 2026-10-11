#if os(watchOS)
import OrgWatchData
import SwiftUI
import WatchConnectivity
import WidgetKit

/// orgstar on the watch: today's agenda from the phone, marking entries done, the running
/// clock, and dictated capture into the phone's capture inbox.
@main
struct OrgstarWatchApp: App {
    @State private var link = PhoneLink.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack { AgendaList(link: link) }
                .onAppear { link.activate() }
        }
    }
}

/// The phone, over WatchConnectivity: the agenda it last sent, and the actions sent to it.
/// Actions go as a message when the phone is reachable, which wakes the app there, else with
/// `transferUserInfo`, which waits for it.
@MainActor
@Observable
final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()

    private(set) var agenda: WatchAgenda? = WatchAgenda.read()
    /// Captures sent and not yet acknowledged by the next agenda.
    private(set) var sentCaptures = 0

    func activate() {
        guard WCSession.isSupported(), WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ action: WatchAction) {
        switch action {
        case .done:
            if case .done(_, let offset, _, _) = action, let agenda,
               let entry = (agenda.rows + agenda.overdue).first(where: { $0.offset == offset && $0.done == action }) {
                store(agenda.markingDone(entry.id))
            }
        case .clockOut:
            if var agenda {
                agenda.lastClocked = agenda.clock?.heading ?? agenda.lastClocked
                agenda.clock = nil
                store(agenda)
            }
        case .capture:
            sentCaptures += 1
        case .clockInLast:
            break
        }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let info = action.userInfo
        if session.isReachable {
            session.sendMessage(info, replyHandler: nil) { _ in session.transferUserInfo(info) }
        } else {
            session.transferUserInfo(info)
        }
    }

    private func store(_ new: WatchAgenda) {
        agenda = new
        if (try? new.write()) == true { WidgetCenter.shared.reloadAllTimelines() }
    }

    private func received(_ new: WatchAgenda?) {
        guard let new else { return }
        store(new)
        sentCaptures = 0
    }

    nonisolated private static func agenda(in context: [String: Any]) -> WatchAgenda? {
        (context[WatchAgenda.contextKey] as? Data).flatMap(WatchAgenda.decode)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let new = Self.agenda(in: session.receivedApplicationContext)
        Task { @MainActor in self.received(new) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let new = Self.agenda(in: applicationContext)
        Task { @MainActor in self.received(new) }
    }
}

/// Today: the running clock, capture, and the entries, each of which a tap marks done.
struct AgendaList: View {
    let link: PhoneLink
    @State private var capturing = false
    @State private var dictated = ""

    var body: some View {
        List {
            if let clock = link.agenda?.clock {
                Section("Clocked In") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clock.heading).font(.headline).lineLimit(2)
                        Text(clock.startedAt, style: .timer).font(.title3.monospacedDigit()).foregroundStyle(.green)
                    }
                    Button("Clock Out", systemImage: "stop.circle") { link.send(.clockOut) }.tint(.red)
                }
            } else if let last = link.agenda?.lastClocked {
                Section("Clock") {
                    Button { link.send(.clockInLast) } label: {
                        Label { Text("Clock In to \(last)").lineLimit(2) } icon: { Image(systemName: "play.circle") }
                    }
                }
            }
            Section {
                TextField("Capture", text: $dictated)
                    .onSubmit {
                        let text = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
                        dictated = ""
                        if !text.isEmpty { link.send(.capture(text: text)) }
                    }
                if link.sentCaptures > 0 {
                    Text(link.sentCaptures == 1 ? "Sent to orgstar on iPhone." : "\(link.sentCaptures) sent to orgstar on iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("orgstar files it with a template when you next open it on iPhone.")
            }
            if let agenda = link.agenda {
                if !agenda.overdue.isEmpty {
                    Section("Overdue") { ForEach(agenda.overdue) { EntryRow(entry: $0, link: link) } }
                }
                Section(agenda.day.formatted(.dateTime.weekday(.wide).day().month())) {
                    if agenda.rows.isEmpty { Text("Nothing scheduled").foregroundStyle(.secondary) }
                    ForEach(agenda.rows) { EntryRow(entry: $0, link: link) }
                }
            } else {
                Text("Open orgstar on your iPhone to show your agenda here.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Today")
    }
}

struct EntryRow: View {
    let entry: WatchAgenda.Entry
    let link: PhoneLink

    var body: some View {
        if let done = entry.done {
            Button { link.send(done) } label: { content(symbol: "circle") }
                .accessibilityHint("Marks it \(entry.doneKeyword ?? "done")")
        } else {
            content(symbol: entry.isDone ? "checkmark.circle.fill" : entry.isEvent ? "calendar" : nil)
        }
    }

    private func content(symbol: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(entry.isDone ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                if !entry.gutter.isEmpty {
                    Text(entry.gutter).font(.caption2).foregroundStyle(entry.status == "overdue" ? .red : .secondary)
                }
                Text(entry.title).strikethrough(entry.isDone).lineLimit(3)
                if let todo = entry.todo { Text(todo).font(.caption2.weight(.semibold)).foregroundStyle(entry.isDone ? .green : .orange) }
            }
        }
    }
}
#else
/// The watch app builds for watchOS only; elsewhere the product does nothing.
@main
enum OrgstarWatchApp {
    static func main() {}
}
#endif
