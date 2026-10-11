import Foundation
import OrgCore
import OrgDocument
import OrgIndex
import OrgPresentation

/// `org-refile-targets`, `org-refile-use-outline-path` and
/// `org-refile-allow-creating-parent-nodes` (Org 9.8.7).
public struct RefileSettings: Sendable, Equatable {
    /// Where an `org-refile-targets` entry looks.
    public enum Files: Sendable, Equatable {
        /// `nil`: the file refiled from.
        case current
        case agendaFiles
        case paths([String])
        /// Every org file in the folders: orgstar's default.
        case workspace
    }

    /// Which headings an entry offers.
    public enum Spec: Sendable, Equatable {
        /// `t`: every heading.
        case all
        case tag(String), todo(String)
        /// An Emacs regexp.
        case regexp(String)
        case level(Int), maxLevel(Int)
    }

    public struct Target: Sendable, Equatable {
        public var files: Files
        public var spec: Spec

        public init(files: Files, spec: Spec) {
            self.files = files
            self.spec = spec
        }
    }

    public enum OutlinePath: String, Sendable, CaseIterable {
        case none = "nil", full = "t", file, fullFilePath = "full-file-path", bufferName = "buffer-name", title
    }

    public enum Creating: String, Sendable, CaseIterable {
        case no = "nil", yes = "t", confirm
    }

    public enum Failure: Error, Equatable {
        case message(String)
    }

    public var targets: [Target]
    public var outlinePath: OutlinePath
    public var creating: Creating

    /// Headings down to level 3 in every file, as orgstar offers with no `org-refile-targets`.
    public static let workspaceTargets = [Target(files: .workspace, spec: .maxLevel(3))]

    public init(targets: [Target] = workspaceTargets, outlinePath: OutlinePath = .file, creating: Creating = .no) {
        self.targets = targets
        self.outlinePath = outlinePath
        self.creating = creating
    }

    /// An `org-refile-targets` value as Lisp writes it: `((nil :maxlevel . 3)
    /// (org-agenda-files :tag . "project") ("~/notes/x.org" :level . 1))`. Empty text is
    /// orgstar's default.
    public static func parseTargets(_ text: String) -> Result<[Target], Failure> {
        guard text.contains(where: { !$0.isWhitespace }) else { return .success(workspaceTargets) }
        let value: Sexp
        do {
            guard let form = try LispReader.read(text).first?.sexp else { return .success(workspaceTargets) }
            value = form
        } catch {
            return .failure(.message("can't read \(text)"))
        }
        func unquote(_ s: Sexp) -> Sexp {
            if case .list(let items) = s, items.count == 2, items[0].symbol == "quote" { return items[1] }
            return s
        }
        guard let entries = unquote(value).elements else { return .failure(.message("not a list of targets")) }
        var targets: [Target] = []
        for entry in entries {
            // `(FILES . (KEY . VALUE))`, read as `(FILES KEY . VALUE)`, or `(FILES KEY VALUE)`.
            let head: Sexp
            var key: String?
            var argument: Sexp?
            switch entry {
            case .dotted(let items, let last) where items.count == 2:
                head = items[0]
                key = items[1].symbol
                argument = last
            case .list(let items) where items.count == 3:
                head = items[0]
                key = items[1].symbol
                argument = items[2]
            case .dotted(let items, let last) where items.count == 1 && last.symbol == "t":
                head = items[0]
                key = "t"
            default:
                return .failure(.message("\(entry.description) isn't a target"))
            }
            let files: Files
            switch head {
            case .symbol("nil"): files = .current
            case .symbol("org-agenda-files"): files = .agendaFiles
            case .string(let path): files = .paths([path])
            case .list(let items) where items.allSatisfy({ $0.string != nil }): files = .paths(items.compactMap(\.string))
            default: return .failure(.message("files \(head.description) aren't supported"))
            }
            let spec: Spec
            switch (key, argument) {
            case ("t"?, _): spec = .all
            case (":tag"?, .string(let s)?): spec = .tag(s)
            case (":todo"?, .string(let s)?): spec = .todo(s)
            case (":regexp"?, .string(let s)?): spec = .regexp(s)
            case (":level"?, .integer(let n)?): spec = .level(n)
            case (":maxlevel"?, .integer(let n)?): spec = .maxLevel(n)
            default: return .failure(.message("\(entry.description) isn't a target"))
            }
            targets.append(Target(files: files, spec: spec))
        }
        return .success(targets)
    }

