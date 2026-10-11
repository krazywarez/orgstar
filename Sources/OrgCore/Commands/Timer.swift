import Foundation

/// org-timer (org-timer.el, Org 9.8.7): a relative timer counting up from a start time, or a
/// countdown counting down to one. The app keeps the timer and gives it to commands in
/// `EditingOptions.timer`; commands that change it return `Effect.timer`.
public struct OrgTimer: Sendable, Equatable, Codable {
    /// `org-timer-start-time`: when a relative timer read 0:00:00, or when a countdown ends.
    public var start: Date
    /// `org-timer-pause-time`.
    public var paused: Date?
    /// A countdown rather than a relative timer.
    public var isCountdown: Bool
    /// A countdown's title (`org-timer-countdown-timer-title`): its heading, or nil.
    public var title: String?

    public init(start: Date, paused: Date? = nil, isCountdown: Bool = false, title: String? = nil) {
        self.start = start
        self.paused = paused
        self.isCountdown = isCountdown
        self.title = title
    }

    /// The timer's seconds: counted up, or left for a countdown.
    public func seconds(now: Date) -> Int {
        let time = (paused ?? now).timeIntervalSince1970 - start.timeIntervalSince1970
        return abs(Int((isCountdown ? -time : time).rounded(.down)))
    }

    /// `org-timer-value-string`.
    public func value(now: Date, format: String = "%s ") -> String {
        format.replacingOccurrences(of: "%s", with: Self.hms(seconds(now: now)))
    }

    /// The mode line's ` <0:01:23>`.
    public func modeLine(now: Date, format: String = "%s ") -> String {
        " <" + String(value(now: now, format: format).dropLast()) + ">"
    }

    /// The countdown's notification text when it ends.
    public var doneMessage: String { "\(title ?? "nil"): time out" }

    /// `org-timer-secs-to-hms`.
    public static func hms(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : ""
        let s = abs(seconds)
        return String(format: "%@%d:%02d:%02d", sign, s / 3600, s / 60 % 60, s % 60)
    }

    /// `org-timer-hms-to-secs`: 0 when it isn't h:mm:ss.
    public static func seconds(_ hms: String) -> Int {
        guard let m = hms.firstMatch(of: /([-+]?[0-9]+):([0-9]{2}):([0-9]{2})/) else { return 0 }
        let total = abs(Int(m.1)!) * 3600 + Int(m.2)! * 60 + Int(m.3)!
        return m.1.hasPrefix("-") ? -total : total
    }

    /// `org-timer-fix-incomplete`: `5` is 0:00:05 and `2:30` is 0:02:30.
    public static func fixIncomplete(_ hms: String) -> String? {
        guard let m = hms.firstMatch(of: /(?:([0-9]+:)?([0-9]+:))?([0-9]+)/) else { return nil }
        let h = m.1.map { Int($0.dropLast())! } ?? 0
        let mm = m.2.map { Int($0.dropLast())! } ?? 0
        let replaced = String(format: "%d:%02d:%02d", h, mm, Int(m.3)!)
        return hms.replacingCharacters(in: m.range, with: replaced)
    }
}

extension Effect {
    static func timerMessage(_ timer: OrgTimer?, _ message: String) -> [Effect] { [.timer(timer), .message(message)] }
}

/// The timer the context's options hold.
private func timer(_ context: EditContext) -> OrgTimer? { context.options.timer }

private func effects(_ context: EditContext, _ effects: [Effect]) -> CommandStep {
    .commit(EditResult(baseRevision: context.revision, edits: [], effects: effects))
}

