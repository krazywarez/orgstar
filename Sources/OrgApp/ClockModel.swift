import Foundation
import Observation
import OrgCore

/// The running clock and the clock history, kept across launches as Org keeps them with
/// `org-clock-persist`, and the commands that start, stop and resolve clocks.
@MainActor
@Observable
public final class ClockModel {
    public struct Running: Codable, Equatable, Sendable {
        public let path: String
        /// The stamp in `CLOCK: [start]`.
        public let start: String
        public let heading: String
        public let startedAt: Date
    }

    /// An open `CLOCK:` line: the running clock, or one left dangling.
    public struct OpenClock: Equatable, Sendable {
        public let path: String
        public let start: String
        public let startedAt: Date
        public let heading: String
    }

    /// What a question about a clock led to: messages, and where to look (`j`).
    public struct Outcome {
        public var messages: [String] = []
        public var jump: (path: String, offset: Int)?
    }

    /// Asks a question in the echo area or a sheet; nil when it is cancelled.
    public typealias Ask = @MainActor (Prompt) async -> String?

    private struct Saved: Codable {
        var running: Running?
        var history: [ClockTask]
    }

    public private(set) var running: Running?
    /// `org-clock-history`, most recent first.
    public private(set) var history: [ClockTask] = []
    /// `org-clock-default-task`, for the session.
    public private(set) var defaultTask: ClockTask?
    /// `org-clock-interrupted-task`.
    public private(set) var interruptedTask: ClockTask?
    /// `org-clock-leftover-time`: where a clock resolved with `K`, `S` or `T` stopped.
    public private(set) var leftover: Date?
    /// A clock question is open (`org-clock-resolving-clocks`).
    public private(set) var isResolving = false
    private let file: URL
    private let defaults: UserDefaults

