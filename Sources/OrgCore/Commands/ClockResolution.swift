import Foundation

// Resolving an open clock after idle time or a dangling one (`org-clock-resolve`,
// `org-clock-resolve-clock`, Org 9.8.7) with `org-clock-resolve-expert` nil. The answer
// becomes steps on the CLOCK line, which the app carries out with `ClockOut` and `ClockIn`.

public enum ClockResolution {
    /// The keys `org-clock-resolve` reads.
    public static let keys: [Character] = ["j", "J", "k", "K", "t", "T", "g", "G", "S", "s", "C", "i", "q"]

    /// The question's suffix, after the clock's description.
    public static let keyHint = " [jkKtTgGSscCiq]? "

    /// The keys with what they do, from Org's *Org Clock* help.
    public static let menu = FastSelection(items: [
        .option(key: "i", name: "Ignore this question; the same as keeping all the idle time"), .newline,
        .option(key: "q", name: "Ignore this question; the same as keeping all the idle time"), .newline,
        .option(key: "k", name: "Keep X minutes of the idle time (default is all)"), .newline,
        .option(key: "K", name: "Keep X minutes of the idle time, then clock out"), .newline,
        .option(key: "t", name: "Like k, but ask for the time you got distracted"), .newline,
        .option(key: "T", name: "Like t, then clock out"), .newline,
        .option(key: "g", name: "Got back X minutes ago: clock out at the start of idling, in again X minutes ago"), .newline,
        .option(key: "G", name: "Like g, but stay clocked out"), .newline,
        .option(key: "s", name: "Subtract the idle time from the current clock"), .newline,
        .option(key: "S", name: "Subtract the idle time and clock out"), .newline,
        .option(key: "C", name: "Cancel the open clock altogether, as though you never clocked in"), .newline,
        .option(key: "j", name: "Jump to the clock to make manual adjustments"), .newline,
        .option(key: "J", name: "Clock out now, then jump to the clock"), .newline,
    ], multiple: false)

    /// What a key asks for next, if anything.
    public enum Input: Equatable, Sendable {
        /// `read-number` with the idle minutes as the default.
        case minutes(prompt: String)
        /// `org-read-date` with a time: when the user got distracted.
        case date
    }

    public static func input(for key: Character) -> Input? {
        switch key {
        case "k", "K": .minutes(prompt: "Keep how many minutes")
        case "g", "G": .minutes(prompt: "Got back how many minutes ago")
        case "t", "T": .date
        default: nil
        }
    }

    /// The default for `k` and `g`: whole minutes since `lastValid`.
    public static func defaultMinutes(lastValid: Date, now: Date) -> Int {
        Int((now.timeIntervalSince(lastValid).rounded(.down) / 60).rounded(.down))
    }

    /// `t`'s answer as minutes kept after `lastValid`.
    public static func minutes(from lastValid: Date, to date: Date) -> Int {
        Int((date.timeIntervalSince(lastValid) / 60).rounded(.down))
    }

    /// Org's error, for the echo area.
    public struct Failure: Error, Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    public enum Step: Equatable, Sendable {
        /// `org-clock-cancel` on the open clock.
        case cancel
        /// The open clock closes at this time.
        case clockOut(Date)
        /// A new clock in the same entry, starting at this time.
        case clockIn(Date)
        /// The open clock becomes the running clock (`org-clock-in` with resume).
        case resume
    }

    public struct Plan: Equatable, Sendable {
        public var steps: [Step] = []
        /// `org-clock-leftover-time` is set to this when `setsLeftover`.
        public var leftover: Date?
        public var setsLeftover = false
        /// Show the clock afterwards (`j`, `J`).
        public var jump = false
    }

