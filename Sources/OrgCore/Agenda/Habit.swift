import Foundation

/// An entry with `STYLE: habit` (org-habit.el, Org 9.8.7), as `org-habit-parse-todo` reads
/// it, with `org-log-states-order-reversed` t.
public struct Habit: Sendable, Equatable, Codable {
    /// Days are absolute day numbers (`Days`).
    public let scheduled: Int
    public let scheduledRepeat: Int
    let deadlineDay: Int?
    let deadlineRepeatDays: Int?
    /// Days the entry was done, at most `preceding + following` of them, oldest first.
    public let doneDates: [Int]
    /// `+`, `++` or `.+`.
    public let repeatType: String

    public init(
        scheduled: Int, scheduledRepeat: Int, deadlineDay: Int? = nil, deadlineRepeatDays: Int? = nil, doneDates: [Int], repeatType: String = ".+"
    ) {
        self.scheduled = scheduled
        self.scheduledRepeat = scheduledRepeat
        self.deadlineDay = deadlineDay
        self.deadlineRepeatDays = deadlineRepeatDays
        self.doneDates = doneDates
        self.repeatType = repeatType
    }

    public static let precedingDays = 21
    public static let followingDays = 7

    /// `org-habit-deadline`.
    public var deadline: Int {
        deadlineDay ?? (deadlineRepeatDays != nil ? scheduled + scheduledRepeat - 1 : scheduled)
    }

    /// `org-habit-deadline-repeat`.
    public var deadlineRepeat: Int { deadlineRepeatDays ?? scheduledRepeat }

    static let repeatRegex = try! NSRegularExpression(pattern: "[+.]?\\+[0-9]+[hdwmy](/[0-9]+[hdwmy])?")
    static let durationRegex = try! NSRegularExpression(pattern: "([0-9]+)([dwmy])")

    /// `org-habit-duration-to-days`.
    static func days(_ s: String) -> Int? {
        let ns = s as NSString
        guard let m = durationRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let n = Double(ns.substring(with: m.range(at: 1)))!
        let factor: Double = switch ns.substring(with: m.range(at: 2)) {
        case "d": 1
        case "w": 7
        case "m": 30.4
        default: 365.25
        }
        return Int((n * factor).rounded(.down))
    }

    /// `org-habit-parse-todo` for the entry whose text is `entry` (heading line to the next
    /// heading) and whose SCHEDULED timestamp is `scheduled` (without brackets). Nil where
    /// org signals an error.
    public static func parse(entry: String, scheduled: String, doneKeywords: [String]) -> Habit? {
        guard let day = Days.absolute(of: scheduled) else { return nil }
        let sns = scheduled as NSString
        guard let rm = repeatRegex.firstMatch(in: scheduled, range: NSRange(location: 0, length: sns.length)) else { return nil }
        let repeat_ = sns.substring(with: rm.range)
        guard let srDays = days(repeat_), srDays > 0 else { return nil }
        let type = String(repeat_.prefix { $0 == "." || $0 == "+" })
        var deadline: Int?
        var drDays: Int?
        if let slash = repeat_.range(of: "/[0-9]+[dwmy]", options: .regularExpression) {
            guard let dr = days(String(repeat_[slash].dropFirst())), dr > srDays else { return nil }
            drDays = dr
            deadline = day + dr - srDays
        }
        let done = doneKeywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let inactive = "\\[([0-9]{4}-[0-9]{2}-[0-9]{2} ?[^\\]\\r\\n>]*?)\\]"
        // `org-log-note-headings` `done` is "CLOSING NOTE %t".
        let pattern = "^[ \\t]*-[ \\t]+(?:State \"(?:\(done))\".*\(inactive)|CLOSING NOTE \(inactive))"
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
        let ens = entry as NSString
        var closed: [Int] = []
        for m in regex.matches(in: entry, range: NSRange(location: 0, length: ens.length)) {
            guard closed.count < precedingDays + followingDays else { break }
            let group = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            if let d = Days.absolute(of: ens.substring(with: group)) { closed.insert(d, at: 0) }
        }
        return Habit(scheduled: day, scheduledRepeat: srDays, deadlineDay: deadline, deadlineRepeatDays: drDays, doneDates: closed, repeatType: type)
    }