/// C-c C-x 0: `org-timer-start`, from 0:00:00, or with `offset` (C-u C-c C-x 0) from an
/// offset asked for, defaulting to a timer stamp at point.
public struct TimerStart: OrgCommand {
    public let offset: Bool
    public init(offset: Bool = false) { self.offset = offset }
    public var id: String { offset ? "org.timer.start-offset" : "org.timer.start" }
    public var title: String { offset ? "Start Timer with Offset…" : "Start Timer" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        if timer(context)?.isCountdown == true { return .failed("Countdown timer is running.  Cancel first") }
        var delta = 0
        if offset {
            let line = (context.text as NSString).lineRange(for: NSRange(location: min(context.caret, (context.text as NSString).length), length: 0))
            let lineText = (context.text as NSString).substring(with: line)
            let caretInLine = context.caret - line.location
            let atPoint = lineText.matches(of: /([-+]?[0-9]+):([0-9]{2}):([0-9]{2})/).first { m in
                let start = lineText.utf16.distance(from: lineText.startIndex, to: m.range.lowerBound)
                let end = lineText.utf16.distance(from: lineText.startIndex, to: m.range.upperBound)
                return start <= caretInLine && caretInLine <= end
            }.map { String(lineText[$0.range]) }
            let def = atPoint ?? "0:00:00"
            guard let answer = context.answers["offset"] else {
                return .prompt(Prompt(key: "offset", message: "Restart timer with offset [\(def)]: ", requireMatch: false))
            }
            let typed = answer.contains(where: { !$0.isWhitespace }) ? answer : def
            guard let fixed = OrgTimer.fixIncomplete(typed) else { return .failed("Cannot parse HMS string \"\(typed)\"") }
            delta = OrgTimer.seconds(fixed)
        }
        let start = context.now.addingTimeInterval(-Double(delta))
        return effects(context, Effect.timerMessage(OrgTimer(start: start), Self.message(start, delta, context)))
    }

    /// What `org-timer-start` says.
    static func message(_ start: Date, _ delta: Int, _ context: EditContext) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        clock.timeZone = context.calendar.timeZone
        return "Timer start time set to \(clock.string(from: start)), current value is \(OrgTimer.hms(delta))"
    }
}

/// C-c C-x ,: `org-timer-pause-or-continue`.
public struct TimerPauseOrContinue: OrgCommand {
    public init() {}
    public var id: String { "org.timer.pause" }
    public var title: String { "Pause or Continue Timer" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        guard var current = timer(context) else { return .failed("No timer is running") }
        let format = context.options.timerFormat
        if let paused = current.paused {
            let elapsed = paused.timeIntervalSince(current.start)
            // A countdown runs again for what was left; a relative timer goes on from its value.
            current.start = context.now.addingTimeInterval(-elapsed)
            current.paused = nil
            return effects(context, Effect.timerMessage(current, "Timer continues at \(current.value(now: context.now, format: format))"))
        }
        current.paused = context.now
        return effects(context, Effect.timerMessage(current, "Timer paused at \(current.value(now: context.now, format: format))"))
    }
}

/// C-c C-x _: `org-timer-stop`.
public struct TimerStop: OrgCommand {
    public init() {}
    public var id: String { "org.timer.stop" }
    public var title: String { "Stop Timer" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        guard timer(context) != nil else { return .failed("No timer running") }
        return effects(context, Effect.timerMessage(nil, "Timer stopped"))
    }
}

/// C-c C-x .: `org-timer`, the timer's value at point, starting a relative timer first when
/// none is running.
public struct InsertTimer: OrgCommand {
    public init() {}
    public var id: String { "org.timer.insert" }
    public var title: String { "Insert Timer Value" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        let (current, started) = Self.timer(context)
        let value = current.value(now: context.now, format: context.options.timerFormat)
        let end = context.caret + (value as NSString).length
        return .commit(EditResult(baseRevision: context.revision, edits: [TextEdit(range: context.caret..<context.caret, replacement: value)],
                                  selection: [end..<end], effects: started ? Self.started(current, context) : []))
    }

    static func started(_ timer: OrgTimer, _ context: EditContext) -> [Effect] {
        Effect.timerMessage(timer, TimerStart.message(timer.start, 0, context))
    }

