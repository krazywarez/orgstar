import Foundation
import OrgCore

/// org-attach's commands on the file system, with `org-attach-preferred-new-method` `id`,
/// `org-attach-auto-tag` "ATTACH" and `org-attach-store-link-p` `attached`. Each takes the
/// file's text and returns it as the command leaves it.
public enum Attachments {
    /// `org-attach-method`.
    public enum Method: String, Sendable {
        case cp, mv, ln, lns
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Where an entry is: its file's text and path, and an offset in the entry.
    public struct Entry: Sendable {
        public var text: String
        public let offset: Int
        public let path: String
        public let idDir: String
        /// `org-attach-use-inheritance`, as `OrgAttach.directory` takes it.
        public let inherit: Bool?
        public let options: EditingOptions

        public init(text: String, offset: Int, path: String, idDir: String = OrgPreferences.attachIDDir(),
                    inherit: Bool? = OrgPreferences.attachUseInheritance(), options: EditingOptions = .org) {
            self.text = text
            self.offset = offset
            self.path = path
            self.idDir = idDir
            self.inherit = inherit
            self.options = options
        }
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// `org-attach-dir`: the entry's attachment folder when it exists.
    public static func directory(_ entry: Entry, noFSCheck: Bool = false) -> String? {
        OrgAttach.directory(tree: OrgParser.parse(entry.text), at: entry.offset, path: entry.path, idDir: entry.idDir, inherit: entry.inherit, noFSCheck: noFSCheck, isDirectory: isDirectory)
    }

