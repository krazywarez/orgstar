import Foundation
import OrgCore

/// A publishing project from config.toml (`org-publish-project-alist`, ox-publish.el, Org 9.8.7):
///
/// ```toml
/// [[publish]]
/// name = "site"
/// base-directory = "~/notes"
/// publishing-directory = "~/public_html"
/// recursive = true
/// auto-sitemap = true
/// ```
///
/// Other keys: `base-extension` (an Emacs regexp, or `any`), `exclude` (a regexp on the path
/// under the base directory), `include` (file names separated by spaces), `publishing-function`
/// (`org-html-publish-to-html`, `org-md-publish-to-md`, `org-publish-attachment`, separated by
/// spaces), `sitemap-filename`, `sitemap-title`, `sitemap-style` (`tree` or `list`),
/// `sitemap-sort-files` (`alphabetically`, `chronologically`, `anti-chronologically`, `nil`),
/// `sitemap-sort-folders` (`ignore`, `first`, `last`, `nil`), `sitemap-ignore-case`,
/// `body-only`, and `components` (project names separated by spaces) for a project of projects.
public struct PublishProject: Sendable, Equatable {
    public var name: String
    public var baseDirectory = ""
    public var publishingDirectory = ""
    public var baseExtension = "org"
    public var recursive = false
    public var exclude: String?
    public var include: [String] = []
    public var publishingFunctions = ["org-html-publish-to-html"]
    public var autoSitemap = false
    public var sitemapFilename = "sitemap.org"
    public var sitemapTitle: String?
    public var sitemapStyle = "tree"
    public var sitemapSortFiles = "alphabetically"
    public var sitemapSortFolders = "ignore"
    public var sitemapIgnoreCase = false
    public var bodyOnly = false
    public var components: [String] = []

    public init(name: String) { self.name = name }

    public static let functions = ["org-html-publish-to-html", "org-md-publish-to-md", "org-publish-attachment"]
}

