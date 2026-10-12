import Foundation
import OrgCore

/// The `app.attach.` commands for the entry at the caret, with the platform's questions,
/// file picker and file opening.
@MainActor
public struct AttachActions {
    /// The open file's entry at the caret; nil when no file is open.
    public var entry: () -> Attachments.Entry?
    /// The buffer's new text, and where the caret goes; nil keeps it where it is.
    public var apply: (String, Int?) -> Void
    public var show: (String) -> Void
    public var ask: (Prompt, @escaping (String?) -> Void) -> Void
    public var storeLink: (StoredLink) -> Void
    /// Opens a file as following a `file:` link does.
    public var open: (String) -> Void
    /// Shows a folder in the system's file browser.
    public var reveal: (String) -> Void
    /// Asks for files to attach with a method.
    public var pick: (Attachments.Method) -> Void

    public init(
        entry: @escaping () -> Attachments.Entry?, apply: @escaping (String, Int?) -> Void, show: @escaping (String) -> Void,
        ask: @escaping (Prompt, @escaping (String?) -> Void) -> Void, storeLink: @escaping (StoredLink) -> Void,
        open: @escaping (String) -> Void, reveal: @escaping (String) -> Void, pick: @escaping (Attachments.Method) -> Void
    ) {
        self.entry = entry
        self.apply = apply
        self.show = show
        self.ask = ask
        self.storeLink = storeLink
        self.open = open
        self.reveal = reveal
        self.pick = pick
    }

    public static let methods: [String: Attachments.Method] = [
        "app.attach.attach": .cp, "app.attach.move": .mv, "app.attach.link": .ln, "app.attach.symlink": .lns,
    ]

    private func yes(_ question: String, _ then: @escaping (Bool) -> Void) {
        ask(Prompt(key: "confirm", message: question + " (yes or no)", choices: ["yes", "no"])) { then($0 == "yes") }
    }

    /// Runs `body` on the entry and applies its text, or shows what went wrong.
    private func change(_ body: (inout Attachments.Entry) throws -> String?) {
        guard var entry = entry() else { return show("No file is open") }
        let original = entry.text
        do {
            let message = try body(&entry)
            if entry.text != original { apply(entry.text, nil) }
            if let message { show(message) }
        } catch {
            if entry.text != original { apply(entry.text, nil) }
            show((error as? Attachments.Failure)?.description ?? error.localizedDescription)
        }
    }

    public func run(_ id: String) {
        if let method = Self.methods[id] { return pick(method) }
        switch id {
        case "app.attach.url":
            ask(Prompt(key: "url", message: "URL of the file to attach:")) { answer in
                guard let answer, !answer.isEmpty else { return }
                download(answer)
            }
        case "app.attach.new":
            ask(Prompt(key: "name", message: "Create attachment named:")) { name in
                guard let name, !name.isEmpty else { return }
                var file: String?
                change { entry in
                    file = try Attachments.create(name, in: &entry)
                    return "New attachment \(name)"
                }
                if let file { open(file) }
            }
        case "app.attach.sync":
            var empty: String?
            change { entry in
                empty = Attachments.sync(&entry)
                return nil
            }
            if let empty {
                yes("Attachment directory is empty.  Delete?") { delete in
                    if delete { try? FileManager.default.removeItem(atPath: empty) }
                }
            }
        case "app.attach.open":
            guard let entry = entry() else { return show("No file is open") }
            guard let dir = Attachments.directory(entry) else { return show("No attachment directory exist") }
            let files = Attachments.files(in: dir)
            if files.count == 1 { return open((dir as NSString).appendingPathComponent(files[0])) }
            guard !files.isEmpty else { return show("No attachments in \(dir)") }
            ask(Prompt(key: "file", message: "Open attachment:", choices: files)) { file in
                if let file { open((dir as NSString).appendingPathComponent(file)) }
            }
        case "app.attach.reveal":
            var dir: String?
            change { entry in
                dir = try Attachments.directoryCreating(&entry)
                return nil
            }
            if let dir { reveal(dir) }
        case "app.attach.delete":
            guard let entry = entry() else { return show("No file is open") }
            guard let dir = Attachments.directory(entry) else { return show("No attachment directory exist") }
            ask(Prompt(key: "file", message: "Delete attachment:", choices: Attachments.files(in: dir))) { file in
                guard let file else { return }
                change { entry in
                    try Attachments.delete(file, in: entry)
                    return "Deleted attachment \(file)"
                }
            }
        case "app.attach.delete-all":
            guard let entry = entry() else { return show("No file is open") }
            guard Attachments.directory(entry) != nil else { return show("No attachment directory exist") }
            yes("Really remove all attachments of this entry?") { remove in
                guard remove else { return }
                change { entry in
                    try Attachments.deleteAll(&entry)
                    return "Attachment directory removed"
                }
            }
        case "app.attach.set-directory":
            guard let entry = entry() else { return show("No file is open") }
            let current = OrgAttach.dirProperty(tree: OrgParser.parse(entry.text), at: entry.offset)
            ask(Prompt(key: "dir", message: "Attachment directory:", initial: current ?? "", requireMatch: false)) { answer in
                guard let answer, !answer.isEmpty else { return }
                var moved: (new: String, old: String?)?
                change { entry in
                    moved = Attachments.setDirectory(answer, in: &entry)
                    return nil
                }
                if let moved, let old = moved.old { offerMove(from: old, to: moved.new) }
            }
        case "app.attach.unset-directory":
            var moved: (old: String?, new: String?)?
            change { entry in
                moved = Attachments.unsetDirectory(&entry)
                return nil
            }
            if let moved, let old = moved.old { offerMove(from: old, to: moved.new) }
        default:
            show("Unknown attachment command \(id)")
        }
    }