    /// The running timer, or a new one started now.
    static func timer(_ context: EditContext) -> (OrgTimer, started: Bool) {
        if let current = context.options.timer { return (current, false) }
        return (OrgTimer(start: context.now), true)
    }
}

/// C-c C-x -: `org-timer-item`, a description item with the timer's value: a new item in a
/// timer list, or a new list.
public struct InsertTimerItem: OrgCommand {
    public init() {}
    public var id: String { "org.timer.item" }
    public var title: String { "Insert Timer Item" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        let (current, started) = InsertTimer.timer(context)
        let value = current.value(now: context.now, format: context.options.timerFormat)
        let step = commitBuffer(context) { try $0.timerItem(value) }
        guard started, case .commit(let result) = step else { return step }
        return .commit(EditResult(baseRevision: result.baseRevision, edits: result.edits, selection: result.selection, effects: result.effects + InsertTimer.started(current, context)))
    }
}

/// C-c C-x ;: `org-timer-set-timer`, a countdown for the entry's Effort, or for a time asked
/// for.
public struct TimerSetCountdown: OrgCommand {
    public init() {}
    public var id: String { "org.timer.set" }
    public var title: String { "Set Countdown Timer…" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        let current = timer(context)
        if let current, !current.isCountdown { return .failed("Relative timer is running.  Stop first") }
        let model = DocumentModel(tree: context.tree)
        let heading = model.headings.lastIndex { $0.headingRange.lowerBound <= context.caret }
        var minutes: String
        if let heading, let effort = model.property("Effort", of: heading)?.value, effort.contains(where: { !$0.isWhitespace }),
           let value = ColumnView.minutes(effort) {
            minutes = String(Int(value.rounded(.down)))
        } else {
            let fallback = context.options.timerDefault
            guard let answer = context.answers["minutes"] else {
                return .prompt(Prompt(key: "minutes", message: "How much time left? (minutes or h:mm:ss) ", initial: fallback == "0" ? "" : fallback, requireMatch: false))
            }
            minutes = answer
        }
        if minutes.wholeMatch(of: /[0-9]+/) != nil { minutes += ":00" }
        guard minutes.contains(where: \.isNumber) else { return TimerShowRemaining().run(in: context) }
        if current != nil {
            guard let replace = context.answers["replace"] else {
                return .prompt(Prompt(key: "replace", message: "Replace current timer? (y or n) ", choices: ["y", "n"]))
            }
            if replace != "y" { return effects(context, [.message("No timer set")]) }
        }
        guard let fixed = OrgTimer.fixIncomplete(minutes) else { return .failed("Cannot parse HMS string \"\(minutes)\"") }
        let seconds = OrgTimer.seconds(fixed)
        // `org-get-heading`, which fails before the first heading.
        let title: String? = heading == nil ? nil : EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).orgGetHeading()
        return effects(context, [.timer(OrgTimer(start: context.now.addingTimeInterval(Double(seconds)), isCountdown: true, title: title))])
    }
}

/// `org-timer-show-remaining-time`.
public struct TimerShowRemaining: OrgCommand {
    public init() {}
    public var id: String { "org.timer.show-remaining" }
    public var title: String { "Show Remaining Countdown Time" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        guard let current = timer(context), current.isCountdown else { return effects(context, [.message("No timer set")]) }
        let left = Int(((current.paused ?? context.now).distance(to: current.start)).rounded(.down))
        return effects(context, [.message("\(left / 60) minute(s) \(left % 60) seconds left before next time out")])
    }
}

/// C-u C-u C-c C-x 0: `org-timer-change-times-in-region`, every h:mm:ss in the region moved by
/// a difference asked for, by default the one that makes the first 0:00:00.
public struct TimerChangeTimes: OrgCommand {
    public init() {}
    public var id: String { "org.timer.change-times" }
    public var title: String { "Shift Timer Values in Region…" }
    public func applies(in context: EditContext) -> Bool { context.selection.first.map { !$0.isEmpty } ?? false }

