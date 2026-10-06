import Foundation

extension EmacsBuffer {
    /// Reads a date prompt answer the way `org-read-date` does: an empty answer takes the
    /// default date.
    func readDate(_ answer: String, default defaultDate: Date?) -> ReadDate.Answer {
        ReadDate.read(answer, default: defaultDate, now: now, calendar: calendar)
    }

    /// The date an Org time string stands for, as a prompt default.
    func dateDefault(_ stamp: String?) -> Date? { stamp.flatMap(Self.parseTimeString).map(date) }

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
    func schedule(_ kind: PlanningKind, answer: String, answers: [String: String] = [:]) throws {
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
        if let old, let inserted = lastInsertedTimestamp {
            try logPlanningChange(kind, old: "<" + old + ">", new: inserted, answers: answers)
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
            let buffer = EmacsBuffer(context.text, point: context.caret)
            buffer.calendar = context.calendar
            let stamp = buffer.atTimestamp().map { buffer.substring($0.match[0]!.lowerBound, $0.match[0]!.upperBound) }
            let repeated = context.lastCommand == "org.timestamp.active" || context.lastCommand == "org.timestamp.inactive"
            return .prompt(Prompt(key: "date", message: "Date+time:", initial: timeOfDayAtCaret(context),
                                  date: .init(defaultDate: repeated ? nil : buffer.dateDefault(stamp))))
        }
        // Twice in a row on a timestamp: a range to a second one.
        let repeated = context.lastCommand == "org.timestamp.active" || context.lastCommand == "org.timestamp.inactive"
        if repeated, EmacsBuffer(context.text, point: context.caret).atTimestamp() != nil {
            return timestampCommand(context) { buffer in
                let result = buffer.readDate(answer, default: nil)
                buffer.insert("--")
                buffer.insertTimestamp(result.components(buffer.calendar), withTime: result.timeGiven, inactive: inactive)
            }
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
            buffer.calendar = context.calendar
            let initial = buffer.planningDefault(kind).flatMap(EmacsBuffer.compactTimeOfDay) ?? ""
            return .prompt(Prompt(key: "date", message: deadline ? "DEADLINE:" : "SCHEDULED:", initial: initial,
                                  date: .init(defaultDate: buffer.dateDefault(buffer.planningDefault(kind)))))
        }
        return timestampCommand(context) { try $0.schedule(kind, answer: answer, answers: context.answers) }
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
        timestampCommand(context) { buffer in
            let kind: EmacsBuffer.PlanningKind = deadline ? .deadline : .scheduled
            let old = buffer.planningValue(kind)
            if let old { try buffer.logPlanningChange(kind, old: "<" + old + ">", new: nil, answers: context.answers) }
            buffer.removePlanning(kind)
        }
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

/// C-c C-y: `org-evaluate-time-range`. On a clock line, updates it; otherwise says how long the
/// range at the caret, or the first on its line, lasts.
public struct EvaluateTimeRange: OrgCommand {
    public init() {}
    public var id: String { "org.timestamp.evaluate-range" }
    public var title: String { "Evaluate Time Range" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret)
        buffer.calendar = context.calendar
        if buffer.lookingAtLine("^[ \\t]*CLOCK:") { return CtrlCCtrlC().run(in: context) }
        let ns = context.text as NSString
        let line = ns.lineRange(for: NSRange(location: min(context.caret, ns.length), length: 0))
        let regex = try! NSRegularExpression(pattern: "[\\[<]([0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]>\\n]*?)[\\]>]--?-?[\\[<]([0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]>\\n]*?)[\\]>]")
        let matches = regex.matches(in: context.text, range: line)
        guard let m = matches.first(where: { $0.range.location <= context.caret && context.caret <= NSMaxRange($0.range) }) ?? matches.first else {
            return .failed("Not at a timestamp range, and none found in current line")
        }
        let ts1 = ns.substring(with: m.range(at: 1))
        let ts2 = ns.substring(with: m.range(at: 2))
        let haveTime = ts1.count > 15 || ts2.count > 15
        let t1 = TagsMatcher.seconds(ts1, now: context.now, calendar: context.calendar)
        let t2 = TagsMatcher.seconds(ts2, now: context.now, calendar: context.calendar)
        var diff = abs(t2 - t1)
        var d = 0, h = 0, minutes = 0
        if haveTime {
            d = Int(floor(diff / 86400)); diff = diff.truncatingRemainder(dividingBy: 86400)
            h = Int(floor(diff / 3600)); diff = diff.truncatingRemainder(dividingBy: 3600)
            minutes = Int(floor(diff / 60))
        } else {
            d = Int((diff / 86400).rounded())
        }
        var parts: [String] = []
        if d > 0 { parts.append("\(d) day" + (d > 1 ? "s" : "")) }
        if h > 0 { parts.append("\(h) hour" + (h > 1 ? "s" : "")) }
        if minutes > 0 { parts.append("\(minutes) minute" + (minutes > 1 ? "s" : "")) }
        let text = parts.isEmpty ? "" : parts.joined(separator: " ") + " "
        return .commit(EditResult(baseRevision: context.revision, edits: [], effects: [.message(text)]))
    }
}
