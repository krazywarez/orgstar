import Foundation
import OrgCore
import OrgIndex

/// The `app.dailies.` and `app.node.` commands: org-roam's daily notes, and finding and
/// linking ID nodes, or with Denote set, denote-journal's entries and Denote's notes, with
/// the platform's questions and file opening.
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
    private var denote: Bool { OrgPreferences.usesDenote() }
    private var linkType: String { denote ? "denote:" : "id:" }

    /// A date prompt's answer, read by `org-read-date`. Without a time, the time of day stays
    /// now's, as `org-read-date` with `to-time` keeps it.
    nonisolated static func date(_ answer: String, now: Date = Date()) -> Date? {
        let read = ReadDate.read(answer, default: nil, now: now, calendar: .current)
        guard let chosen = Calendar.current.date(from: read.components(.current)) else { return nil }
        let time = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        return Calendar.current.date(bySettingHour: read.timeGiven ? read.hour : time.hour!, minute: read.timeGiven ? read.minute : time.minute!,
                                     second: read.timeGiven ? 0 : time.second!, of: chosen) ?? chosen
    }

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
                guard let answer, let date = Self.date(answer) else { return }
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
        case "app.node.rename-from-front-matter":
            renameFromFrontMatter()
        case "app.node.find":
            chooseNode("Node: ") { choice in
                switch choice {
                case .existing(let node): open(node.location.path, node.location.start)
                case .created(let path, _, _): open(path, (session.text(of: path).map { ($0 as NSString).length }) ?? 0)
                }
            }
        case "app.node.insert":
            chooseNode("Node: ") { choice in
                switch choice {
                case .existing(let node): insertLink(linkType + node.id, node.title)
                case .created(_, let id, let title): insertLink(linkType + id, title)
                }
            }
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

    enum NodeChoice {
        case existing(IndexStore.Node)
        case created(path: String, id: String, title: String)
    }

    /// `org-roam-node-read`: a node by its title, with its file's name when titles repeat. A
    /// title no node has makes a node with it, as org-roam's default capture template does;
    /// with Denote, `denote` asks for its keywords and makes the note.
    private func chooseNode(_ message: String, _ then: @escaping (NodeChoice) -> Void) {
        let all = nodes()
        let counts = Dictionary(all.map { ($0.title, 1) }, uniquingKeysWith: +)
        let labels = all.map { node in
            counts[node.title, default: 0] > 1 ? "\(node.title) (\((node.location.path as NSString).lastPathComponent))" : node.title
        }
        ask(Prompt(key: "node", message: message, choices: labels, requireMatch: false)) { answer in
            guard let answer else { return }
            if let index = labels.firstIndex(of: answer) { return then(.existing(all[index])) }
            let title = answer.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            if denote { return createDenote(title, known: all, then) }
            guard let folder = RoamNode.directory(roots: roots()) else { return show("No folder for new nodes") }
            do {
                let node = try RoamNode.create(title: title, in: folder)
                refresh()
                show("Created \((node.path as NSString).lastPathComponent)")
                then(.created(path: node.path, id: node.id, title: title))
            } catch {
                show("Can't make the node: \(error)")
            }
        }
    }

    /// What a new Denote note's questions give.
    struct DenoteAnswers {
        var keywords: [String] = []
        var folder: String?
        var date: Date?
        var template = ""
        var signature = ""
    }

    /// `denote`: after the title, the questions `denote-prompts` lists, in its order, then the
    /// note in `denote-directory` or the folder chosen under it.
    private func createDenote(_ title: String, known: [IndexStore.Node], _ then: @escaping (NodeChoice) -> Void) {
        guard let root = DenoteNote.directory(roots: roots()) else { return show("No folder for new notes") }
        createDenote(title, root: root, prompts: OrgPreferences.denotePrompts(), templates: UserConfig.denoteTemplates(.standard),
                     keywords: Denote.keywords(known.flatMap { Denote.name(ofFile: $0.location.path).keywords }), then)
    }

    func createDenote(
        _ title: String, root: String, prompts: [String], templates: [(key: String, text: String)], keywords: [String],
        answers: DenoteAnswers = DenoteAnswers(), _ then: @escaping (NodeChoice) -> Void
    ) {
        func next(_ answers: DenoteAnswers) {
            createDenote(title, root: root, prompts: Array(prompts.dropFirst()), templates: templates, keywords: keywords, answers: answers, then)
        }
        var answers = answers
        switch prompts.first {
        case nil:
            do {
                let note = try DenoteNote.create(title: title, keywords: answers.keywords, in: answers.folder ?? root, root: root,
                                                 now: answers.date ?? Date(), signature: answers.signature, template: answers.template)
                refresh()
                show("Created \((note.path as NSString).lastPathComponent)")
                then(.created(path: note.path, id: note.id, title: title))
            } catch {
                show("Can't make the note: \(error)")
            }
        case "keywords":
            // Separated by commas or spaces; the keywords already in file names are offered.
            ask(Prompt(key: "keywords", message: "New file KEYWORDS: ", choices: keywords, requireMatch: false)) { answer in
                guard let answer else { return }
                answers.keywords = answer.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                next(answers)
            }
        case "subdirectory":
            let folders = DenoteNote.subdirectories(of: root)
            guard !folders.isEmpty else { return next(answers) }
            ask(Prompt(key: "subdirectory", message: "Select SUBDIRECTORY: ", choices: ["."] + folders)) { answer in
                guard let answer else { return }
                answers.folder = answer == "." || answer.isEmpty ? root : (root as NSString).appendingPathComponent(answer)
                next(answers)
            }
        case "date":
            ask(Prompt(key: "date", message: "DATE and TIME for note: ", date: Prompt.DateRead(defaultDate: nil))) { answer in
                guard let answer else { return }
                answers.date = Self.date(answer)
                next(answers)
            }
        case "template":
            guard !templates.isEmpty else { return next(answers) }
            ask(Prompt(key: "template", message: "Select TEMPLATE key: ", choices: templates.map(\.key))) { answer in
                guard let answer else { return }
                answers.template = templates.first { $0.key == answer }?.text ?? ""
                next(answers)
            }
        case "signature":
            ask(Prompt(key: "signature", message: "New file SIGNATURE: ", requireMatch: false)) { answer in
                guard let answer else { return }
                answers.signature = answer
                next(answers)
            }
        default:
            // The title is asked first anyway; Org is the only file type; the rest have no equal.
            next(answers)
        }
    }

    /// `denote-rename-file-using-front-matter`: the open file renamed from its title and
    /// keywords, keeping its identifier and signature.
    func renameFromFrontMatter() {
        guard let path = session.path else { return show("No file is open") }
        guard let text = session.text(of: path) else { return show("Can't read \((path as NSString).lastPathComponent)") }
        guard let target = Denote.renamed(path, text: text) else { return show("Not a Denote note: no front matter or identifier") }
        guard target != path else { return show("Nothing to rename") }
        guard !FileManager.default.fileExists(atPath: target) else { return show("\((target as NSString).lastPathComponent) is already there") }
        guard session.save(path) else { return show("Can't save \((path as NSString).lastPathComponent)") }
        do {
            try FileManager.default.moveItem(atPath: path, toPath: target)
            session.kill(path)
            refresh()
            open(target, 0)
            show("Renamed to \((target as NSString).lastPathComponent)")
        } catch {
            show("Can't rename: \(error.localizedDescription)")
        }
    }
}
