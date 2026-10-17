#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI
import UserNotifications

/// First launch: what the app does, the folder of org files, and the permissions each
/// optional feature needs, asked for one at a time and only when the user chooses to.
struct OnboardingScreen: View {
    /// Set once onboarding is done or skipped for a workspace that had folders already.
    static let doneKey = "onboarded"

    let model: MobileModel
    let workspace: WorkspaceModel
    let finish: () -> Void
    @State private var step = Step.welcome
    @State private var importing = false
    @State private var problem: String?

    private enum Step: Int, CaseIterable {
        case welcome, folder, notifications, calendar, reminders
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .folder: folder
                case .notifications: notifications
                case .calendar: calendar
                case .reminders: reminders
                }
            }
            .frame(maxWidth: 500, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
            .id(step)
            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            .padding(.bottom, 12)
        }
        .tint(model.theme.accentColor)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            // Kept for the bookmark; WorkspaceRoot resolves it with access again at launch.
            _ = url.startAccessingSecurityScopedResource()
            Task {
                do {
                    try await workspace.addRoot(url)
                    problem = nil
                    next()
                } catch {
                    problem = "Can't add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private var welcome: some View {
        page(symbol: "star.fill", title: "Welcome to orgstar", text: "Your org files on iPhone, in the folders where they already are.") {
            VStack(alignment: .leading, spacing: 18) {
                feature("calendar", "The agenda", "Scheduled entries, deadlines and TODOs from all your files.")
                feature("hand.tap", "Tap to edit", "Change an entry's state, dates, tags and notes in place. Swipe to finish or reschedule.")
                feature("square.and.pencil", "Capture", "Your capture templates, from the app, the share sheet, widgets and the watch.")
            }
            .padding(.top, 8)
        } actions: {
            primary("Continue") { next() }
        }
    }

    private var folder: some View {
        page(symbol: "folder.fill", title: "Choose your org folder",
             text: "Pick the folder that holds your org files, in iCloud Drive or another provider. orgstar reads and writes them there; nothing is copied.") {
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
        } actions: {
            primary("Choose Folder") { importing = true }
            secondary("Later") { next() }
        }
    }

    private var notifications: some View {
        page(symbol: "bell.badge.fill", title: "Notifications",
             text: "orgstar can notify you before timed entries, as Org's appointment reminders do, and show today's overdue count on its icon.") {
            EmptyView()
        } actions: {
            primary("Allow Notifications") {
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                    next()
                }
            }
            secondary("Not Now") {
                // Off, so the agenda doesn't ask later; Settings turns it back on.
                model.set("reminders", to: .bool(false))
                next()
            }
        }
    }

    private var calendar: some View {
        page(symbol: "calendar.badge.clock", title: "Calendar events",
             text: "Show events from Calendar among your agenda's entries. You can choose which calendars in Settings.") {
            EmptyView()
        } actions: {
            primary("Show Calendar Events") {
                Task {
                    if await model.calendarEvents.requestAccess() { model.set("calendarEvents", to: .bool(true)) }
                    next()
                }
            }
            secondary("Not Now") { next() }
        }
    }

    private var reminders: some View {
        page(symbol: "checklist", title: "Reminders app",
             text: "Show incomplete reminders with a due date from the Reminders app in your agenda, read-only.") {
            EmptyView()
        } actions: {
            primary("Show Reminders") {
                Task {
                    if await model.reminderLists.requestAccess() { model.set("agendaReminders", to: .bool(true)) }
                    next()
                }
            }
            secondary("Not Now") { next() }
        }
    }

    private func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else {
            model.reloadConfig()
            finish()
            return
        }
        withAnimation(.snappy) { step = following }
    }

    // MARK: - Layout

    private func page<Content: View, Actions: View>(
        symbol: String, title: LocalizedStringKey, text: LocalizedStringKey,
        @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 96, height: 96)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.title.bold()).multilineTextAlignment(.center)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            content()
            Spacer(minLength: 24)
            VStack(spacing: 12) { actions() }
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func primary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }

    private func secondary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.body.weight(.medium))
            .frame(minHeight: 44)
    }
}
#endif
