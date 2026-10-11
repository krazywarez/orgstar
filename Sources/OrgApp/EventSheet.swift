import Foundation
import OrgPresentation
import SwiftUI

/// What the event sheet does: change an event from the agenda, or add an entry to a calendar.
public struct EventRequest: Identifiable {
    public let id = UUID()
    public let draft: EventDraft
    /// The event changed; nil adds a new one.
    public let event: AgendaEvent?

    public init(draft: EventDraft, event: AgendaEvent? = nil) {
        self.draft = draft
        self.event = event
    }
}

/// An event's title, times, location and calendar, saved to Calendar. `done` closes the sheet
/// with a message, nil when cancelled.
public struct EventSheet: View {
    let request: EventRequest
    let events: CalendarEvents
    let done: (String?) -> Void
    @State private var draft: EventDraft
    @State private var calendars: [(id: String, title: String, color: RGBA?)] = []
    @State private var problem: String?

    public init(request: EventRequest, events: CalendarEvents, done: @escaping (String?) -> Void) {
        self.request = request
        self.events = events
        self.done = done
        _draft = State(initialValue: request.draft)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Title", text: $draft.title)
                Toggle("All day", isOn: $draft.isAllDay)
                DatePicker("Starts", selection: $draft.start, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $draft.end, in: draft.start..., displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                TextField("Location", text: $draft.location)
                Picker("Calendar", selection: $draft.calendarID) {
                    ForEach(calendars, id: \.id) { calendar in Text(calendar.title).tag(calendar.id) }
                }
                if request.event != nil, events.isRepeating(request.event!) {
                    Text("Changes apply to this occurrence only.").font(.caption).foregroundStyle(.secondary)
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            #if os(macOS)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(request.event == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420)
        #else
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { done(nil) } }
            ToolbarItem(placement: .confirmationAction) { Button(request.event == nil ? "Add" : "Save") { save() }.disabled(!canSave) }
        }
        #endif
        .task {
            _ = await events.requestAccess()
            calendars = events.writableCalendars()
            if !calendars.contains(where: { $0.id == draft.calendarID }) {
                draft.calendarID = calendars.first { $0.id == events.defaultCalendarID }?.id ?? calendars.first?.id ?? ""
            }
            if calendars.isEmpty { problem = CalendarEvents.isAuthorized ? "No calendar can be changed." : CalendarEvents.SaveError.noAccess.description }
        }
    }

    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && !draft.calendarID.isEmpty }

    private func save() {
        do {
            try events.save(draft, replacing: request.event)
            let name = calendars.first { $0.id == draft.calendarID }?.title ?? "Calendar"
            done(request.event == nil ? "Added to \(name)." : "Saved.")
        } catch {
            problem = "\(error)"
        }
    }
}