    /// For an answer that isn't a target, `parent/child` with `parent` one: the target and the
    /// new heading's title, as `org-refile-get-location` splits it.
    public static func newNode(_ answer: String, in targets: [RefileTarget]) -> (parent: RefileTarget, child: String)? {
        guard let m = answer.firstMatch(of: /^(.*)\/([^\/]+)$/) else { return nil }
        let parent = String(m.1).replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        let child = String(m.2).trimmingCharacters(in: .whitespaces)
        guard !child.isEmpty, let target = targets.first(where: { $0.label == parent }) else { return nil }
        return (target, child)
    }

    /// `org-refile-get-targets`'s `descre` for `spec`, in Emacs syntax.
    static func regexp(_ spec: Spec) -> String {
        func quote(_ s: String) -> String { s.map { "[*.\\?+^$".contains($0) ? "\\" + String($0) : String($0) }.joined() }
        switch spec {
        case .all: return "^\\*+[ \t]"
        case .tag(let tag): return "^\\*+[ \t]+.*?:" + quote(tag) + ":"
        case .todo(let keyword): return "^\\*+[ \t]+" + quote(keyword) + "[ \t]"
        case .regexp(let re): return re
        case .level(let n): return "^\\*\\{\(n)\\}[ \t]"
        case .maxLevel(let n): return "^\\*\\{1,\(n)\\}[ \t]"
        }
    }
}

extension WorkspaceModel {
    /// The refile targets, as `org-refile-get-targets` lists them for `settings`: entry by
    /// entry, file by file, in buffer order, with a file's own target first when the outline
    /// path starts with the file. `openPath` is the file refiled from, read from `document`.
    public func refileTargets(openPath: String?, document: DocumentState?, settings: RefileSettings = OrgPreferences.refileSettings()) -> [RefileTarget] {
        var targets: [RefileTarget] = []
        var seen: Set<String> = []
        func add(_ target: RefileTarget) {
            if seen.insert("\(target.path)\u{0}\(target.start ?? -1)\u{0}\(target.label)").inserted { targets.append(target) }
        }
        let orgFiles = files.filter { $0.kind == .org }
        let relative = Dictionary(orgFiles.map { ($0.path, $0.relativePath) }, uniquingKeysWith: { a, _ in a })
        // Closed files' headings, from the index, for the targets that go by level.
        let levels = settings.targets.compactMap { target -> Int? in
            switch target.spec {
            case .all: Int.max
            case .level(let n), .maxLevel(let n): n
            default: nil
            }
        }
        let indexed = levels.isEmpty ? [] : (try? index.outline(maxLevel: min(levels.max()!, 1000))) ?? []
        let indexedByPath = Dictionary(grouping: indexed, by: \.location.path)
        for entry in settings.targets {
            let paths: [String]
            switch entry.files {
            case .current: paths = openPath.map { [$0] } ?? []
            case .workspace: paths = orgFiles.map(\.path)
            case .agendaFiles:
                let list = OrgPreferences.agendaFiles()
                if list.isEmpty {
                    let subfolders = OrgPreferences.agendaSubfolders()
                    paths = orgFiles.filter { !$0.name.hasPrefix(".") && (subfolders || !$0.relativePath.contains("/")) }.map(\.path).sorted()
                } else {
                    paths = AgendaFiles.resolve(list, base: rootPaths.first)
                }
            case .paths(let list):
                let base = openPath.map { ($0 as NSString).deletingLastPathComponent } ?? rootPaths.first
                paths = list.map { entry in
                    let path = (entry as NSString).expandingTildeInPath
                    return ((path.hasPrefix("/") || base == nil ? path : (base! as NSString).appendingPathComponent(path)) as NSString).standardizingPath
                }
            }
            for path in paths {
                let name = relative[path] ?? (path as NSString).lastPathComponent
                // The headings: from the buffer, the index, or the file's text.
                var text: String?
                var hash: String
                var headings: [(start: Int, level: Int, path: [String])] = []
                if path == openPath, let document {
                    text = document.text
                    hash = FileRecord.hash(document.mergeBase)
                } else if let level = Self.level(entry.spec), let records = indexedByPath[path] {
                    hash = records.first?.location.contentHash ?? ""
                    headings = records.filter { level($0.level) }.map { ($0.location.start, $0.level, $0.outlinePath) }
                } else {
                    guard let data = FileManager.default.contents(atPath: path) else { continue }
                    let state = DocumentState(bytes: [UInt8](data))
                    text = state.text
                    hash = FileRecord.hash(state.mergeBase)
                }
                if let text {
                    headings = Self.headings(text, spec: entry.spec)
                }
                let base: String? = switch settings.outlinePath {
                case .file, .bufferName: name
                case .fullFilePath: path
                case .title: text.flatMap { Self.fileTitle($0) } ?? Self.diskTitle(path) ?? name
                case .none, .full: nil
                }
                // Targets in other files name the file after them, but not with paths that start with it.
                let elsewhere = path != openPath && [.none, .full, .bufferName].contains(settings.outlinePath)
                let suffix = elsewhere ? " (\((path as NSString).lastPathComponent))" : ""
                if let base, settings.outlinePath != .none, settings.outlinePath != .full {
                    add(RefileTarget(label: base + suffix, path: path, start: nil, title: "", level: 0, contentHash: hash))
                }
                for heading in headings {
                    let escaped = heading.path.map { $0.replacingOccurrences(of: "/", with: "\\/") }
                    var label = settings.outlinePath == .none ? heading.path.last ?? "" : ((base.map { [$0] } ?? []) + escaped).joined(separator: "/")
                    label += suffix
                    add(RefileTarget(label: label, path: path, start: heading.start, title: heading.path.last ?? "", level: heading.level, contentHash: hash))
                }
            }
        }
        return targets
    }

