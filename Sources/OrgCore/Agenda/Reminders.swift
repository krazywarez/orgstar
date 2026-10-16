import Foundation

/// A notification for an agenda entry with a time of day.
public struct Reminder: Sendable, Equatable {
    /// Stable while the entry, its day and time stay the same.
    public let id: String
    public let fireDate: Date
    public let eventDate: Date
    public let title: String
    public let body: String
    public let path: String
    public let offset: Int
    /// The folder the entry's file is in, for Focus filters to mute.
    public var folder: String?

    public init(id: String, fireDate: Date, eventDate: Date, title: String, body: String, path: String, offset: Int) {
        self.id = id
        self.fireDate = fireDate
        self.eventDate = eventDate
        self.title = title
        self.body = body
        self.path = path
        self.offset = offset
    }
}

/// What `org-agenda-to-appt` hands appt: timed entries, each with a warning before it.
public enum Reminders {
    /// Reminders for the next `days` days from `now`, earliest first, at most `limit`. An
    /// entry whose warning time has passed but which hasn't started fires now.
    public static func upcoming(
        _ sources: [AgendaSource], now: Date, calendar: Calendar, days: Int = 7, lead: Int = 12, limit: Int = 64
    ) -> [Reminder] {
        let today = Days.absolute(now, calendar: calendar)
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let list = Agenda.list(sources, start: today, days: days, today: today, now: (clock.hour ?? 0, clock.minute ?? 0))
        var reminders: [Reminder] = []
        for day in list {
            let date = Days.date(day.day)
            guard let midnight = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) else { continue }
            for item in day.items {
                guard let time = item.timeOfDay, let path = item.path, !item.isDone,
                      [.deadline, .scheduled, .timestamp, .block].contains(item.kind),
                      let event = calendar.date(byAdding: .minute, value: (time / 100) * 60 + time % 100, to: midnight),
                      event > now else { continue }
                let fire = max(event.addingTimeInterval(-Double((item.warntime ?? lead) * 60)), now.addingTimeInterval(1))
                let clockText = String(format: "%d:%02d", time / 100, time % 100)
                // `Scheduled:` reads `Scheduled` beside the time.
                var leader = item.extra.trimmingCharacters(in: .whitespaces)
                if leader.hasSuffix(":") { leader.removeLast() }
                reminders.append(Reminder(
                    id: "orgstar.\(path)|\(item.headingLine ?? item.text.trimmingCharacters(in: .whitespaces))|\(day.day)|\(time)|\(item.kind.rawValue)",
                    fireDate: fire, eventDate: event, title: item.title,
                    body: ([clockText] + (leader.isEmpty ? [] : [leader]) + [item.category]).joined(separator: " · "),
                    path: path, offset: item.markerOffset ?? item.headingOffset ?? 0
                ))
            }
        }
        return Array(reminders.sorted { $0.fireDate < $1.fireDate }.prefix(limit))
    }
}
