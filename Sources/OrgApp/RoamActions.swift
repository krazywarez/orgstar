import Foundation
import OrgCore
import OrgIndex

/// The `app.dailies.` and `app.node.` commands: org-roam's daily notes, and finding and
/// linking ID nodes, with the platform's questions and file opening.
@MainActor
public struct RoamActions {
    public var session: DocumentSession
    /// The sidebar folders, the first being `org-roam-directory` unless it's set.
    public var roots: () -> [String]
    /// Headings and files with IDs.
    public var nodes: () -> [IndexStore.Node]
    public var show: (String) -> Void
    public var ask: (Prompt, @escaping (String?) -> Void) -> Void
    /// Opens a file with the caret at an offset.
    public var open: (_ path: String, _ offset: Int) -> Void
    /// Puts a link at the caret, in place of the selection, which describes it; without one,
    /// the title does.
    public var insertLink: (_ link: String, _ title: String) -> Void
    /// The index reads new files.
    public var refresh: () -> Void

    public init(
        session: DocumentSession, roots: @escaping () -> [String], nodes: @escaping () -> [IndexStore.Node], show: @escaping (String) -> Void,
        ask: @escaping (Prompt, @escaping (String?) -> Void) -> Void, open: @escaping (String, Int) -> Void,
        insertLink: @escaping (String, String) -> Void, refresh: @escaping () -> Void
    ) {
        self.session = session
        self.roots = roots
        self.nodes = nodes
        self.show = show
        self.ask = ask
        self.open = open
        self.insertLink = insertLink
        self.refresh = refresh
    }

    private var dailies: Dailies? { Dailies.configured(roots: roots()) }

    private func day(_ offset: Int, from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
    }

    public func run(_ id: String) {
        switch id {
        case "app.dailies.today": goto(day(0))
        case "app.dailies.yesterday": goto(day(-1))
        case "app.dailies.tomorrow": goto(day(1))
        case "app.dailies.capture-today": capture(day(0))
        case "app.dailies.capture-yesterday": capture(day(-1))
        case "app.dailies.capture-tomorrow": capture(day(1))
        case "app.dailies.date", "app.dailies.capture-date":
            let goto = id == "app.dailies.date"
            ask(Prompt(key: "date", message: goto ? "Find daily-note: " : "Capture to daily-note: ", date: Prompt.DateRead(defaultDate: nil))) { answer in
                guard let answer else { return }
                let now = Date()
                let read = ReadDate.read(answer, default: nil, now: now, calendar: .current)
                guard let chosen = Calendar.current.date(from: read.components(.current)) else { return }
                // The time of day stays now's, as `org-read-date` with `to-time` keeps it.
                let time = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
                let date = Calendar.current.date(bySettingHour: read.timeGiven ? read.hour : time.hour!, minute: read.timeGiven ? read.minute : time.minute!,
                                                 second: read.timeGiven ? 0 : time.second!, of: chosen) ?? chosen
                if goto { self.goto(date) } else { capture(date) }
            }
        case "app.dailies.next", "app.dailies.previous":
            guard let dailies else { return show("No folder for daily notes") }
            guard let path = session.path else { return show("Not in a daily-note") }
            do {
                let note = try dailies.neighbor(of: path, by: id == "app.dailies.next" ? 1 : -1)
                open(note, 0)
            } catch {
                show("\(error)")
            }
        case "app.node.find":
            chooseNode("Node: ") { node in open(node.location.path, node.location.start) }
        case "app.node.insert":
            chooseNode("Node: ") { node in insertLink("id:" + node.id, node.title) }
        default:
            show("Unknown command \(id)")
        }
    }

    /// `org-roam-dailies-goto-*`: the day's file, made if missing.
    func goto(_ day: Date) {
        guard let dailies else { return show("No folder for daily notes") }
        do {
            let (path, created) = try dailies.ensure(day)
            if created { refresh() }
            open(path, (session.text(of: path).map { ($0 as NSString).length }) ?? 0)
        } catch {
            show("Can't make the daily note: \(error.localizedDescription)")
        }
    }

    /// `org-roam-dailies-capture-*`: the entry template filed at the end of the day's file,
    /// which opens with the caret at `%?`.
    func capture(_ day: Date) {
        guard let dailies else { return show("No folder for daily notes") }
        let context = CaptureContext(now: day, file: session.path ?? "", userName: NSFullUserName())
        let questions = Capture.questions(dailies.entry, context: context)
        func ask(_ answers: [String]) {
            guard answers.count < questions.count else { return file(answers) }
            let question = questions[answers.count]
            self.ask(Prompt(key: "q\(answers.count)", message: question.prompt + ": ", initial: question.defaultValue, requireMatch: false)) { answer in
                if let answer { ask(answers + [answer]) }
            }
        }
        func file(_ answers: [String]) {
            do {
                let (path, created) = try dailies.ensure(day)
                if created { refresh() }
                guard let text = session.text(of: path) else { return show("Can't read \((path as NSString).lastPathComponent)") }
                let filled: (text: String, cursor: Int)
                switch Capture.fill(dailies.entry, context: context, answers: answers) {
                case .success(let result): filled = result
                case .failure(.message(let message)): return show(message)
                }
                let template = CaptureTemplate(key: "d", name: "daily", target: .file(path), template: dailies.entry)
                switch Capture.placement(filled.text, template: template, in: text, now: day) {
                case .failure(.message(let message)): show(message)
                case .success(let placed):
                    if case .failed(let message) = session.perform(ReplaceText(old: text, new: placed.text), path: path, at: 0, expect: nil) { return show(message) }
                    open(path, placed.start + filled.cursor)
                }
            } catch {
                show("Can't make the daily note: \(error.localizedDescription)")
            }
        }
        ask([])
    }

    /// `org-roam-node-read`: a node by its title, with its file's name when titles repeat.
    private func chooseNode(_ message: String, _ then: @escaping (IndexStore.Node) -> Void) {
        let all = nodes()
        guard !all.isEmpty else { return show("No headings or files have IDs") }
        let counts = Dictionary(all.map { ($0.title, 1) }, uniquingKeysWith: +)
        let labels = all.map { node in
            counts[node.title, default: 0] > 1 ? "\(node.title) (\((node.location.path as NSString).lastPathComponent))" : node.title
        }
        ask(Prompt(key: "node", message: message, choices: labels)) { answer in
            guard let answer, let index = labels.firstIndex(of: answer) else { return }
            then(all[index])
        }
    }
}
