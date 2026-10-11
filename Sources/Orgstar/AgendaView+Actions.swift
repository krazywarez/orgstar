import AppKit
import OrgApp
import OrgDocument
import OrgCore
import OrgPresentation
import SwiftUI

extension AgendaView {
    // MARK: - Commands

    func handle(_ press: KeyPress) -> KeyPress.Result {
        let control = press.modifiers.contains(.control)
        // `C-x` and friends arrive as control characters or as letters with control.
        func isControl(_ letter: String, _ code: String) -> Bool { control && (press.characters == letter || press.characters == code) }
        if let pending = prefix {
            prefix = nil
            if pending == "v" {
                switch press.characters {
                case "d" where isAgenda: setSpan(.day)
                case "w" where isAgenda: setSpan(.week)
                case "m" where isAgenda: setSpan(.month)
                default: message = "v \(press.characters) is undefined"
                }
                if message == "v-" { message = nil }
                return .handled
            }
            if pending == "C-c C-x" {
                if isControl("s", "\u{13}") { archive() } else { message = "C-c C-x \(press.characters) is undefined" }
                return .handled
            }
            if isControl("s", "\u{13}") {
                run(SetPlanning(deadline: false))
            } else if isControl("d", "\u{04}") {
                run(SetPlanning(deadline: true))
            } else if isControl("q", "\u{11}") {
                run(SetTags())
            } else if isControl("t", "\u{14}") {
                run(TodoCycle())
            } else if isControl("w", "\u{17}") {
                refile(marked: false)
            } else if isControl("x", "\u{18}") {
                prefix = "C-c C-x"
                message = "C-c C-x-"
            } else if press.characters == "$" {
                archive()
            } else {
                message = "C-c \(press.characters) is undefined"
            }
            return .handled
        }
        if isControl("c", "\u{03}") {
            prefix = "C-c"
            message = "C-c-"
            return .handled
        }
        if isControl("n", "\u{0e}") || (press.key == .downArrow && press.modifiers.isEmpty) {
            step(1)
            return .handled
        }
        if isControl("p", "\u{10}") || (press.key == .upArrow && press.modifiers.isEmpty) {
            step(-1)
            return .handled
        }
        if press.key == .return || press.key == .tab, let selection, let line = line(selection) {
            open(line)
            return .handled
        }
        if press.key == .space, let selection {
            jump(selection, focus: false)
            return .handled
        }
        if press.modifiers == .shift, press.key == .rightArrow || press.key == .leftArrow {
            run(ShiftTimestampDay(later: press.key == .rightArrow), atMarker: true)
            return .handled
        }
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch press.characters {
        case "n": step(1)
        case "p": step(-1)
        case "f" where isAgenda: move(forward: true)
        case "b" where isAgenda: move(forward: false)
        case "." where isAgenda: goToday()
        case "j" where isAgenda:
            pickedDate = Self.date(anchorDay)
            showingDatePicker = true
        case "v" where isAgenda:
            prefix = "v"
            message = "v-"
        case "d" where isAgenda: setSpan(.day)
        case "w" where isAgenda: setSpan(.week)
        case "k" where isAgenda: capture(on: anchorDay)
        case "s":
            commands.run("app.save-all")
            message = "Saved"
        case "/", "\\", "=", "_": askFilter(press.characters.first!)
        case "<": toggleCategoryFilter()
        case "|":
            filter = AgendaFilter()
            message = "Filters removed"
        case "l" where isAgenda:
            logMode.toggle()
            message = logMode ? "Log mode on" : "Log mode off"
        case "g", "r":
            loadViews()
            tick += 1
        case "I": clockIn()
        case "O": message = clock.clockOut(session)
        case "X": message = clock.clockOut(session, cancel: true)
        case "$": archive()
        case "m": mark(true)
        case "u": mark(false)
        case "U":
            marked = []
            message = "No entries marked"
        case "B": askBulk()
        case "t": run(TodoCycle())
        case "+": run(PriorityUp())
        case "-": run(PriorityDown())
        case ",": run(SetPriority())
        case ":": run(SetTags())
        default: return .ignored
        }
        return .handled
    }

    // MARK: - Clock, refile, archive, bulk

    private var selectedEntry: EntryRef? { selection.flatMap(item).flatMap(EntryRef.init) }

    func clockIn() {
        guard let entry = selectedEntry, let offset = session.locateHeading(path: entry.path, line: entry.line, near: entry.offset) else {
            message = "No entry selected"
            return
        }
        let paths = workspace.files.filter { $0.kind == .org }.map(\.path)
        Task {
            let outcome = await clock.clockIn(session, target: .entry(path: entry.path, offset: offset), paths: paths, ask: commands.askClock)
            if let jump = outcome.jump { commands.jump(path: jump.path, offset: jump.offset) }
            message = outcome.messages.last { !$0.isEmpty }
            tick += 1
        }
    }

    func archive() {
        guard let entry = selectedEntry, let offset = session.locateHeading(path: entry.path, line: entry.line, near: entry.offset) else {
            message = "No entry selected"
            return
        }
        message = session.archive(from: (entry.path, offset))
        tick += 1
    }