    /// `org-attach-dir-get-create`: the folder, made if missing; an entry without DIR or ID
    /// gets an ID.
    public static func directoryCreating(_ entry: inout Entry, newID: () -> String = { UUID().uuidString.lowercased() }) throws -> String {
        var dir = directory(entry, noFSCheck: true)
        if dir == nil {
            let (text, id) = OrgAttach.ensuringID(entry.text, at: entry.offset, newID: newID)
            entry.text = text
            dir = OrgAttach.folder(forID: id, idDir: entry.idDir, in: (entry.path as NSString).deletingLastPathComponent, existing: false, isDirectory: isDirectory)
        }
        guard let dir else { throw Failure("No attachment directory is associated with the current node") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func tag(_ entry: inout Entry, on: Bool) {
        entry.text = OrgAttach.tagging(entry.text, at: entry.offset, on: on, options: entry.options)
    }

    static func stored(_ name: String) -> StoredLink {
        StoredLink(link: "attachment:" + name, description: name)
    }

    /// `org-attach-attach`: `source` moved, copied or linked into the folder. The link it
    /// stores.
    @discardableResult
    public static func attach(_ source: URL, method: Method, to entry: inout Entry) throws -> StoredLink {
        let dir = try directoryCreating(&entry)
        let name = source.standardizedFileURL.lastPathComponent
        let target = (dir as NSString).appendingPathComponent(name)
        let files = FileManager.default
        switch method {
        case .mv: try files.moveItem(atPath: source.path, toPath: target)
        case .cp: try files.copyItem(atPath: source.path, toPath: target)
        case .ln: try files.linkItem(atPath: source.path, toPath: target)
        case .lns: try files.createSymbolicLink(atPath: target, withDestinationPath: source.path)
        }
        tag(&entry, on: true)
        return stored(name)
    }

    /// `org-attach-url` and `org-attach-buffer`: `data` written as `name` in the folder.
    @discardableResult
    public static func attach(_ data: Data, named name: String, to entry: inout Entry) throws -> StoredLink {
        guard !name.isEmpty, !name.contains("/") else { throw Failure("No file name to attach as") }
        let dir = try directoryCreating(&entry)
        let target = (dir as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target) else { throw Failure("File exists: \(target)") }
        try data.write(to: URL(fileURLWithPath: target))
        tag(&entry, on: true)
        return stored(name)
    }

    /// The name `org-attach-url` gives a download: the URL after its last slash.
    public static func name(ofURL url: String) -> String {
        url.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// `org-attach-new`: the path of `name` in the folder, made empty if missing, to open.
    public static func create(_ name: String, in entry: inout Entry) throws -> String {
        let dir = try directoryCreating(&entry)
        tag(&entry, on: true)
        let file = OrgAttach.expand(name, in: dir)
        if !FileManager.default.fileExists(atPath: file) {
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: file))
        }
        return file
    }

    /// `org-attach-file-list`.
    public static func files(in dir: String) -> [String] {
        OrgAttach.fileList((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
    }

    /// `org-attach-delete-one`.
    public static func delete(_ name: String, in entry: Entry) throws {
        guard let dir = directory(entry) else { throw Failure("No attachment directory exist") }
        let file = OrgAttach.expand(name, in: dir)
        guard FileManager.default.fileExists(atPath: file) else { throw Failure("No such attachment: \(file)") }
        try FileManager.default.removeItem(atPath: file)
    }

    /// `org-attach-delete-all`: the folder and everything in it, and the tag.
    public static func deleteAll(_ entry: inout Entry) throws {
        guard let dir = directory(entry) else { return }
        try FileManager.default.removeItem(atPath: dir)
        tag(&entry, on: false)
    }

    /// `org-attach-sync`: the tag on when the folder has files, off when it hasn't or is
    /// missing. The folder when it's empty, for the caller to offer to delete.
    public static func sync(_ entry: inout Entry) -> String? {
        guard let dir = directory(entry) else {
            tag(&entry, on: false)
            return nil
        }
        let files = files(in: dir)
        tag(&entry, on: !files.isEmpty)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).isEmpty ? dir : nil
    }

    /// `org-attach-set-directory`'s DIR: `dir` expanded against the file's folder, absolute as
    /// with `org-attach-dir-relative` nil. The old folder when it existed and is another.
    public static func setDirectory(_ dir: String, in entry: inout Entry) -> (new: String, old: String?) {
        let old = directory(entry)
        let new = OrgAttach.expand(dir, in: (entry.path as NSString).deletingLastPathComponent)
        entry.text = OrgAttach.settingDirectory(entry.text, at: entry.offset, to: dir.hasSuffix("/") ? new + "/" : new)
        return (new, old.flatMap { $0 == new ? nil : $0 })
    }

    /// `org-attach-unset-directory`: DIR and ATTACH_DIR removed. The old and new folders when
    /// they differ.
    public static func unsetDirectory(_ entry: inout Entry) -> (old: String?, new: String?) {
        let old = directory(entry)
        entry.text = OrgAttach.settingDirectory(entry.text, at: entry.offset, to: nil)
        let new = directory(entry)
        return old == new ? (nil, nil) : (old, new)
    }

    /// `copy-directory` of the old folder's contents into the new one, which is made if
    /// missing; files there already are kept.
    public static func copyContents(of old: String, to new: String) throws {
        let files = FileManager.default
        try files.createDirectory(atPath: new, withIntermediateDirectories: true)
        for name in try files.contentsOfDirectory(atPath: old) {
            let target = (new as NSString).appendingPathComponent(name)
            if !files.fileExists(atPath: target) { try files.copyItem(atPath: (old as NSString).appendingPathComponent(name), toPath: target) }
        }
    }
}

extension DocumentSession {
    /// `files` moved into the attachment folder of the entry at `offset` of `path`, open or
    /// not. A message for the echo area.
    public func attach(_ files: [URL], to path: String, at offset: Int) -> String {
        guard let text = text(of: path) else { return "Can't read \((path as NSString).lastPathComponent)" }
        var entry = Attachments.Entry(text: text, offset: offset, path: path, options: options)
        var names: [String] = []
        var failure: String?
        for file in files {
            do {
                names.append(try Attachments.attach(file, method: .mv, to: &entry).description ?? file.lastPathComponent)
            } catch {
                failure = (error as? Attachments.Failure)?.description ?? error.localizedDescription
                break
            }
        }
        if entry.text != text, case .failed(let message) = perform(ReplaceText(old: text, new: entry.text), path: path, at: offset, expect: nil) {
            return message
        }
        return failure ?? AttachActions.attached(names) ?? "Nothing to attach"
    }
}
