import Foundation

/// What the watch shows, sent by the phone over WatchConnectivity: today's agenda, the running
/// clock and the entry Clock In Last would take. The watch keeps the last one it got.
public struct WatchAgenda: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// The agenda's gutter: the time or a short status.
        public var gutter: String
        public var category: String
        public var todo: String?
        /// `AgendaRow.Status`'s raw value: `overdue`, `due-soon`, `normal`, `done`.
        public var status: String
        public var isDone: Bool
        public var isEvent: Bool
        public var start: Date?
        public var end: Date?
        /// Where the entry is, and its heading line, for the phone to find it again.
        public var path: String?
        public var offset: Int?
        public var headingLine: String?
        /// The keyword marking it done takes: the first done keyword of its sequence.
        public var doneKeyword: String?

        public init(
            id: String, title: String, gutter: String, category: String, todo: String?, status: String, isDone: Bool, isEvent: Bool,
            start: Date?, end: Date?, path: String?, offset: Int?, headingLine: String?, doneKeyword: String?
        ) {
            self.id = id
            self.title = title
            self.gutter = gutter
            self.category = category
            self.todo = todo
            self.status = status
            self.isDone = isDone
            self.isEvent = isEvent
            self.start = start
            self.end = end
            self.path = path
            self.offset = offset
            self.headingLine = headingLine
            self.doneKeyword = doneKeyword
        }

        /// An open TODO entry the phone can find.
        public var canBeDone: Bool {
            !isDone && !isEvent && todo != nil && doneKeyword != nil && path != nil && offset != nil && headingLine != nil
        }

        /// The action marking it done.
        public var done: WatchAction? {
            guard canBeDone, let path, let offset, let headingLine, let doneKeyword else { return nil }
            return .done(path: path, offset: offset, headingLine: headingLine, keyword: doneKeyword)
        }
    }

    public struct Clock: Codable, Equatable, Sendable {
        public var heading: String
        public var startedAt: Date

        public init(heading: String, startedAt: Date) {
            self.heading = heading
            self.startedAt = startedAt
        }
    }

    public var generated: Date
    /// Midnight starting today.
    public var day: Date
    /// Deadlines and scheduled entries from before today.
    public var overdue: [Entry]
    public var rows: [Entry]
    public var clock: Clock?
    /// The most recently clocked entry, `org-clock-in-last`'s.
    public var lastClocked: String?

    public init(generated: Date, day: Date, overdue: [Entry], rows: [Entry], clock: Clock?, lastClocked: String?) {
        self.generated = generated
        self.day = day
        self.overdue = overdue
        self.rows = rows
        self.clock = clock
        self.lastClocked = lastClocked
    }

    /// What's left of today at `now`, as the Up Next widget counts it: entries that aren't
    /// done, without timed ones that have ended (or started, with no end), then the overdue.
    public func upcoming(at now: Date, calendar: Calendar = .current) -> [Entry] {
        guard calendar.isDate(day, inSameDayAs: now) else { return [] }
        let left = rows.filter { row in
            guard !row.isDone else { return false }
            if let end = row.end ?? row.start { return end > now }
            return true
        }
        return left + overdue.filter { !$0.isDone }
    }

    /// The first of `upcoming`.
    public func next(at now: Date, calendar: Calendar = .current) -> Entry? { upcoming(at: now, calendar: calendar).first }

    /// Open TODO entries today and overdue, as the complication counts them.
    public func openCount(at now: Date, calendar: Calendar = .current) -> Int {
        guard calendar.isDate(day, inSameDayAs: now) else { return 0 }
        return (rows + overdue).filter { !$0.isDone && !$0.isEvent && $0.todo != nil }.count
    }

    /// `entry` marked done here before the phone sends the agenda again.
    public func markingDone(_ id: String) -> WatchAgenda {
        var copy = self
        func mark(_ rows: inout [Entry]) {
            for i in rows.indices where rows[i].id == id {
                rows[i].isDone = true
                rows[i].todo = rows[i].doneKeyword
                rows[i].status = "done"
            }
        }
        mark(&copy.rows)
        mark(&copy.overdue)
        return copy
    }

    // MARK: - Transfer

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The application context key the agenda travels under.
    public static let contextKey = "agenda"

    public func data() throws -> Data { try Self.encoder.encode(self) }

    public static func decode(_ data: Data) -> WatchAgenda? { try? decoder.decode(WatchAgenda.self, from: data) }

    /// `Widgets/watch.json` in the app group's container, which the complications read; nil
    /// without the group.
    public static func file(group: String = "group.sh.krz.orgstar") -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Widgets").appendingPathComponent("watch.json")
    }

    public static func read(from file: URL? = file()) -> WatchAgenda? {
        file.flatMap { try? Data(contentsOf: $0) }.flatMap(decode)
    }

    /// Writes unless the file holds the same; true when it wrote.
    @discardableResult
    public func write(to file: URL? = WatchAgenda.file()) throws -> Bool {
        guard let file, Self.read(from: file) != self else { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data().write(to: file, options: .atomic)
        return true
    }
}

/// What the watch asks the phone to do.
public enum WatchAction: Codable, Equatable, Sendable {
    /// Sets the entry's keyword to `keyword`, if its heading line is still `headingLine`.
    case done(path: String, offset: Int, headingLine: String, keyword: String)
    case clockOut
    /// `org-clock-in-last`.
    case clockInLast
    /// Dictated text for the capture inbox.
    case capture(text: String)

    /// The user info key an action travels under.
    public static let key = "action"

    public var userInfo: [String: Any] {
        guard let data = try? WatchAgenda.encoder.encode(self) else { return [:] }
        return [Self.key: data]
    }

    public init?(userInfo: [String: Any]) {
        guard let data = userInfo[Self.key] as? Data, let action = try? WatchAgenda.decoder.decode(WatchAction.self, from: data) else { return nil }
        self = action
    }
}
