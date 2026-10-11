import Foundation
import OrgCore

/// org-roam-dailies (org-roam 2.3): a file a day in `org-roam-dailies-directory` under
/// `org-roam-directory`, named and started as its default capture template does,
/// `%<%Y-%m-%d>.org` with `#+title: %<%Y-%m-%d>`, and an ID like any new org-roam file.
public struct Dailies: Sendable, Equatable {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// The folder the daily files are in.
    public var directory: String
    /// The file name, with `%<…>` for the date.
    public var file: String
    /// What a new file starts with.
    public var head: String
    /// What Capture to Daily adds, an org-capture template.
    public var entry: String

    public init(directory: String, file: String = "%<%Y-%m-%d>.org", head: String = "#+title: %<%Y-%m-%d>\n", entry: String = "* %?") {
        self.directory = directory
        self.file = file
        self.head = head
        self.entry = entry
    }

    /// The settings' dailies: `org-roam-directory`, by default the first folder, and
    /// `org-roam-dailies-directory` in it. Nil without a folder.
    public static func configured(roots: [String], defaults: UserDefaults = .standard) -> Dailies? {
        let roam = OrgPreferences.roamDirectory(defaults)
        guard let base = roam.isEmpty ? roots.first : OrgAttach.expand(roam, in: roots.first ?? NSHomeDirectory()) else { return nil }
        return Dailies(directory: OrgAttach.expand(OrgPreferences.dailiesDirectory(defaults), in: base),
                       file: OrgPreferences.dailiesFile(defaults), head: OrgPreferences.dailiesHead(defaults), entry: OrgPreferences.dailiesEntry(defaults))
    }

    /// `format-time-string` for each `%<format>`, in the local time zone.
    public static func expandTime(_ template: String, _ day: Date) -> String {
        template.replacing(/%<([^>]*)>/) { strftime(String($0.1), day) }
    }

    static func strftime(_ format: String, _ date: Date) -> String {
        var time = time_t(date.timeIntervalSince1970)
        var parts = tm()
        localtime_r(&time, &parts)
        var buffer = [CChar](repeating: 0, count: 256)
        let count = Darwin.strftime(&buffer, buffer.count, format, &parts)
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func path(for day: Date) -> String {
        OrgAttach.expand(Self.expandTime(file, day).trimmingCharacters(in: .whitespaces), in: directory)
    }

    /// The file's text when it's new: the head, ending in a newline, under a property drawer
    /// with the ID, as `org-entry-put` puts it at the start.
    public func newText(_ day: Date, id: String) -> String {
        var text = Self.expandTime(head, day)
        if !text.hasSuffix("\n") { text += "\n" }
        return OrgAttach.ensuringID(text, at: 0) { id }.text
    }

    /// The daily file for `day`, made when missing. True when it's new.
    @discardableResult
    public func ensure(_ day: Date, id: () -> String = { UUID().uuidString.lowercased() }) throws -> (path: String, created: Bool) {
        let path = path(for: day)
        guard !FileManager.default.fileExists(atPath: path) else { return (path, false) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try newText(day, id: id()).write(toFile: path, atomically: true, encoding: .utf8)
        return (path, true)
    }

    /// `org-roam-dailies--list-files`: the org files in the folder and below, without hidden,
    /// backup and auto-save files, sorted.
    public func files() -> [String] {
        let paths = (FileManager.default.enumerator(atPath: directory)?.allObjects as? [String]) ?? []
        return paths.compactMap { relative -> String? in
            let name = (relative as NSString).lastPathComponent
            guard (relative as NSString).pathExtension == "org", !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  !name.hasPrefix("#"), !name.hasSuffix("~") else { return nil }
            return (directory as NSString).appendingPathComponent(relative)
        }.sorted()
    }

    /// `org-roam-dailies-goto-next-note` from the daily file at `path`, `n` notes on
    /// (back for negative `n`).
    public func neighbor(of path: String, by n: Int) throws -> String {
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        guard real(path).hasPrefix(real(directory) + "/") else { throw Failure("Not in a daily-note") }
        let all = files()
        guard let position = all.map(real).firstIndex(of: real(path)) else { throw Failure("Can't find current note file - have you saved it yet?") }
        if n >= 0, position == all.count - 1 { throw Failure("Already at newest note") }
        if n < 0, position == 0 { throw Failure("Already at oldest note") }
        return all[min(max(position + n, 0), all.count - 1)]
    }
}