public enum Publish {
    /// The `[[publish]]` tables of a config.toml, directories resolved against `root`.
    public static func projects(fromConfig text: String, root: String?) -> (projects: [PublishProject], problems: [String]) {
        guard let tables = try? TOML.parse(text) else { return ([], []) }
        var projects: [PublishProject] = []
        var problems: [String] = []
        for table in tables where table.name == "publish" {
            let v = table.values
            guard let name = v["name"]?.string, !name.isEmpty else {
                problems.append("config.toml line \(table.line): a [[publish]] project needs a name")
                continue
            }
            var p = PublishProject(name: name)
            func words(_ key: String) -> [String]? { v[key]?.string.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) } }
            p.components = words("components") ?? []
            if p.components.isEmpty {
                guard let base = v["base-directory"]?.string, let out = v["publishing-directory"]?.string else {
                    problems.append("config.toml line \(table.line): project \(name) needs base-directory and publishing-directory")
                    continue
                }
                p.baseDirectory = resolve(base, root: root)
                p.publishingDirectory = resolve(out, root: root)
            }
            if let ext = v["base-extension"]?.string { p.baseExtension = ext }
            p.recursive = v["recursive"]?.bool ?? false
            p.exclude = v["exclude"]?.string
            p.include = words("include") ?? []
            if let functions = words("publishing-function") {
                let unknown = functions.filter { !PublishProject.functions.contains($0) }
                if !unknown.isEmpty { problems.append("config.toml line \(table.line): unknown publishing-function \(unknown.joined(separator: " "))") }
                p.publishingFunctions = functions.filter(PublishProject.functions.contains)
            }
            p.autoSitemap = v["auto-sitemap"]?.bool ?? false
            if let s = v["sitemap-filename"]?.string { p.sitemapFilename = s }
            p.sitemapTitle = v["sitemap-title"]?.string
            if let s = v["sitemap-style"]?.string { p.sitemapStyle = s }
            if let s = v["sitemap-sort-files"]?.string { p.sitemapSortFiles = s }
            if let s = v["sitemap-sort-folders"]?.string { p.sitemapSortFolders = s }
            p.sitemapIgnoreCase = v["sitemap-ignore-case"]?.bool ?? false
            p.bodyOnly = v["body-only"]?.bool ?? false
            projects.append(p)
        }
        return (projects, problems)
    }

    /// Absolute, `~/…`, or relative to `root`.
    static func resolve(_ path: String, root: String?) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return ((root ?? NSHomeDirectory()) as NSString).appendingPathComponent(path)
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// `org-publish-expand-projects`: components in place of projects of projects.
    public static func expand(_ chosen: [PublishProject], all: [PublishProject]) throws -> [PublishProject] {
        var rest = chosen
        var out: [PublishProject] = []
        while !rest.isEmpty {
            let p = rest.removeFirst()
            if p.components.isEmpty {
                if !out.contains(where: { $0.name == p.name }) { out.append(p) }
                continue
            }
            rest = try p.components.map { name in
                guard let c = all.first(where: { $0.name == name }) else { throw Failure(description: "Unknown component \"\(name)\" in project \"\(p.name)\"") }
                return c
            } + rest
        }
        return out
    }

    static func directory(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }

    /// `org-publish-get-base-files`: the project's files, its sitemap and `include`.
    public static func baseFiles(_ p: PublishProject) -> [String] {
        let base = directory(p.baseDirectory)
        let pattern = p.baseExtension == "any" ? "" : "^[^.].*\\.(?:" + EmacsRegex.translate(p.baseExtension) + ")$"
        let regex = try? NSRegularExpression(pattern: pattern)
        func matches(_ name: String) -> Bool {
            regex?.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
        }
        var files: [String] = []
        let fm = FileManager.default
        func walk(_ dir: String, depth: Int) {
            guard depth <= 100, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() {
                let path = dir + name
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    if p.recursive { walk(path + "/", depth: depth + 1) }
                } else if matches(name) {
                    files.append(path)
                }
            }
        }
        walk(base, depth: 0)
        if let exclude = p.exclude, let regex = try? NSRegularExpression(pattern: EmacsRegex.translate(exclude)) {
            files.removeAll { file in
                let relative = String(file.dropFirst(base.count))
                return regex.firstMatch(in: relative, range: NSRange(location: 0, length: (relative as NSString).length)) != nil
            }
        }
        if p.autoSitemap { files.append(base + p.sitemapFilename) }
        files += p.include.map { $0.hasPrefix("/") ? $0 : base + $0 }
        var seen: Set<String> = []
        return files.filter { seen.insert($0).inserted }
    }

    // MARK: - Sitemap

    /// `org-publish-find-title`: `#+TITLE`, or the file's base name.
    static func title(_ path: String, read: (String) -> String?) -> String {
        let titles = (read(path) ?? "").matches(of: #/(?mi)^[ \t]*#\+TITLE:[ \t]*(.*?)[ \t]*$/#).map { String($0.1) }
        return titles.isEmpty ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : titles.joined(separator: " ")
    }

    /// `org-publish-find-date`: a timestamp in `#+DATE`, or the modification time.
    static func date(_ path: String, read: (String) -> String?) -> Date {
        if !path.hasSuffix("/"), let text = read(path),
           let line = text.firstMatch(of: #/(?mi)^[ \t]*#\+DATE:[ \t]*(.*?)[ \t]*$/#),
           let m = String(line.1).firstMatch(of: /[<\[][0-9]{4}-[0-9]{2}-[0-9]{2}[^>\]]*[>\]]/), let stamp = Timestamp.parse(m.0) {
            let p = stamp.start
            return Calendar.current.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: p.hour ?? 0, minute: p.minute ?? 0)) ?? Date()
        }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    }

    /// `org-publish-sitemap` with the default entry format and builder: the sitemap's text.
    public static func sitemap(_ p: PublishProject, read: (String) -> String?) -> String {
        let root = directory(p.baseDirectory)
        let sitemapPath = root + p.sitemapFilename
        var files = baseFiles(p).filter { $0 != sitemapPath }
        if !(p.sitemapStyle == "list" && p.sitemapSortFolders == "ignore") {
            var seen: Set<String> = []
            let dirs = files.map { ($0 as NSString).deletingLastPathComponent + "/" }.filter { $0 != root && seen.insert($0).inserted }
            files = dirs + files
        }
        if p.sitemapSortFiles != "nil" || p.sitemapSortFolders != "ignore" {
            files = stableSorted(files) { a, b in before(a, b, p, read: read) }
        }
        func entry(_ path: String) -> String {
            let relative = String(path.dropFirst(root.count))
            if !path.hasSuffix("/") { return "[[file:\(relative)][\(title(path, read: read))]]" }
            return p.sitemapStyle == "tree" ? (String(relative.dropLast()) as NSString).lastPathComponent : relative
        }
        var lines: [String] = []
        if p.sitemapStyle == "list" {
            lines = files.map { "- " + entry($0) }
        } else {
            let filesOnly = files.filter { !$0.hasSuffix("/") }
            let dirs = files.filter { $0.hasSuffix("/") }
            func subtree(_ dir: String, _ indent: String) {
                for f in filesOnly where (f as NSString).deletingLastPathComponent + "/" == dir { lines.append(indent + "- " + entry(f)) }
                for sub in dirs where (String(sub.dropLast()) as NSString).deletingLastPathComponent + "/" == dir {
                    lines.append(indent + "- " + entry(sub))
                    subtree(sub, indent + "  ")
                }
            }
            subtree(root, "")
        }
        return "#+TITLE: " + (p.sitemapTitle ?? "Sitemap for project " + p.name) + "\n\n" + lines.joined(separator: "\n")
    }

    /// The sort predicate of `org-publish-sitemap`: whether `a` goes before `b`.
    static func before(_ a: String, _ b: String, _ p: PublishProject, read: (String) -> String?) -> Bool {
        var result: Bool?
        switch p.sitemapSortFiles {
        case "alphabetically":
            func key(_ path: String) -> String {
                guard path.hasSuffix(".org") else { return path }
                return (path as NSString).deletingLastPathComponent + "/" + title(path, read: read)
            }
            var (x, y) = (key(a), key(b))
            if p.sitemapIgnoreCase { (x, y) = (x.lowercased(), y.lowercased()) }
            result = Array(x.unicodeScalars).lexicographicallyPrecedes(Array(y.unicodeScalars))
        case "chronologically", "anti-chronologically":
            let (x, y) = (date(a, read: read), date(b, read: read))
            result = p.sitemapSortFiles == "chronologically" ? x < y : y < x
        default:
            result = nil
        }
        if p.sitemapSortFolders == "first" || p.sitemapSortFolders == "last" {
            let (da, db) = (a.hasSuffix("/"), b.hasSuffix("/"))
            if da != db { return da == (p.sitemapSortFolders == "first") }
        }
        return result ?? false
    }

    static func stableSorted<T>(_ items: [T], by before: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { x, y in
            if before(x.element, y.element) { return true }
            if before(y.element, x.element) { return false }
            return x.offset < y.offset
        }.map(\.element)
    }

    // MARK: - Publishing

    public struct Report: Equatable {
        public var published: [String] = []
        public var skipped: [String] = []
    }

    /// `org-publish-projects`: each project's sitemap, when it has one, then its files, through
    /// its publishing functions. A file whose output is newer than it is skipped unless `force`.
    /// `export` turns an Org file's text into the HTML or Markdown to write.
    public static func publish(
        _ chosen: [PublishProject], all: [PublishProject], force: Bool = false, only: String? = nil,
        read: (String) -> String?, export: (_ function: String, _ text: String, _ path: String, _ bodyOnly: Bool) -> String
    ) throws -> Report {
        var report = Report()
        let fm = FileManager.default
        for p in try expand(chosen, all: all) {
            let base = directory(p.baseDirectory)
            if p.autoSitemap, only == nil {
                let text = sitemap(p, read: read)
                let path = base + p.sitemapFilename
                if (try? String(contentsOfFile: path, encoding: .utf8)) != text { try text.write(toFile: path, atomically: true, encoding: .utf8) }
            }
            for file in baseFiles(p) where only == nil || only == file {
                let relative = String(file.dropFirst(base.count))
                let outputDirectory = directory(p.publishingDirectory) + ((relative as NSString).deletingLastPathComponent.isEmpty ? "" : (relative as NSString).deletingLastPathComponent + "/")
                for function in p.publishingFunctions {
                    guard let output = try outputPath(file, function: function, in: outputDirectory, read: read) else { continue }
                    if !force, upToDate(output, source: file) {
                        report.skipped.append(file)
                        continue
                    }
                    try fm.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try write(file, to: output, function: function, bodyOnly: p.bodyOnly, read: read, export: export)
                    report.published.append(file)
                }
            }
        }
        return report
    }

    /// Where `function` publishes `file` in `outputDirectory`; nil for an attachment already there.
    private static func outputPath(_ file: String, function: String, in outputDirectory: String, read: (String) -> String?) throws -> String? {
        guard function != "org-publish-attachment" else {
            if directory((file as NSString).deletingLastPathComponent) == outputDirectory { return nil }
            return outputDirectory + (file as NSString).lastPathComponent
        }
        let ext = function == "org-md-publish-to-md" ? "md" : "html"
        guard let text = read(file) else { throw Failure(description: "Can't read \(file)") }
        return ExportScope.output(for: URL(fileURLWithPath: outputDirectory + (file as NSString).lastPathComponent),
                                  name: ExportScope.fileName(text), extension: ext).path
    }

    /// Copies an attachment to `output`, or writes what `function` exports from `file`.
    private static func write(
        _ file: String, to output: String, function: String, bodyOnly: Bool,
        read: (String) -> String?, export: (_ function: String, _ text: String, _ path: String, _ bodyOnly: Bool) -> String
    ) throws {
        let fm = FileManager.default
        if function == "org-publish-attachment" {
            if fm.fileExists(atPath: output) { try fm.removeItem(atPath: output) }
            try fm.copyItem(atPath: file, toPath: output)
        } else {
            try export(function, read(file) ?? "", file, bodyOnly).write(toFile: output, atomically: true, encoding: .utf8)
        }
    }

    static func upToDate(_ output: String, source: String) -> Bool {
        let fm = FileManager.default
        guard let out = try? fm.attributesOfItem(atPath: output)[.modificationDate] as? Date,
              let src = try? fm.attributesOfItem(atPath: source)[.modificationDate] as? Date else { return false }
        return out >= src
    }

    /// The projects publishing `path`, not counting projects of projects.
    public static func projects(containing path: String, in all: [PublishProject]) -> [PublishProject] {
        all.filter { $0.components.isEmpty && baseFiles($0).contains(path) }
    }
}
