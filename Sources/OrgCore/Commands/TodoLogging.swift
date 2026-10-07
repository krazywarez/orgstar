import Foundation

// Logging TODO state changes as `org-todo` does (Org 9.8.7): CLOSED with `org-log-done`, state
// notes for keywords with `!` and `@`, `#+STARTUP` log options, the LOGGING and
// LOG_INTO_DRAWER properties, `org-log-into-drawer`, `org-log-states-order-reversed` t and the
// default `org-log-note-headings`.

/// What `org-log-done` and the `!`/`@` keyword flags ask for.
public enum LogHow: String, Sendable, Equatable, Codable {
    case time, note
}

/// The logging in effect for one entry.
struct LogSettings {
    var done: LogHow?
    var repeatHow: LogHow?
    /// `org-log-reschedule` and `org-log-redeadline`.
    var reschedule: LogHow?
    var redeadline: LogHow?
    var drawer: String?
    /// `org-todo-log-states`: keyword → (on entering, on leaving).
    var states: [String: (enter: LogHow?, leave: LogHow?)] = [:]

    static func how(_ flag: String?) -> LogHow? {
        switch flag {
        case "!": .time
        case "@": .note
        default: nil
        }
    }

    /// Applies one word of `#+STARTUP` or of a LOGGING property.
    mutating func apply(startup word: String) {
        switch word {
        case "logdone": done = .time
        case "lognotedone": done = .note
        case "nologdone": done = nil
        case "logrepeat": repeatHow = .time
        case "lognoterepeat": repeatHow = .note
        case "nologrepeat": repeatHow = nil
        case "logreschedule": reschedule = .time
        case "lognotereschedule": reschedule = .note
        case "nologreschedule": reschedule = nil
        case "logredeadline": redeadline = .time
        case "lognoteredeadline": redeadline = .note
        case "nologredeadline": redeadline = nil
        case "logdrawer": drawer = "LOGBOOK"
        case "nologdrawer": drawer = nil
        default: break
        }
    }

    /// `org-extract-log-state-settings`: `WAIT(w@/!)`.
    static func stateSetting(_ word: String) -> (String, LogHow?, LogHow?)? {
        guard let match = word.firstMatch(of: /^(.*?)(?:\(([^!@\/])?([!@])?(?:\/([!@]))?\))?$/) else { return nil }
        let enter = how(match.3.map(String.init))
        let leave = how(match.4.map(String.init))
        guard enter != nil || leave != nil else { return nil }
        return (String(match.1), enter, leave)
    }
}

/// A note `org-add-log-setup` asked for, stored when the command ends.
struct LogSetup {
    enum Purpose { case done, state, reschedule, delschedule, redeadline, deldeadline }
    var purpose: Purpose
    var state: String?
    var previous: String?
    var how: LogHow
    var drawer: String?
}

extension EmacsBuffer {
    /// The logging settings for the entry at point.
    func logSettings() -> LogSettings {
        var log = LogSettings(done: options.logDone, repeatHow: options.logRepeat ? .time : nil,
                              reschedule: options.logReschedule, redeadline: options.logRedeadline, drawer: options.logIntoDrawer)
        for sequence in settings.todoSequences {
            for keyword in sequence.active + sequence.done {
                let enter = LogSettings.how(keyword.logOnEnter)
                let leave = LogSettings.how(keyword.logOnLeave)
                if enter != nil || leave != nil, log.states[keyword.name] == nil { log.states[keyword.name] = (enter, leave) }
            }
        }
        for (key, value) in SetupFile.keywords(settings.setupKeywords) where key == "STARTUP" {
            for word in value.split(whereSeparator: \.isWhitespace) { log.apply(startup: String(word)) }
        }
        let startup = try! NSRegularExpression(pattern: "^[ \\t]*#\\+STARTUP:(.*)$", options: [.anchorsMatchLines, .caseInsensitive])
        for match in startup.matches(in: string, range: NSRange(location: 0, length: length)) {
            for word in substring(match.range(at: 1).location, NSMaxRange(match.range(at: 1))).split(whereSeparator: \.isWhitespace) {
                log.apply(startup: String(word))
            }
        }
        if let logging = inheritedProperty("LOGGING")?.value {
            // `org-local-logging`.
            log.done = nil
            log.repeatHow = nil
            log.states = [:]
            for word in logging.split(whereSeparator: \.isWhitespace).map(String.init) {
                if ["logdone", "lognotedone", "nologdone", "logrepeat", "lognoterepeat", "nologrepeat"].contains(word) {
                    log.apply(startup: word)
                } else if let (keyword, enter, leave) = LogSettings.stateSetting(word), keywordsInOrder.contains(keyword) {
                    log.states[keyword] = (enter, leave)
                }
            }
        }
        if let drawer = inheritedProperty("LOG_INTO_DRAWER")?.value {
            log.drawer = drawer == "nil" ? nil : drawer == "t" ? "LOGBOOK" : drawer
        }
        return log
    }