    /// What `key` does to a clock that started at `start`, idle since `lastValid`.
    /// `minutes` is the answer to `input(for:)` (for `t`, `minutes(from:to:)`). `active`: the
    /// clock is the running one. `clockingIn`: resolving before a clock-in
    /// (`org-clock-clocking-in`), which never restarts or resumes. `defaultMinutes` is the
    /// default the minutes prompt offered, when there was one.
    public static func plan(
        key: Character, minutes: Int?, start: Date, lastValid: Date, now: Date, active: Bool, clockingIn: Bool, defaultMinutes: Int? = nil
    ) throws -> Plan {
        var plan = Plan()
        if key == "j" || key == "J" {
            if key == "J" { plan.steps = try resolve(.now, clockOutTime: nil, close: true, restart: false, active: active, clockingIn: clockingIn, now: now).steps }
            plan.jump = true
            return plan
        }
        guard "kKgGsSCtT".contains(key) else { return plan }
        let defaultMinutes = defaultMinutes ?? Self.defaultMinutes(lastValid: lastValid, now: now)
        let keep = "kKtT".contains(key) ? minutes : nil
        let gotback = "gG".contains(key) ? minutes : nil
        let subtract = key == "s" || key == "S"
        // `barely-started-p`: less than 45 seconds on the clock before idling.
        let startOver = subtract && lastValid.timeIntervalSince(start) < 45
        let target: Target
        if key == "C" || startOver {
            target = .cancel
        } else if subtract || gotback == 0 {
            target = .time(lastValid)
        } else if keep == defaultMinutes || gotback == defaultMinutes {
            target = .now
        } else if let keep {
            target = .time(lastValid.addingTimeInterval(Double(keep * 60)))
        } else if let gotback {
            target = .time(now.addingTimeInterval(Double(-gotback * 60)))
        } else {
            throw Failure(message: "Unexpected, please report this as a bug")
        }
        return try resolve(
            target, clockOutTime: gotback == nil ? nil : lastValid, close: "KGST".contains(key),
            restart: startOver && !"KGSC".contains(key), active: active, clockingIn: clockingIn, now: now
        )
    }

    enum Target {
        case cancel, now
        case time(Date)
    }

    /// `org-clock-resolve-clock`.
    static func resolve(_ target: Target, clockOutTime: Date?, close: Bool, restart: Bool, active: Bool, clockingIn: Bool, now: Date) throws -> Plan {
        var plan = Plan()
        switch target {
        case .cancel:
            plan.steps = [.cancel]
            if restart, !clockingIn { plan.steps.append(.clockIn(now)) }
        case .now:
            if restart { throw Failure(message: "RESTART is not valid here") }
            if close || clockingIn {
                plan.steps = [.clockOut(now)]
            } else if !active {
                plan.steps = [.resume]
            }
        case .time(let time):
            if now < time { throw Failure(message: "RESOLVE-TO must refer to a time in the past") }
            if restart { throw Failure(message: "RESTART is not valid here") }
            plan.steps = [.clockOut(clockOutTime ?? time)]
            if clockingIn {
            } else if close {
                plan.setsLeftover = true
                plan.leftover = clockOutTime == nil ? time : nil
            } else {
                plan.steps.append(.clockIn(clockOutTime == nil ? now : time))
            }
        }
        return plan
    }

    /// The time of a clock stamp (`2026-10-08 Thu 09:00`).
    public static func date(of stamp: String, calendar: Calendar = .current) -> Date? {
        EmacsBuffer.parseTimeString(stamp).flatMap { calendar.date(from: $0) }
    }

    /// `org-find-open-clocks`: each open `CLOCK:` line in `text` (in a clock element), with
    /// its start stamp and where the line starts.
    public static func openClocks(in text: String) -> [(start: String, offset: Int)] {
        guard text.contains("CLOCK:") else { return [] }
        var result: [(String, Int)] = []
        func walk(_ node: SyntaxNode) {
            for child in node.children {
                if child.kind == .clock {
                    let line = child.text.trimmingCharacters(in: .newlines)
                    if let match = line.firstMatch(of: /^[ \t]*CLOCK: \[([^\]]+)\][ \t]*$/) {
                        result.append((String(match.1), child.range.lowerBound))
                    }
                } else {
                    walk(child)
                }
            }
        }
        walk(OrgParser.parse(text).root)
        return result
    }
}
