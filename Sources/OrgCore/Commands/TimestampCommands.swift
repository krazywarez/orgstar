import Foundation

extension EmacsBuffer {
    /// Reads a date prompt answer the way `org-read-date` does: an empty answer takes the
    /// default date.
    func readDate(_ answer: String, default defaultDate: Date?) -> ReadDate.Answer {
        let def = defaultDate ?? now
        var input = answer
        if input.trimmingCharacters(in: .whitespaces).isEmpty {
            let c = calendar.dateComponents([.year, .month, .day], from: def)
            input = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        return ReadDate.analyze(input, default: def, now: now, calendar: calendar)
    }

    func date(_ components: DateComponents) -> Date { calendar.date(from: components)! }

    /// `org-timestamp`: replaces the timestamp at point, keeping its repeater, or inserts one.
    func timestampCommand(_ answer: String, inactive: Bool) {
        let existing = atTimestamp()
        let stamp = existing.map { substring($0.match[0]!.lowerBound, $0.match[0]!.upperBound) }
        let defaultDate = stamp.flatMap(Self.parseTimeString).map(date)
        let repeater = stamp.flatMap { $0.firstMatch(of: try! Regex("([.+-]+[0-9]+[hdwmy] ?)+")).map { String($0.output[0].substring!) } }
        let result = readDate(answer, default: defaultDate)
        let components = result.components(calendar)
        if let existing {
            replace(existing.match[0]!, with: "")
            insertTimestamp(components, withTime: result.timeGiven, inactive: inactive, endTime: result.endTime)
            if let repeater {
                point -= 1
                insert(" " + repeater)
            }
        } else {
            insertTimestamp(components, withTime: result.timeGiven, inactive: inactive, endTime: result.endTime)
        }
    }

    /// The first timestamp after `kind` in the entry, as the date prompt's default.
    func planningDefault(_ kind: PlanningKind) -> String? {
        saveExcursion {
            guard (try? backToHeading()) != nil else { return nil }
            let end = saveExcursion { () -> Int in outlineNextHeading(); return point }
            return searchForward(kind.pattern, bound: end, caseInsensitive: false).map { substring($0[1]!.lowerBound, $0[1]!.upperBound) }
        }
    }

    /// `org--deadline-or-schedule` without a prefix argument.
    func schedule(_ kind: PlanningKind, answer: String) throws {
        let old = planningValue(kind)
        let repeatPattern = "([.+-]+[0-9]+[hdwmy](?:[/ ][-+]?[0-9]+[hdwmy])?)"
        let repeater = old.flatMap { $0.firstMatch(of: try! Regex(repeatPattern)).map { String($0.output[1].substring!) } }
        let defaultDate = planningDefault(kind).flatMap(Self.parseTimeString).map(date)
        let result = readDate(answer, default: defaultDate)
        try addPlanningInfo(kind, time: result.components(calendar), withTime: result.timeGiven, endTime: result.endTime, remove: [.closed])
        if let repeater, let inserted = lastInsertedTimestamp {
            try saveExcursion {
                try backToHeading()
                let bound = saveExcursion { () -> Int in forwardLine(2); return lineEnd(point) }
                if let match = searchForward(NSRegularExpression.escapedPattern(for: kind.keyword + " " + inserted), bound: bound, caseInsensitive: false) {
                    point = match[0]!.upperBound - 1
                    insert(" " + repeater)
                }
            }
        }
    }

    /// `org--deadline-or-schedule` with C-u: removes the planning timestamp.
    func removePlanning(_ kind: PlanningKind) {
        guard planningValue(kind) != nil else { return }
        saveExcursion {
            guard let begin = try? backToHeading() else { return }
            outlineNextHeading()
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: kind.keyword) + " +<[^>\\n]+>[ \\t]*"
            while let match = searchBackward(pattern, bound: begin, caseInsensitive: false) {
                replace(match[0]!, with: "")
                let before = substring(lineStart(point), point)
                if before.contains(where: { !$0.isWhitespace }), character(at: point - 1) == 32 {
                    deleteRegion(point - 1, point)
                } else if substring(lineStart(point), lineEnd(point)).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    deleteRegion(lineStart(point), min(length, lineEnd(point) + 1))
                }
            }
        }
    }
}