    /// `org-todo`'s logging after the keyword went from `previous` to `state`: CLOSED is added
    /// or removed, and the note to take is returned.
    func todoLogging(previous: String?, state: String?, log: LogSettings) throws -> LogSetup? {
        guard log.done != nil || !log.states.isEmpty else { return nil }
        let isDone = { (k: String?) in k.map(self.settings.isDone) ?? false }
        let isNotDone = { (k: String?) in k.map { self.keywordsInOrder.contains($0) && !self.settings.isDone($0) } ?? false }
        let nowDone = isDone(state) && !isDone(previous)
        let dolog = state.flatMap { log.states[$0]?.enter } ?? previous.flatMap { log.states[$0]?.leave }
        if state == nil || (isNotDone(state) && !isNotDone(previous)) {
            try addPlanningInfo(nil, time: nil, withTime: false, endTime: nil, remove: [.closed])
        }
        var setup: LogSetup?
        if nowDone, let done = log.done {
            let time = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            try addPlanningInfo(.closed, time: time, withTime: true, endTime: nil, remove: [])
            if dolog == nil, done == .note { setup = LogSetup(purpose: .done, state: state, previous: previous, how: .note, drawer: log.drawer) }
        }
        if let state, let dolog { setup = LogSetup(purpose: .state, state: state, previous: previous, how: dolog, drawer: log.drawer) }
        return setup
    }

    /// The question a note needs.
    static func notePrompt(_ setup: LogSetup) -> Prompt {
        let about = switch setup.purpose {
        case .done: "closed todo item"
        case .state: "state change from \"\(setup.previous ?? "")\" to \"\(setup.state ?? "")\""
        case .reschedule: "rescheduling"
        case .delschedule: "no longer scheduled"
        case .redeadline: "changing deadline"
        case .deldeadline: "removing deadline"
        }
        return Prompt(key: "note", message: "Note for \(about):")
    }

    /// `org-store-log-note` for `setup` with the note's text, in the entry at point.
    func storeLog(_ setup: LogSetup, text: String) {
        func quoted(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "" }
        let stamp = formatTimestamp(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now), withTime: true, inactive: true)
        var heading = switch setup.purpose {
        case .done: "CLOSING NOTE " + stamp
        case .state:
            "State " + quoted(setup.state).padding(toLength: max(12, quoted(setup.state).count), withPad: " ", startingAt: 0)
                + " from " + quoted(setup.previous).padding(toLength: max(12, quoted(setup.previous).count), withPad: " ", startingAt: 0)
                + " " + stamp
        case .reschedule: "Rescheduled from \(Self.quotedState(setup.previous)) on \(stamp)"
        case .delschedule: "Not scheduled, was \(Self.quotedState(setup.previous)) on \(stamp)"
        case .redeadline: "New deadline from \(Self.quotedState(setup.previous)) on \(stamp)"
        case .deldeadline: "Removed deadline, was \(Self.quotedState(setup.previous)) on \(stamp)"
        }
        var trimmed = text
        while let range = trimmed.range(of: "^# .*\\n[ \\t\\n]*", options: .regularExpression) { trimmed.removeSubrange(range) }
        trimmed = trimmed.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let lines = trimmed.isEmpty ? [] : trimmed.components(separatedBy: "\n")
        if !lines.isEmpty { heading += " \\\\" }
        saveExcursion {
            point = logBeginning(drawer: setup.drawer, create: true)
            if !bolp {
                insert("\n")
            } else if lookingAt("[ \\t]*\\S") != nil {
                saveExcursion { insert("\n") }
            }
            if let item = inItem() {
                let structure = saveExcursion { point = item; return listStruct() }
                indentLineTo(structure.ind(structure.top))
            } else {
                indentLineTo(0)
            }
            let bodyColumn = currentColumn + 2
            insert("- " + heading)
            for line in lines {
                insert("\n")
                if !line.isEmpty {
                    indentLineTo(bodyColumn)
                    insert(line)
                }
            }
        }
    }

    /// What `org-todo` does after the keyword went from `previous` to the current one: CLOSED,
    /// the repeat of a repeating entry, and the log note, asking for its text with `answers`.
    func afterTodoChange(previous: String?, answers: [String: String]) throws {
        let state = todoKeyword
        guard state != previous else { return }
        let log = logSettings()
        var setup = try saveExcursion { try todoLogging(previous: previous, state: state, log: log) }
        if let state, settings.isDone(state), !(previous.map(settings.isDone) ?? false),
           let repeatSetup = try autoRepeat(doneWord: state, previous: previous, log: log) {
            if setup == nil { setup = repeatSetup } else if repeatSetup.how == .note { setup?.how = .note }
        }
        guard let setup else { return }
        if setup.how == .note {
            guard let note = answers["note"] else { throw Ask(prompt: Self.notePrompt(setup)) }
            storeLog(setup, text: note)
        } else {
            storeLog(setup, text: "")
        }
    }

    /// `%S` in `org-log-note-headings`: a timestamp as an inactive one, in quotes.
    static func quotedState(_ s: String?) -> String {
        guard let s else { return "" }
        if s.range(of: "^[\\[<][0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) != nil {
            return "\"[" + s.dropFirst().dropLast() + "]\""
        }
        return "\"" + s + "\""
    }

    /// The note `org--deadline-or-schedule` logs when a planning date changes or goes, with
    /// `org-log-reschedule` and `org-log-redeadline`; asks for its text with `answers`.
    func logPlanningChange(_ kind: PlanningKind, old: String, new: String?, answers: [String: String]) throws {
        let log = logSettings()
        guard let how = kind == .deadline ? log.redeadline : log.reschedule else { return }
        if let new, new == old { return }
        let purpose: LogSetup.Purpose = switch (kind == .deadline, new == nil) {
        case (true, true): .deldeadline
        case (true, false): .redeadline
        case (false, true): .delschedule
        case (false, false): .reschedule
        }
        let setup = LogSetup(purpose: purpose, state: new, previous: old, how: how, drawer: log.drawer)
        if how == .note {
            guard let note = answers["note"] else { throw Ask(prompt: Self.notePrompt(setup)) }
            storeLog(setup, text: note)
        } else {
            storeLog(setup, text: "")
        }
    }
}