    /// `org-attach-set-directory`'s questions after the folder changes.
    private func offerMove(from old: String, to new: String?) {
        func offerDelete() {
            yes("Delete \(old)") { delete in
                if delete { try? FileManager.default.removeItem(atPath: old) }
            }
        }
        guard let new else { return offerDelete() }
        yes("Copy over attachments from old directory?") { copy in
            if copy {
                do { try Attachments.copyContents(of: old, to: new) } catch { return show(error.localizedDescription) }
            }
            offerDelete()
        }
    }

    /// `org-attach-attach` for each picked file.
    public func attach(_ urls: [URL], method: Attachments.Method) {
        change { entry in
            var names: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let link = try Attachments.attach(url, method: method, to: &entry)
                storeLink(link)
                names.append(link.description ?? url.lastPathComponent)
            }
            return Self.attached(names)
        }
    }

    /// `data` attached as `name`, as a photo or a download is.
    public func attach(_ data: Data, named name: String) {
        change { entry in
            let link = try Attachments.attach(data, named: name, to: &entry)
            storeLink(link)
            return Self.attached([name])
        }
    }

    /// Runs `body` on the entry and puts the links it returns at the caret.
    private func insert(_ body: (inout Attachments.Entry) throws -> [String]) {
        guard var entry = entry() else { return show("No file is open") }
        let original = entry.text
        do {
            let links = try body(&entry)
            guard !links.isEmpty else { return }
            let (text, caret) = ImageYank.inserting(links, into: entry.text, at: ImageYank.map(entry.offset, from: original, to: entry.text))
            apply(text, caret)
            let names = links.compactMap { $0.firstMatch(of: /^\[\[attachment:(.*)\]\]$/).map { String($0.1) } }
            if let message = Self.attached(names) { show(message) }
        } catch {
            if entry.text != original { apply(entry.text, nil) }
            show((error as? Attachments.Failure)?.description ?? error.localizedDescription)
        }
    }

    /// `yank-media` with an image: `data` saved as `org-yank-image-save-method` says, with
    /// extension `ext`, and its link at the caret. `prefix` replaces "clipboard" in the name.
    public func yankImage(_ data: Data, ext: String, prefix: String = "clipboard") {
        let method = ImageYank.SaveMethod(OrgPreferences.yankImageSaveMethod())
        insert { entry in [try ImageYank.save(data, ext: ext, method: method, in: &entry, prefix: prefix)] }
    }

    /// Files dropped or pasted, as `org-yank-dnd-method` says: attached with `attachMethod`,
    /// opened, or linked; their links at the caret.
    public func drop(_ files: [URL], method: ImageYank.DropMethod = OrgPreferences.yankDndMethod(), attachMethod: Attachments.Method = .cp) {
        guard !files.isEmpty else { return }
        switch method {
        case .ask:
            ask(Prompt(key: "dnd", message: "What to do with file?", choices: ["attach", "open", "insert file: link"])) { answer in
                switch answer {
                case "attach": drop(files, method: .attach, attachMethod: attachMethod)
                case "open": drop(files, method: .open, attachMethod: attachMethod)
                case "insert file: link": drop(files, method: .fileLink, attachMethod: attachMethod)
                default: break
                }
            }
        case .open:
            for file in files { open(file.path) }
        case .attach, .fileLink:
            let saveMethod = ImageYank.SaveMethod(OrgPreferences.yankImageSaveMethod())
            insert { entry in
                let scoped = files.map { $0.startAccessingSecurityScopedResource() }
                defer { for (file, on) in zip(files, scoped) where on { file.stopAccessingSecurityScopedResource() } }
                return try ImageYank.drop(files, method: method, attachMethod: attachMethod, saveMethod: saveMethod, in: &entry)
            }
        }
    }

    static func attached(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "File \"\(names[0])\" is now an attachment"
        default: "\(names.count) files are now attachments"
        }
    }

    /// `org-attach-url`: the file downloaded, then attached as the URL's last part.
    private func download(_ address: String) {
        guard let url = URL(string: address), url.scheme != nil else { return show("Not a URL: \(address)") }
        let name = Attachments.name(ofURL: address)
        guard !name.isEmpty else { return show("No file name in \(address)") }
        show("Downloading \(address)…")
        Task { @MainActor in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return show("Can't download \(address): HTTP \(http.statusCode)")
                }
                attach(data, named: name)
            } catch {
                show("Can't download \(address): \(error.localizedDescription)")
            }
        }
    }
}