    public init(file: URL = WorkspaceModel.defaultDirectory.appendingPathComponent("clock.json"), defaults: UserDefaults = .standard) {
        self.file = file
        self.defaults = defaults
        guard let data = try? Data(contentsOf: file) else { return }
        if let running = try? JSONDecoder().decode(Running.self, from: data) {
            self.running = running
        } else if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            running = saved.running
            history = saved.history
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if running != nil || !history.isEmpty, let data = try? JSONEncoder().encode(Saved(running: running, history: history)) {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Clocking in and out

    /// `org-clock-in` at the heading under the caret, clocking out a running clock first.
    public func clockIn(_ session: DocumentSession, now: Date = Date()) -> String {
        guard let path = session.path, session.document != nil else { return "No file is open." }
        return clockIn(session, path: path, at: session.caret, now: now)
    }

    /// `org-clock-in` at the heading containing `offset` in `path`.
    public func clockIn(_ session: DocumentSession, path: String, at offset: Int, now: Date = Date()) -> String {
        guard let text = Self.text(path, session) else { return "Can't read \(path)" }
        let headings = DocumentModel(tree: OrgParser.parse(text)).headings
        guard let index = headings.lastIndex(where: { $0.headingRange.lowerBound <= offset }) else { return "Before first headline" }
        let entry = headings[index]
        var offset = offset
        var heading = entry.headingRange.lowerBound
        if let running {
            if isRunning(path: path, heading: heading, session) { return "Clock continues in \"\(running.heading)\"" }
            let interrupted = runningTask(session)
            let message = clockOut(session, now: now)
            if self.running != nil { return message }
            interruptedTask = interrupted
            // Clocking out may have moved the entry.
            let target = ClockTask(path: path, title: entry.title, ordinal: index, id: entry.id)
            guard let moved = Self.text(path, session).flatMap(target.locate) else { return "Can't find \(entry.title) after clocking out." }
            offset += moved - heading
            heading = moved
        } else {
            interruptedTask = nil
        }
        switch session.perform(ClockIn(), path: path, at: offset, expect: nil, now: now) {
        case .commit:
            guard let updated = Self.text(path, session), let start = ClockIn.runningStart(in: updated, near: heading) else {
                return "The clock line wasn't found after clocking in."
            }
            running = Running(path: path, start: start, heading: entry.title, startedAt: now)
            if let task = ClockTask.at(heading, in: updated, path: path) { push(task, session) }
            save()
            return "Clock starts at [\(start)]"
        case .failed(let message):
            return message
        default:
            return "Can't clock in here."
        }
    }

    /// `org-clock-out`, or `org-clock-cancel` with `cancel`.
    public func clockOut(_ session: DocumentSession, cancel: Bool = false, now: Date = Date()) -> String {
        guard let clock = running else { return "No active clock" }
        switch session.perform(ClockOut(start: clock.start, cancel: cancel), path: clock.path, at: 0, expect: nil, now: now) {
        case .commit:
            running = nil
            save()
            if cancel { return "Clock canceled" }
            let minutes = Int(now.timeIntervalSince(clock.startedAt) / 60)
            return String(format: "Clock stopped after %d:%02d", minutes / 60, minutes % 60)
        case .failed(let message):
            if message == "Clock start time is gone" || message == "No active clock" {
                running = nil
                save()
            }
            return message
        default:
            return "Can't clock out."
        }
    }

    /// A template's `clock-in` once its entry is filed: clocked from when capture began and,
    /// without `clock-keep`, clocked out now, the clock it interrupted resuming with
    /// `clock-resume`. The messages, in order.
    public func captured(
        _ entry: (path: String, offset: Int), options: CaptureTemplate.Options, session: DocumentSession, opened: Date, now: Date = Date()
    ) -> [String] {
        guard options.clockIn else { return [] }
        let previous = self.entry(session)
        var messages = [clockIn(session, path: entry.path, at: entry.offset, now: opened)]
        if !options.clockKeep {
            messages.append(clockOut(session, now: now))
            if options.clockResume, let previous {
                messages.append(clockIn(session, path: previous.path, at: previous.offset, now: now))
            }
        }
        return messages
    }

    static func text(_ path: String, _ session: DocumentSession) -> String? {
        session.openDocuments.first { $0.path == path }?.document.text ?? (try? String(contentsOfFile: path, encoding: .utf8))
    }

    /// The clocked entry's heading, for the `clock` capture target.
    public func entry(_ session: DocumentSession) -> (path: String, offset: Int)? {
        guard let line = location(session), let text = Self.text(line.path, session) else { return nil }
        let heading = DocumentModel(tree: OrgParser.parse(text)).headings.last { $0.headingRange.lowerBound <= line.offset }
        return heading.map { (line.path, $0.headingRange.lowerBound) }
    }

    /// Where the running clock's line is, for `org-clock-goto`.
    public func location(_ session: DocumentSession) -> (path: String, offset: Int)? {
        guard let clock = running else { return nil }
        return lineLocation(path: clock.path, start: clock.start, session)
    }

    private func lineLocation(path: String, start: String, _ session: DocumentSession) -> (path: String, offset: Int)? {
        guard let text = Self.text(path, session) else { return nil }
        let range = (text as NSString).range(of: "CLOCK: [\(start)]")
        return range.location == NSNotFound ? (path, 0) : (path, range.location)
    }

    /// The running clock's entry.
    private func runningTask(_ session: DocumentSession) -> ClockTask? {
        guard let line = location(session), let text = Self.text(line.path, session) else { return nil }
        return ClockTask.at(line.offset, in: text, path: line.path)
    }

    private func isRunning(path: String, heading: Int, _ session: DocumentSession) -> Bool {
        guard running?.path == path, let current = entry(session) else { return false }
        return current.offset == heading
    }

    // MARK: - History

    private func push(_ task: ClockTask, _ session: DocumentSession) {
        history = ClockHistory.push(task, onto: history, length: OrgPreferences.clockHistoryLength(defaults)) { Self.text($0, session) }
    }

    /// Where a remembered entry's heading is now.
    public func locate(_ task: ClockTask, _ session: DocumentSession) -> (path: String, offset: Int)? {
        Self.text(task.path, session).flatMap { task.locate(in: $0) }.map { (task.path, $0) }
    }

    /// `org-clock-mark-default-task` for the heading under the caret.
    public func markDefault(_ session: DocumentSession) -> String {
        guard let path = session.path, session.document != nil else { return "No file is open." }
        return markDefault(session, path: path, at: session.caret)
    }

    /// `org-clock-mark-default-task` for the heading containing `offset` in `path`.
    public func markDefault(_ session: DocumentSession, path: String, at offset: Int) -> String {
        guard let text = Self.text(path, session) else { return "Can't read \(path)" }
        guard let task = ClockTask.at(offset, in: text, path: path) else { return "Before first headline" }
        defaultTask = task
        return "Default clock task: \(task.title)"
    }

    /// `org-clock-select-task`'s entries, or nil with no recent clock.
    public func selection(_ session: DocumentSession) -> [ClockHistory.Choice]? {
        ClockHistory.selection(
            defaultTask: defaultTask, interrupted: interruptedTask, current: running == nil ? nil : runningTask(session), history: history
        ) { Self.text($0, session) }
    }

    /// `org-clock-select-task`: the chosen entry, nil when the question is left with `q`,
    /// `x` or Escape, or an error message.
    public func chooseTask(_ session: DocumentSession, prompt: String, ask: Ask) async -> Result<ClockTask?, ClockResolution.Failure> {
        guard let choices = selection(session) else { return .failure(.init(message: "No recent clock")) }
        guard let answer = await ask(Prompt(key: "clock-task", message: prompt, fast: ClockHistory.fastSelection(choices))),
              let key = answer.first, key != "q", key != "x" else { return .success(nil) }
        guard let choice = choices.first(where: { $0.key == key }) else { return .failure(.init(message: "Invalid task choice \(key)")) }
        return .success(choice.task)
    }

    /// `org-clock-goto`: the running clock, else the most recent entry clocked.
    public func goto(_ session: DocumentSession) -> (location: (path: String, offset: Int)?, message: String?) {
        if let location = location(session) { return (location, nil) }
        if let recent = history.first, let location = locate(recent, session) {
            return (location, "No running clock, this is the most recently clocked task")
        }
        return (nil, "No active or recent clock task")
    }

    /// `org-clock-goto` with a prefix argument: an entry from the selection.
    public func gotoRecent(_ session: DocumentSession, ask: Ask) async -> (location: (path: String, offset: Int)?, message: String?) {
        switch await chooseTask(session, prompt: "Select task to go to: ", ask: ask) {
        case .failure(let failure): return (nil, failure.message)
        case .success(nil): return (nil, "No task selected")
        case .success(let task?):
            guard let location = locate(task, session) else { return (nil, "\(task.title) isn't in \((task.path as NSString).lastPathComponent) any more") }
            return (location, nil)
        }
    }

    // MARK: - Clocking in with questions

    /// Where an interactive clock-in goes.
    public enum Target {
        /// The heading under the caret (`org-clock-in`).
        case caret
        /// An entry chosen from the selection (`org-clock-in` with a prefix argument).
        case select
        /// The most recent entry (`org-clock-in-last`).
        case last
        /// A remembered entry.
        case task(ClockTask)
    }

    /// `org-clock-in` as a command: dangling clocks in `paths` are resolved first when no
    /// clock runs (`org-clock-auto-clock-resolution` `when-no-clock-is-running`), and a clock
    /// stopped with `K`, `S` or `T` offers its time as the start.
    public func clockIn(_ session: DocumentSession, target: Target, paths: [String], ask: Ask, now: () -> Date = Date.init) async -> Outcome {
        var outcome = Outcome()
        if case .last = target, history.isEmpty {
            outcome.messages.append("No last clock")
            return outcome
        }
        let wasRunning = running != nil
        let stopped = leftover
        if !wasRunning {
            leftover = nil
            for clock in openClocks(session, paths: paths) {
                let minutes = Int(now().timeIntervalSince(clock.startedAt) / 60)
                let result = await resolve(
                    clock, description: "Dangling clock started \(minutes) mins ago", lastValid: clock.startedAt, clockingIn: true, session, ask: ask, now: now
                )
                outcome.messages += result.messages
            }
        }
        let location: (path: String, offset: Int)
        switch target {
        case .caret:
            guard let path = session.path, session.document != nil else {
                outcome.messages.append("No file is open.")
                return outcome
            }
            location = (path, session.caret)
        case .select:
            switch await chooseTask(session, prompt: "Clock-in on task: ", ask: ask) {
            case .failure(let failure):
                outcome.messages.append(failure.message)
                return outcome
            case .success(nil):
                outcome.messages.append("Abort")
                return outcome
            case .success(let task?):
                guard let found = locate(task, session) else {
                    outcome.messages.append("\(task.title) isn't in \((task.path as NSString).lastPathComponent) any more")
                    return outcome
                }
                location = found
            }
        case .last, .task:
            let task: ClockTask
            if case .task(let chosen) = target { task = chosen } else { task = history[0] }
            guard let found = locate(task, session) else {
                outcome.messages.append("\(task.title) isn't in \((task.path as NSString).lastPathComponent) any more")
                return outcome
            }
            location = found
        }
        var start = now()
        if let stopped, !isRunning(path: location.path, heading: headingStart(location, session) ?? -1, session) {
            let minutes = Int(start.timeIntervalSince(stopped) / 60)
            let answer = await ask(Prompt(
                key: "clock-leftover", message: "You stopped another clock \(minutes) mins ago; start this one from then? (y or n) ",
                fast: FastSelection(items: [.option(key: "y", name: "yes"), .option(key: "n", name: "no")], multiple: false)
            ))
            if answer == "y" { start = stopped }
        }
        let message = clockIn(session, path: location.path, at: location.offset, now: start)
        if case .last = target, !wasRunning, let running {
            outcome.messages.append("Clocking back: \(running.heading) (in \((running.path as NSString).lastPathComponent))")
        } else {
            outcome.messages.append(message)
        }
        return outcome
    }

    private func headingStart(_ location: (path: String, offset: Int), _ session: DocumentSession) -> Int? {
        guard let text = Self.text(location.path, session) else { return nil }
        return DocumentModel(tree: OrgParser.parse(text)).headings.last { $0.headingRange.lowerBound <= location.offset }?.headingRange.lowerBound
    }

    // MARK: - Resolving clocks

    /// `org-find-open-clocks` over `paths` and the open org buffers.
    public func openClocks(_ session: DocumentSession, paths: [String]) -> [OpenClock] {
        // A file open under another spelling of its path is read from its buffer.
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        var open: [String: String] = [:]
        for document in session.openDocuments { open[resolved(document.path)] = document.path }
        var seen = Set<String>()
        let all = (session.openDocuments.map(\.path).filter { $0.hasSuffix(".org") } + paths.map { open[resolved($0)] ?? $0 })
            .filter { seen.insert(resolved($0)).inserted }
        var clocks: [OpenClock] = []
        for path in all {
            guard let text = Self.text(path, session), text.contains("CLOCK: [") else { continue }
            let open = ClockResolution.openClocks(in: text)
            guard !open.isEmpty else { continue }
            let headings = DocumentModel(tree: OrgParser.parse(text)).headings
            for clock in open {
                guard let startedAt = ClockResolution.date(of: clock.start) else { continue }
                let heading = headings.last { $0.headingRange.lowerBound <= clock.offset }?.title ?? ""
                clocks.append(OpenClock(path: path, start: clock.start, startedAt: startedAt, heading: heading))
            }
        }
        return clocks
    }

    private func isActive(_ clock: OpenClock) -> Bool {
        running?.path == clock.path && running?.start == clock.start
    }

    /// `org-resolve-clocks`: every open clock in `paths`, the running one included.
    public func resolveOpenClocks(_ session: DocumentSession, paths: [String], ask: Ask, now: () -> Date = Date.init) async -> Outcome {
        var outcome = Outcome()
        let clocks = openClocks(session, paths: paths)
        guard !clocks.isEmpty else {
            outcome.messages.append("No open clocks")
            return outcome
        }
        for clock in clocks {
            let minutes = Int(now().timeIntervalSince(clock.startedAt) / 60)
            let result = await resolve(
                clock, description: "Dangling clock started \(minutes) mins ago", lastValid: clock.startedAt, clockingIn: false, session, ask: ask, now: now
            )
            outcome.messages += result.messages
            if let jump = result.jump { outcome.jump = jump }
        }
        return outcome
    }

    /// `org-resolve-clocks-if-idle`: the running clock after the user was idle since `idleSince`.
    public func resolveIdle(_ session: DocumentSession, idleSince: Date, ask: Ask, now: () -> Date = Date.init) async -> Outcome {
        guard let running, !isResolving else { return Outcome() }
        let clock = OpenClock(path: running.path, start: running.start, startedAt: running.startedAt, heading: running.heading)
        let minutes = now().timeIntervalSince(idleSince) / 60
        return await resolve(
            clock, description: String(format: "Clocked in & idle for %.1f mins", minutes), lastValid: idleSince, clockingIn: false, session, ask: ask, now: now
        )
    }

    /// `org-clock-resolve`: asks what to do with `clock`'s time since `lastValid` and does it.
    func resolve(
        _ clock: OpenClock, description: String, lastValid: Date, clockingIn: Bool, _ session: DocumentSession, ask: Ask, now: () -> Date
    ) async -> Outcome {
        var outcome = Outcome()
        // An earlier answer may have closed it.
        guard let text = Self.text(clock.path, session), ClockResolution.openClocks(in: text).contains(where: { $0.start == clock.start }) else {
            return outcome
        }
        isResolving = true
        defer { isResolving = false }
        var key: Character = "q"
        while true {
            guard let answer = await ask(Prompt(key: "clock-resolve", message: description + ClockResolution.keyHint, fast: ClockResolution.menu)) else {
                return outcome
            }
            if let c = answer.first, ClockResolution.keys.contains(c) {
                key = c
                break
            }
        }
        var minutes: Int?
        var defaultMinutes: Int?
        switch ClockResolution.input(for: key) {
        case .minutes(let prompt):
            let fallback = ClockResolution.defaultMinutes(lastValid: lastValid, now: now())
            defaultMinutes = fallback
            while minutes == nil {
                guard let answer = await ask(Prompt(key: "clock-minutes", message: "\(prompt) (default \(fallback)): ")) else { return outcome }
                let trimmed = answer.trimmingCharacters(in: .whitespaces)
                minutes = trimmed.isEmpty ? fallback : Int(trimmed)
            }
        case .date:
            guard let answer = await ask(Prompt(key: "clock-date", message: "Date+time: ", date: .init(defaultDate: nil))) else { return outcome }
            let calendar = Calendar.current
            let read = ReadDate.read(answer, default: nil, now: now(), calendar: calendar)
            guard let date = calendar.date(from: read.components(calendar)) else { return outcome }
            minutes = ClockResolution.minutes(from: lastValid, to: date)
            defaultMinutes = ClockResolution.defaultMinutes(lastValid: lastValid, now: now())
        case nil:
            break
        }
        let plan: ClockResolution.Plan
        do {
            plan = try ClockResolution.plan(
                key: key, minutes: minutes, start: clock.startedAt, lastValid: lastValid, now: now(), active: isActive(clock),
                clockingIn: clockingIn, defaultMinutes: defaultMinutes
            )
        } catch {
            outcome.messages.append((error as? ClockResolution.Failure)?.message ?? "\(error)")
            return outcome
        }
        outcome.messages = apply(plan, to: clock, session)
        if plan.jump { outcome.jump = lineLocation(path: clock.path, start: clock.start, session) }
        return outcome
    }

    /// Carries out `plan` on `clock`'s line.
    func apply(_ plan: ClockResolution.Plan, to clock: OpenClock, _ session: DocumentSession) -> [String] {
        var messages: [String] = []
        let active = isActive(clock)
        let task = lineLocation(path: clock.path, start: clock.start, session).flatMap { line in
            Self.text(clock.path, session).flatMap { ClockTask.at(line.offset, in: $0, path: clock.path) }
        }
        for step in plan.steps {
            switch step {
            case .cancel:
                if active {
                    messages.append(clockOut(session, cancel: true))
                } else {
                    messages.append(perform(ClockOut(start: clock.start, cancel: true), clock, session, now: Date()) ?? "Clock canceled")
                }
            case .clockOut(let time):
                if active {
                    messages.append(clockOut(session, now: time))
                } else {
                    let minutes = Int(time.timeIntervalSince(clock.startedAt) / 60)
                    messages.append(perform(ClockOut(start: clock.start), clock, session, now: time)
                        ?? String(format: "Clock stopped after %d:%02d", minutes / 60, minutes % 60))
                }
            case .clockIn(let time):
                guard let task, let location = locate(task, session) else { continue }
                messages.append(clockIn(session, path: location.path, at: location.offset, now: time))
            case .resume:
                if running != nil { messages.append(clockOut(session, now: Date())) }
                running = Running(path: clock.path, start: clock.start, heading: clock.heading, startedAt: clock.startedAt)
                if let task { push(task, session) }
                save()
                messages.append("Clock starts at [\(clock.start)]")
            }
        }
        if plan.setsLeftover { leftover = plan.leftover }
        return messages
    }

    /// Runs a clock command on a clock that isn't the running one; nil when it worked.
    private func perform(_ command: ClockOut, _ clock: OpenClock, _ session: DocumentSession, now: Date) -> String? {
        switch session.perform(command, path: clock.path, at: 0, expect: nil, now: now) {
        case .commit: return nil
        case .failed(let message): return message
        default: return "Can't change the clock."
        }
    }
}