private func timestampCommand(_ context: EditContext, _ body: (EmacsBuffer) throws -> Void) -> CommandStep {
    commitBuffer(context, body)
}

private func atTimestamp(_ context: EditContext) -> Bool {
    EmacsBuffer(context.text, point: context.caret).atTimestamp() != nil
}

/// The prompt's starting text: the time of the timestamp at the caret, as org pre-fills it.
private func timeOfDayAtCaret(_ context: EditContext) -> String {
    let buffer = EmacsBuffer(context.text, point: context.caret)
    guard let match = buffer.atTimestamp()?.match[0] else { return "" }
    return EmacsBuffer.compactTimeOfDay(buffer.substring(match.lowerBound, match.upperBound)) ?? ""
}

/// C-c . and C-c !: `org-timestamp`.
public struct InsertTimestamp: OrgCommand {
    let inactive: Bool
    public init(inactive: Bool = false) { self.inactive = inactive }
    public var id: String { inactive ? "org.timestamp.inactive" : "org.timestamp.active" }
    public var title: String { inactive ? "Insert Inactive Timestamp" : "Insert Timestamp" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        guard let answer = context.answers["date"] else {
            return .prompt(Prompt(key: "date", message: "Date+time:", initial: timeOfDayAtCaret(context)))
        }
        return timestampCommand(context) { $0.timestampCommand(answer, inactive: inactive) }
    }
}

/// C-c C-s and C-c C-d: `org-schedule` and `org-deadline`.
public struct SetPlanning: OrgCommand {
    let deadline: Bool
    public init(deadline: Bool) { self.deadline = deadline }
    public var id: String { deadline ? "org.deadline" : "org.schedule" }
    public var title: String { deadline ? "Set Deadline" : "Schedule" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        guard entryHeading(at: context.caret, in: context.tree) != nil else { return .failed("Before first headline") }
        let kind: EmacsBuffer.PlanningKind = deadline ? .deadline : .scheduled
        guard let answer = context.answers["date"] else {
            let buffer = EmacsBuffer(context.text, point: context.caret)
            let initial = buffer.planningDefault(kind).flatMap(EmacsBuffer.compactTimeOfDay) ?? ""
            return .prompt(Prompt(key: "date", message: deadline ? "DEADLINE:" : "SCHEDULED:", initial: initial))
        }
        return timestampCommand(context) { try $0.schedule(kind, answer: answer) }
    }
}

/// C-u C-c C-s and C-u C-c C-d.
public struct RemovePlanning: OrgCommand {
    let deadline: Bool
    public init(deadline: Bool) { self.deadline = deadline }
    public var id: String { deadline ? "org.deadline.remove" : "org.schedule.remove" }
    public var title: String { deadline ? "Remove Deadline" : "Remove Schedule" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        timestampCommand(context) { $0.removePlanning(deadline ? .deadline : .scheduled) }
    }
}

/// S-up and S-down on a timestamp: `org-timestamp-up` and `org-timestamp-down`.
public struct ShiftTimestamp: OrgCommand {
    let up: Bool
    public init(up: Bool) { self.up = up }
    public var id: String { up ? "org.timestamp.up" : "org.timestamp.down" }
    public var title: String { up ? "Increase Timestamp Part" : "Decrease Timestamp Part" }
    public func applies(in context: EditContext) -> Bool { atTimestamp(context) }
    public func run(in context: EditContext) -> CommandStep {
        timestampCommand(context) { try $0.changeTimestamp(up ? 1 : -1, updown: true) }
    }
}

/// S-right and S-left on a timestamp: `org-timestamp-up-day` and `org-timestamp-down-day`.
public struct ShiftTimestampDay: OrgCommand {
    let later: Bool
    public init(later: Bool) { self.later = later }
    public var id: String { later ? "org.timestamp.day-later" : "org.timestamp.day-earlier" }
    public var title: String { later ? "Timestamp One Day Later" : "Timestamp One Day Earlier" }
    public func applies(in context: EditContext) -> Bool { atTimestamp(context) }
    public func run(in context: EditContext) -> CommandStep {
        timestampCommand(context) { try $0.changeTimestamp(later ? 1 : -1, what: .day, updown: true) }
    }
}
