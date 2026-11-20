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
    /// In the Mac sandbox, asks for access to folders outside the sidebar's that new notes go
    /// in. False when one is still out of reach.
    public var reachFolders: ([String]) -> Bool = { _ in true }

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
        case "app.node.rename":
            renameNote()
        case _ where id.hasPrefix("app.node.sequence-"):
            runSequence(String(id.dropFirst("app.node.sequence-".count)))
        case "app.node.rename-folder-from-front-matter":
            renameFolderFromFrontMatter()
        case "app.node.find":
            chooseNode("Node: ") { choice in
                switch choice {
                case .existing(let node): open(node.location.path, node.location.start)
                case .created(let path, _, _): open(path, (session.text(of: path).map { ($0 as NSString).length }) ?? 0)
                }
            }
        case "app.node.silo-find", "app.node.silo-create":
            // denote-silo: a folder of `denote-silo-directories` in place of `denote-directory`.
            let silos = DenoteNote.silos(roots: roots())
            guard !silos.isEmpty else { return show("No folder for new notes") }
            ask(Prompt(key: "silo", message: "Select a silo: ", choices: silos.map(DenoteNote.abbreviated))) { answer in
                guard let answer, let silo = silos.first(where: { DenoteNote.abbreviated($0) == answer }) else { return }
                let opened: (NodeChoice) -> Void = { choice in
                    switch choice {
                    case .existing(let node): open(node.location.path, node.location.start)
                    case .created(let path, _, _): open(path, (session.text(of: path).map { ($0 as NSString).length }) ?? 0)
                    }
                }
                guard id == "app.node.silo-create" else { return chooseNode("Node: ", silo: silo, opened) }
                ask(Prompt(key: "title", message: "New file TITLE: ", requireMatch: false)) { title in
                    guard let title = title?.trimmingCharacters(in: .whitespaces) else { return }
                    createDenote(title, known: nodes(), silo: silo, opened)
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
        guard reachFolders([dailies.directory]) else { return }
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
        guard reachFolders([dailies.directory]) else { return }
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
    private func chooseNode(_ message: String, silo: String? = nil, _ then: @escaping (NodeChoice) -> Void) {
        let all = silo.map { silo in nodes().filter { $0.location.path.hasPrefix(silo.hasSuffix("/") ? silo : silo + "/") } } ?? nodes()
        let counts = Dictionary(all.map { ($0.title, 1) }, uniquingKeysWith: +)
        let labels = all.map { node in
            counts[node.title, default: 0] > 1 ? "\(node.title) (\((node.location.path as NSString).lastPathComponent))" : node.title
        }
        ask(Prompt(key: "node", message: message, choices: labels, requireMatch: false)) { answer in
            guard let answer else { return }
            if let index = labels.firstIndex(of: answer) { return then(.existing(all[index])) }
            let title = answer.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            if denote || silo != nil { return createDenote(title, known: all, silo: silo, then) }
            guard let folder = RoamNode.directory(roots: roots()) else { return show("No folder for new nodes") }
            guard reachFolders([folder]) else { return }
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
    /// In a silo, its folder takes the place of `denote-directory`.
    /// With `signature`, as `denote-use-signature` sets it: that signature, not asked for.
    func createDenote(_ title: String, known: [IndexStore.Node], silo: String? = nil, signature: String? = nil, _ then: @escaping (NodeChoice) -> Void) {
        let folders = silo.map { [$0] } ?? DenoteNote.directories(roots: roots())
        guard !folders.isEmpty else { return show("No folder for new notes") }
        var answers = DenoteAnswers()
        if let signature { answers.signature = signature }
        createDenote(title, roots: folders, prompts: OrgPreferences.denotePrompts().filter { signature == nil || $0 != "signature" },
                     templates: UserConfig.denoteTemplates(.standard), keywords: Denote.keywords(known.flatMap { Denote.name(ofFile: $0.location.path).keywords }),
                     answers: answers, then)
    }

    /// The note goes in the first of `roots`, or the folder the `subdirectory` question picks
    /// among them and their folders.
    func createDenote(
        _ title: String, roots: [String], prompts: [String], templates: [(key: String, text: String)], keywords: [String],
        answers: DenoteAnswers = DenoteAnswers(), _ then: @escaping (NodeChoice) -> Void
    ) {
        let root = roots[0]
        func next(_ answers: DenoteAnswers) {
            createDenote(title, roots: roots, prompts: Array(prompts.dropFirst()), templates: templates, keywords: keywords, answers: answers, then)
        }
        var answers = answers
        switch prompts.first {
        case nil:
            guard reachFolders([answers.folder ?? root]) else { return }
            do {
                let note = try DenoteNote.create(title: title, keywords: answers.keywords, in: answers.folder ?? root, roots: roots,
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
            let folders = DenoteNote.folderChoices(roots)
            guard folders.count > 1 else { return next(answers) }
            ask(Prompt(key: "subdirectory", message: "Select SUBDIRECTORY: ", choices: folders.map(\.label))) { answer in
                guard let answer else { return }
                answers.folder = folders.first { $0.label == answer }?.path ?? root
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

    /// `denote-rename-file-using-front-matter`: the open file renamed from its title,
    /// keywords and signature, keeping its identifier.
    func renameFromFrontMatter() {
        guard let path = session.path else { return show("No file is open") }
        guard let text = session.text(of: path) else { return show("Can't read \((path as NSString).lastPathComponent)") }
        guard let target = Denote.renamed(path, text: text) else { return show("Not a Denote note: no front matter or identifier") }
        guard target != path else { return show("Nothing to rename") }
        rename(path, to: target)
    }

    /// Saves `path`, moves it to `target` and opens it there.
    func rename(_ path: String, to target: String) {
        guard !FileManager.default.fileExists(atPath: target) else { return show("\((target as NSString).lastPathComponent) is already there") }
        do {
            try move(path, to: target)
            refresh()
            open(target, 0)
            show("Renamed to \((target as NSString).lastPathComponent)")
        } catch {
            show("Can't rename: \(error)")
        }
    }

    /// Moves a file, saving it first and closing it when it's open.
    func move(_ path: String, to target: String) throws {
        if session.openPaths.contains(path) {
            guard session.save(path) else { throw Dailies.Failure("Can't save \((path as NSString).lastPathComponent)") }
        }
        try FileManager.default.moveItem(atPath: path, toPath: target)
        if session.openPaths.contains(path) { session.kill(path) }
    }

    /// `denote-rename-file`: the open file's title, keywords, signature and date, as
    /// `denote-prompts` asks for them, each starting with the current value, then the file
    /// renamed in its folder and its front matter rewritten. A file without an identifier
    /// gets one from its modification time; one without front matter gets it at the top.
    func renameNote() {
        guard let path = session.path else { return show("No file is open") }
        guard let text = session.text(of: path) else { return show("Can't read \((path as NSString).lastPathComponent)") }
        let name = Denote.name(ofFile: path), front = Denote.frontMatter(of: text)
        var title = front.title ?? name.title?.replacingOccurrences(of: "-", with: " ") ?? ""
        var keywords = front.keywords ?? name.keywords
        var signature = name.signature ?? front.signature ?? ""
        var date: Date?
        let file = (path as NSString).lastPathComponent
        func ask(_ prompts: ArraySlice<String>) {
            switch prompts.first {
            case nil: finish()
            case "title":
                self.ask(Prompt(key: "title", message: "Rename \(file) with TITLE (empty to remove): ", initial: title, requireMatch: false)) { answer in
                    guard let answer else { return }
                    title = answer
                    ask(prompts.dropFirst())
                }
            case "keywords":
                self.ask(Prompt(key: "keywords", message: "Rename \(file) with KEYWORDS (empty to remove): ", initial: keywords.joined(separator: ","), requireMatch: false)) { answer in
                    guard let answer else { return }
                    keywords = answer.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                    ask(prompts.dropFirst())
                }
            case "signature":
                self.ask(Prompt(key: "signature", message: "Rename \(file) with SIGNATURE (empty to remove): ", initial: signature, requireMatch: false)) { answer in
                    guard let answer else { return }
                    signature = answer
                    ask(prompts.dropFirst())
                }
            case "date":
                self.ask(Prompt(key: "date", message: "Rename \(file) with DATE: ", date: Prompt.DateRead(defaultDate: Denote.date(of: text)))) { answer in
                    guard let answer else { return }
                    date = answer.isEmpty ? nil : Self.date(answer)
                    ask(prompts.dropFirst())
                }
            default: ask(prompts.dropFirst())
            }
        }
        func finish() {
            let (target, rewritten) = DenoteNote.renaming(path, text: text, title: title, keywords: keywords, signature: signature, date: date,
                                                          roots: DenoteNote.directories(roots: roots()))
            guard target != path || rewritten != text else { return show("Nothing to rename") }
            if rewritten != text, case .failed(let message) = session.perform(ReplaceText(old: text, new: rewritten), path: path, at: 0, expect: nil) { return show(message) }
            guard target != path else { return show("Front matter rewritten") }
            rename(path, to: target)
        }
        ask(ArraySlice(OrgPreferences.denotePrompts()))
    }

    /// `denote-dired-rename-marked-files-using-front-matter`, with every Denote note in a
    /// folder of `denote-directory` marked: each renamed from its front matter.
    func renameFolderFromFrontMatter() {
        let folders = DenoteNote.folderChoices(DenoteNote.directories(roots: roots()))
        guard !folders.isEmpty else { return show("No folder for notes") }
        ask(Prompt(key: "folder", message: "Rename notes in: ", choices: folders.map(\.label))) { answer in
            guard let answer, let folder = folders.first(where: { $0.label == answer })?.path else { return }
            let shown = session.path
            var renamed = 0, problems: [String] = []
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() where Denote.identifier(ofFile: name) != nil {
                let path = (folder as NSString).appendingPathComponent(name)
                guard let text = session.text(of: path) ?? (try? String(contentsOfFile: path, encoding: .utf8)),
                      let target = Denote.renamed(path, text: text), target != path else { continue }
                guard !FileManager.default.fileExists(atPath: target) else { problems.append("\((target as NSString).lastPathComponent) is already there"); continue }
                do {
                    try move(path, to: target)
                    renamed += 1
                    if shown == path { open(target, 0) }
                } catch {
                    problems.append("\(error)")
                }
            }
            refresh()
            show(([renamed == 1 ? "Renamed 1 note" : "Renamed \(renamed) notes"] + problems).joined(separator: "; "))
        }
    }
}