    /// The test a level-based spec makes of a heading's level; nil for the others.
    static func level(_ spec: RefileSettings.Spec) -> ((Int) -> Bool)? {
        switch spec {
        case .all: { _ in true }
        case .level(let n): { $0 == n }
        case .maxLevel(let n): { $0 <= n }
        default: nil
        }
    }

    /// The headings `spec` finds in `text`, as `org-refile-get-targets` searches: each match
    /// of its regexp (case-sensitive) on a heading line gives that heading.
    static func headings(_ text: String, spec: RefileSettings.Spec) -> [(start: Int, level: Int, path: [String])] {
        let outline = Presentation.outline(OrgParser.parse(text))
        var paths: [[String]] = []
        for entry in outline { paths.append((entry.parent.map { paths[$0] } ?? []) + [entry.title]) }
        let byStart = Dictionary(outline.indices.map { (outline[$0].start, $0) }, uniquingKeysWith: { a, _ in a })
        guard let regex = try? NSRegularExpression(pattern: EmacsRegex.translate(RefileSettings.regexp(spec)), options: .anchorsMatchLines) else { return [] }
        let ns = text as NSString
        var found: [(Int, Int, [String])] = []
        var at = 0
        while at <= ns.length, let m = regex.firstMatch(in: text, options: [.withoutAnchoringBounds, .withTransparentBounds], range: NSRange(location: at, length: ns.length - at)) {
            let end = NSMaxRange(m.range)
            let line = ns.lineRange(for: NSRange(location: min(end, max(0, ns.length - 1)), length: 0))
            let lineStart = end == ns.length && end > 0 && ns.character(at: end - 1) == 10 ? end : line.location
            if let index = byStart[lineStart] {
                found.append((lineStart, outline[index].level, paths[index]))
                var lineEnd = NSMaxRange(line)
                if lineEnd > line.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
                at = max(lineEnd, end, at + 1)
            } else {
                at = max(end, at + 1)
            }
        }
        return found
    }

    /// `org-get-title`: the `#+TITLE` lines joined.
    static func fileTitle(_ text: String) -> String? {
        let titles = text.components(separatedBy: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "^#\\+(?i:title):[ \\t]*", options: .regularExpression) else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return titles.isEmpty ? nil : titles.joined(separator: " ")
    }

    static func diskTitle(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }.flatMap { fileTitle($0) }
    }
}