    /// Refiles the selected entry, or with `marked` the marked ones, to a target asked for in
    /// the main window, where the list of targets is searchable.
    private func refile(marked bulk: Bool) {
        let entries = bulk ? marked : selectedEntry.map { [$0] } ?? []
        guard !entries.isEmpty else {
            message = "No entry selected"
            return
        }
        let targets = workspace.refileTargets(openPath: session.path, document: session.document)
        commands.ask(Prompt(key: "refile", message: "Refile to:", choices: targets.map(\.label))) { answer in
            guard let answer, targets.contains(where: { $0.label == answer }) else { return }
            message = eachEntry(entries) { entry, offset in
                // Targets in the entry's own file from its text now, as earlier moves shift them.
                let document = session.openDocuments.first { $0.path == entry.path }?.document
                    ?? FileManager.default.contents(atPath: entry.path).map { DocumentState(bytes: [UInt8]($0)) }
                guard let target = workspace.refileTargets(openPath: entry.path, document: document).first(where: { $0.label == answer }) else {
                    return "Can't find \(answer) any more."
                }
                return session.refile(to: target, from: (entry.path, offset))
            }
            if bulk { marked = [] }
            tick += 1
        }
        openWindow(id: "main")
    }

    /// Runs `action` on each entry, finding it again first: later entries in a file first, so
    /// earlier ones keep their place. Returns the last message.
    private func eachEntry(_ entries: [EntryRef], _ action: (EntryRef, Int) -> String?) -> String? {
        var last: String?
        var failed = 0
        for entry in entries.sorted(by: { ($0.path, $1.offset) < ($1.path, $0.offset) }) {
            guard let offset = session.locateHeading(path: entry.path, line: entry.line, near: entry.offset) else {
                failed += 1
                continue
            }
            last = action(entry, offset)
        }
        return failed > 0 ? "\(failed) marked \(failed == 1 ? "entry" : "entries") changed and \(failed == 1 ? "was" : "were") skipped" : last
    }

    func mark(_ on: Bool) {
        guard let entry = selectedEntry else {
            message = "No entry selected"
            return
        }
        if on {
            if !marked.contains(entry) { marked.append(entry) }
        } else {
            marked.removeAll { $0 == entry }
        }
        message = "\(marked.count) marked"
    }

    /// `B`: an action for every marked entry.
    private func askBulk() {
        guard !marked.isEmpty else {
            message = "No entries are marked"
            return
        }
        textPrompt = TextPrompt(title: "Bulk action on \(marked.count): [$] archive [r] refile [t] TODO state [+] tag [-] untag [s] schedule [d] deadline") { answer in
            switch answer.trimmingCharacters(in: .whitespaces) {
            case "$": bulk { session.archive(from: ($0.path, $1)) }
            case "r": refile(marked: true)
            case "t":
                textPrompt = TextPrompt(title: "TODO state (empty for none):") { keyword in
                    let word = keyword.trimmingCharacters(in: .whitespaces)
                    bulk { performAt($0, $1, SetTodo(keyword: word.isEmpty ? nil : word)) }
                }
            case "+", "-":
                let on = answer.trimmingCharacters(in: .whitespaces) == "+"
                textPrompt = TextPrompt(title: on ? "Tag to add:" : "Tag to remove:") { tag in
                    let tag = tag.trimmingCharacters(in: .whitespaces)
                    guard !tag.isEmpty else { return }
                    bulk { performAt($0, $1, ToggleTag(tag: tag, on: on)) }
                }
            case "s", "d":
                let deadline = answer.trimmingCharacters(in: .whitespaces) == "d"
                textPrompt = TextPrompt(title: deadline ? "Deadline (+2d, fri, 2026-10-12):" : "Schedule (+2d, fri, 2026-10-12):") { date in
                    bulk { performAt($0, $1, SetPlanning(deadline: deadline), answers: ["date": date]) }
                }
            default:
                message = "No bulk action \(answer)"
            }
        }
    }

    func bulk(_ action: (EntryRef, Int) -> String?) {
        message = eachEntry(marked, action) ?? "Done with \(marked.count) entries"
        marked = []
        tick += 1
    }

    /// Runs `command` at the heading at `offset`, as `run` does for the selection.
    private func performAt(_ entry: EntryRef, _ offset: Int, _ command: any OrgCommand, answers: [String: String] = [:]) -> String? {
        switch session.perform(command, path: entry.path, at: offset, expect: (offset, entry.line), answers: answers) {
        case .failed(let text): text
        case .prompt: "\(command.title) needs an answer; run it on the entry itself"
        default: nil
        }
    }

    /// Runs `command` on the selected entry, at its heading or, with `atMarker`, at the
    /// timestamp the entry is listed for.
    func run(_ command: any OrgCommand, atMarker: Bool = false, answers: [String: String] = [:], itemID: String? = nil) {
        guard let id = itemID ?? selection, let item = item(id), let path = item.path, let start = item.headingOffset else {
            message = "No entry selected"
            return
        }
        if atMarker, ![.deadline, .upcomingDeadline, .scheduled, .pastScheduled, .timestamp].contains(item.kind) {
            message = "Only dated entries can move"
            return
        }
        let offset = atMarker ? (item.markerOffset ?? start) : start
        let step = session.perform(command, path: path, at: offset, expect: item.headingLine.map { (start, $0) }, answers: answers)
        switch step {
        case .prompt(let request):
            promptText = request.initial
            prompt = PendingPrompt(prompt: request, command: command, atMarker: atMarker, answers: answers, itemID: id)
        case .failed(let text):
            message = text
            tick += 1
        case .external:
            message = "Not available from the agenda"
        case .commit:
            message = nil
            tick += 1
        }
    }

    func answerPrompt() {
        guard let pending = prompt else { return }
        prompt = nil
        var answers = pending.answers
        answers[pending.prompt.key] = promptText
        run(pending.command, atMarker: pending.atMarker, answers: answers, itemID: pending.itemID)
    }
}