    public func run(in context: EditContext) -> CommandStep {
        guard let region = context.selection.first, !region.isEmpty else { return .failed("The mark is not set now, so there is no region") }
        guard var delta = context.answers["delta"] else {
            return .prompt(Prompt(key: "delta", message: "Enter time difference like \"-1:08:26\".  Default is first time to zero: ", requireMatch: false))
        }
        let pattern = try! NSRegularExpression(pattern: "[-+]?[0-9]+:[0-9]{2}:[0-9]{2}")
        let first = pattern.firstMatch(in: context.text, range: NSRange(region))
        if !delta.contains(where: { !$0.isWhitespace }), let first {
            let stamp = (context.text as NSString).substring(with: first.range)
            delta = stamp.hasPrefix("-") ? String(stamp.dropFirst()) : "-" + stamp
        }
        guard let fixed = OrgTimer.fixIncomplete(delta) else { return .failed("Cannot parse HMS string \"\(delta)\"") }
        let seconds = OrgTimer.seconds(fixed)
        guard seconds != 0 else { return .failed("No change") }
        // `re-search-backward` from the region's end: the match starting nearest before the
        // position and ending by it, so `0:00:00` inside `10:00:00` is found first.
        let text = NSMutableString(string: context.text)
        var position = region.upperBound
        while position > region.lowerBound {
            var found: NSRange?
            var start = position - 1
            while start >= region.lowerBound, found == nil {
                found = pattern.firstMatch(in: text as String, options: .anchored, range: NSRange(location: start, length: position - start))?.range
                start -= 1
            }
            guard let match = found else { break }
            text.replaceCharacters(in: match, with: OrgTimer.hms(OrgTimer.seconds(text.substring(with: match)) + seconds))
            position = match.location
        }
        let edits = TextEdit.between(context.text, text as String)
        return .commit(EditResult(baseRevision: context.revision, edits: edits))
    }
}

extension EmacsBuffer {
    /// Whether the item at the caret starts with a timer, as `org-insert-item` checks.
    static func atTimerList(_ context: EditContext) -> Bool {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
        guard let item = buffer.inItem() else { return false }
        buffer.point = item
        return buffer.atTimerItem
    }

    /// `org-at-item-timer-p`.
    var atTimerItem: Bool {
        saveExcursion {
            beginningOfLine()
            guard let match = looking(itemPattern) else { return false }
            point = match[0]!.upperBound
            // `org-list-at-regexp-after-bullet-p`: past a counter, not a checkbox.
            let counter = options.listAllowAlphabetical ? "(?:\\[@(?:start:)?([0-9]+|[A-Za-z])\\][ \\t]*)?" : "(?:\\[@(?:start:)?[0-9]+\\][ \\t]*)?"
            return looking(counter + "([0-9]+:[0-9]+:[0-9]+)[ \\t]+::[ \\t]+") != nil
        }
    }

    /// `org-timer-item` with the timer's `value`.
    func timerItem(_ value: String) throws {
        let pos = point
        if let item = inItem() {
            point = item
            guard atTimerItem else {
                point = pos
                throw UserError(message: "This is not a timer list")
            }
            var structure = listStruct()
            structure = insertItem(at: pos, structure, structure.prevs, checkbox: false, afterBullet: value + ":: ", splitLine: options.metaReturnMaySplitLine)
            writeStruct(&structure, structure.parents)
            beginningOfLine()
            if let match = looking(Self.fullItemPattern) { point = match[0]!.upperBound }
            return
        }
        // `org-indent-line` outside a list, with `org-adapt-indentation` nil: as the line
        // above that isn't blank, or at column 0 after a heading or at the start.
        let column = saveExcursion { () -> Int in
            beginningOfLine()
            skipBackward([32, 9, 10, 13])
            guard point > 0 else { return 0 }
            beginningOfLine()
            return atHeading ? 0 : currentTextIndentation
        }
        indentLineTo(column)
        insert("- " + value + ":: ")
    }
}