    /// `org-habit-get-urgency`.
    public func urgency(today: Int) -> Int {
        var pri = 1000 + (today - scheduled) * 10
        if scheduled != deadline, today == deadline { pri += 50 }
        let slip = today - (deadline - 1)
        pri += slip > 0 ? slip * 100 : slip * 10
        return pri
    }

    public enum Face: String, Sendable {
        case clear, clearFuture, ready, readyFuture, alert, alertFuture, overdue, overdueFuture
    }

    public struct Cell: Sendable, Equatable {
        public let day: Int
        /// `*` done, `!` today, or a space.
        public let glyph: Character
        public let face: Face
    }

    /// `org-habit-get-faces`.
    func faces(now: Int, scheduledDays: Int?, done: Bool) -> (Face, Face) {
        let scheduled = scheduledDays ?? self.scheduled
        let deadline = scheduledDays.map { $0 + deadlineRepeat - scheduledRepeat } ?? self.deadline
        if now < scheduled { return (.clear, .clearFuture) }
        if now < deadline { return (.ready, .readyFuture) }
        if now == deadline { return done ? (.ready, .readyFuture) : (.alert, .alertFuture) }
        return (.overdue, .overdueFuture)
    }

    /// `org-habit-build-graph` from `today - preceding` to `today + following` (exclusive),
    /// as `org-habit-insert-consistency-graphs` calls it.
    public func graph(today: Int, preceding: Int = precedingDays, following: Int = followingDays) -> [Cell] {
        let allDone = doneDates.sorted()
        var doneIndex = 0
        var lastDone: Int?
        let first = today - preceding
        while doneIndex < allDone.count, allDone[doneIndex] < first {
            lastDone = allDone[doneIndex]
            doneIndex += 1
        }
        var cells: [Cell] = []
        for day in first..<(today + following) {
            let past = day < today
            let isToday = day == today
            let isDone = doneIndex < allDone.count && allDone[doneIndex] == day
            let faces: (Face, Face)
            if past, lastDone == nil, !(scheduled < today) {
                faces = allDone.first == day ? (.ready, .readyFuture) : (.clear, .clearFuture)
            } else {
                var scheduledDays: Int?
                if past, let last = lastDone {
                    let remaining = allDone.count - doneIndex
                    if remaining == 0 {
                        scheduledDays = scheduled
                    } else if repeatType == ".+" {
                        scheduledDays = last + scheduledRepeat
                    } else if repeatType == "+" {
                        scheduledDays = scheduled - remaining * scheduledRepeat
                    } else {
                        let firstDone = allDone[0]
                        let shift = ((scheduled - firstDone) % scheduledRepeat + scheduledRepeat) % scheduledRepeat
                        var s = (shift == 0 ? scheduledRepeat : shift) + firstDone
                        if firstDone != last {
                            for done in allDone.dropFirst() {
                                s += (1 + max(done - s, 0) / scheduledRepeat) * scheduledRepeat
                                if done == last { break }
                            }
                        }
                        scheduledDays = s
                    }
                }
                faces = self.faces(now: day, scheduledDays: scheduledDays, done: isDone)
            }
            var glyph: Character = " "
            var marked = false
            if isDone {
                glyph = "*"
                marked = true
                while doneIndex < allDone.count, allDone[doneIndex] == day {
                    lastDone = day
                    doneIndex += 1
                }
            } else if isToday {
                glyph = "!"
            }
            var face = past || isToday ? faces.0 : faces.1
            if past, face != .overdue, !marked { face = faces.1 }
            cells.append(Cell(day: day, glyph: glyph, face: face))
        }
        return cells
    }

    /// The agenda line with the graph at `org-habit-graph-column` (40), as
    /// `org-habit-insert-consistency-graphs` puts it.
    public static func insertGraph(_ cells: [Cell], into line: String, column: Int = 40) -> String {
        var chars = Array(line)
        var width = 0
        var index = 0
        while index < chars.count, width < column {
            width += displayWidth(of: chars[index])
            index += 1
        }
        if width < column { chars += Array(repeating: " ", count: column - width); index = chars.count }
        let remove = Swift.min(precedingDays + followingDays + 1, chars.count - index)
        chars.removeSubrange(index..<(index + remove))
        // build-graph's vector has one more cell than it fills.
        chars.insert(contentsOf: cells.map(\.glyph) + [" "], at: index)
        return String(chars)
    }
}
