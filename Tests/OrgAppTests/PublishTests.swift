import Foundation
import Testing
@testable import OrgApp
import OrgCore

/// `org-publish` against Emacs: sitemaps and the files published.
struct PublishTests {
    static let files: [(String, String, TimeInterval)] = [
        ("a.org", "#+TITLE: Zeta page\n#+DATE: <2026-01-05 Mon>\n* H\nText [[file:sub/b.org][b]].\n", 1_780_000_000),
        ("b2.org", "#+TITLE: Alpha\n", 1_780_000_300),
        ("sub/b.org", "#+TITLE: Beta\n#+TITLE: two\n* B\n", 1_780_000_200),
        ("sub/deep/c.org", "no title\n", 1_780_000_100),
        ("other/z.org", "#+TITLE: alpha lower\n", 1_780_000_400),
        ("draft-x.org", "#+TITLE: Draft\n", 1_780_000_500),
        ("style.css", "body{}", 1_780_000_600),
        ("img/logo.png", "png", 1_780_000_700),
        (".hidden.org", "#+TITLE: Hidden\n", 1_780_000_800),
    ]

    static func tree(_ folder: URL) throws {
        for (path, text, time) in files {
            let url = folder.appendingPathComponent("src").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
        }
    }

    /// Projects as config.toml writes them and as Lisp, over `folder`.
    static func projects(_ folder: String) -> (toml: String, lisp: String) {
        let toml = """
        fill-column = 80

        [[publish]]
        name = "site"
        base-directory = "\(folder)/src"
        publishing-directory = "\(folder)/out"
        recursive = true
        exclude = "^draft-"
        auto-sitemap = true
        sitemap-title = "Site"

        [[publish]]
        name = "list"
        base-directory = "\(folder)/src"
        publishing-directory = "\(folder)/out2"
        recursive = true
        auto-sitemap = true
        sitemap-filename = "index.org"
        sitemap-style = "list"
        sitemap-sort-folders = "first"

        [[publish]]
        name = "dated"
        base-directory = "\(folder)/src"
        publishing-directory = "\(folder)/out3"
        include = "sub/b.org"
        auto-sitemap = true
        sitemap-filename = "dated.org"
        sitemap-style = "list"
        sitemap-sort-files = "anti-chronologically"
        publishing-function = "org-md-publish-to-md"

        [[publish]]
        name = "static"
        base-directory = "\(folder)/src"
        base-extension = "css\\\\|png"
        recursive = true
        publishing-directory = "\(folder)/out"
        publishing-function = "org-publish-attachment"

        [[publish]]
        name = "all"
        components = "site list dated static"
        """
        let lisp = """
        '(("site" :base-directory "\(folder)/src" :publishing-directory "\(folder)/out" :recursive t :exclude "^draft-" :auto-sitemap t :sitemap-title "Site")
          ("list" :base-directory "\(folder)/src" :publishing-directory "\(folder)/out2" :recursive t :auto-sitemap t :sitemap-filename "index.org" :sitemap-style list :sitemap-sort-folders first)
          ("dated" :base-directory "\(folder)/src" :publishing-directory "\(folder)/out3" :include ("sub/b.org") :auto-sitemap t :sitemap-filename "dated.org" :sitemap-style list :sitemap-sort-files anti-chronologically :publishing-function org-md-publish-to-md)
          ("static" :base-directory "\(folder)/src" :base-extension "css\\\\|png" :recursive t :publishing-directory "\(folder)/out" :publishing-function org-publish-attachment)
          ("all" :components ("site" "list" "dated" "static")))
        """
        return (toml, lisp)
    }

    static func listing(_ folder: URL) -> [String] {
        let base = folder.path + "/"
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        var out: [String] = []
        while let path = enumerator?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: base + path, isDirectory: &isDirectory), !isDirectory.boolValue, !path.hasPrefix("ts/") { out.append(path) }
        }
        return out.sorted()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func publishesLikeOrg() throws {
        let emacsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-publish-e-\(UUID().uuidString)").resolvingSymlinksInPath()
        let ourFolder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-publish-o-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer {
            try? FileManager.default.removeItem(at: emacsFolder)
            try? FileManager.default.removeItem(at: ourFolder)
        }
        try Self.tree(emacsFolder)
        try Self.tree(ourFolder)
        let form = """
        (progn
          (require 'ox-publish) (require 'ox-md)
          (setq org-publish-timestamp-directory "\(emacsFolder.path)/ts/"
                org-publish-project-alist \(Self.projects(emacsFolder.path).lisp))
          (org-publish "all" t))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "--eval", form]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let log = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: log, as: UTF8.self))")

        let loaded = Publish.projects(fromConfig: Self.projects(ourFolder.path).toml, root: nil)
        #expect(loaded.problems.isEmpty, "\(loaded.problems)")
        let read = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        let all = loaded.projects.first { $0.name == "all" }!
        let report = try Publish.publish([all], all: loaded.projects, force: true, read: read) { function, text, _, _ in function + "\n" + text }
        #expect(!report.published.isEmpty)
        for name in ["sitemap.org", "index.org", "dated.org"] {
            let theirs = try String(contentsOf: emacsFolder.appendingPathComponent("src/" + name), encoding: .utf8)
            let ours = try String(contentsOf: ourFolder.appendingPathComponent("src/" + name), encoding: .utf8)
            #expect(ours == theirs, "\(name)\nours:\n\(ours)\nemacs:\n\(theirs)")
        }
        #expect(Self.listing(ourFolder) == Self.listing(emacsFolder))
    }

    /// `org-latex-publish-to-latex`: the same `.tex` files as Emacs writes, the `% Created`
    /// line and the labels aside.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func publishesLaTeXLikeOrg() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-publish-tex-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = ["a.org": "#+TITLE: A\n* One\nText with a [[https://orgmode.org][link]].\n", "sub/b.org": "#+OPTIONS: toc:nil\n- item\n- [X] done\n"]
        for (path, text) in sources {
            let url = folder.appendingPathComponent("src/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let form = """
        (progn
          (require 'ox-publish) (require 'ox-latex)
          (setq user-full-name "A. Writer"
                org-publish-timestamp-directory "\(folder.path)/ts/"
                org-publish-project-alist '(("tex" :base-directory "\(folder.path)/src" :publishing-directory "\(folder.path)/emacs"
                                             :recursive t :publishing-function org-latex-publish-to-latex)))
          (org-publish "tex" t))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "--eval", form]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let toml = """
        [[publish]]
        name = "tex"
        base-directory = "\(folder.path)/src"
        publishing-directory = "\(folder.path)/ours"
        recursive = true
        publishing-function = "org-latex-publish-to-latex"
        """
        let loaded = Publish.projects(fromConfig: toml, root: nil)
        #expect(loaded.problems.isEmpty, "\(loaded.problems)")
        let read = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        let report = try Publish.publish(loaded.projects, all: loaded.projects, force: true, read: read) { _, text, path, bodyOnly in
            try LaTeXExport.document(text, path: path, bodyOnly: bodyOnly, author: "A. Writer", file: true)
        }
        #expect(report.published.count == 2)
        func normalized(_ s: String) -> String {
            var labels: [String: String] = [:]
            return s.replacing(#/(?m)^% Created .*\n/#, with: "").replacing(#/org[0-9a-f]{7}/#) { m in
                let key = String(m.output)
                if labels[key] == nil { labels[key] = "org\(labels.count + 1)" }
                return labels[key]!
            }
        }
        for path in ["a.tex", "sub/b.tex"] {
            let theirs = try String(contentsOf: folder.appendingPathComponent("emacs/" + path), encoding: .utf8)
            let ours = try String(contentsOf: folder.appendingPathComponent("ours/" + path), encoding: .utf8)
            #expect(normalized(ours) == normalized(theirs), "\(path)\nours:\n\(ours)\nemacs:\n\(theirs)")
        }
    }

    /// `org-ascii-publish-to-ascii`: the same `.txt` files as Emacs writes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func publishesASCIILikeOrg() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-publish-txt-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = ["a.org": "#+TITLE: A\n* One\nText with a [[https://orgmode.org][link]].\n| x | y |\n", "sub/b.org": "#+OPTIONS: toc:nil\n- item\n- [X] done\n"]
        for (path, text) in sources {
            let url = folder.appendingPathComponent("src/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let form = """
        (progn
          (require 'ox-publish) (require 'ox-ascii)
          (setq user-full-name "A. Writer"
                org-publish-timestamp-directory "\(folder.path)/ts/"
                org-publish-project-alist '(("txt" :base-directory "\(folder.path)/src" :publishing-directory "\(folder.path)/emacs"
                                             :recursive t :publishing-function org-ascii-publish-to-ascii)))
          (org-publish "txt" t))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "--eval", form]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let toml = """
        [[publish]]
        name = "txt"
        base-directory = "\(folder.path)/src"
        publishing-directory = "\(folder.path)/ours"
        recursive = true
        publishing-function = "org-ascii-publish-to-ascii"
        """
        let loaded = Publish.projects(fromConfig: toml, root: nil)
        #expect(loaded.problems.isEmpty, "\(loaded.problems)")
        let read = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        let report = try Publish.publish(loaded.projects, all: loaded.projects, force: true, read: read) { _, text, path, bodyOnly in
            try ASCIIExport.document(text, path: path, bodyOnly: bodyOnly, author: "A. Writer", file: true)
        }
        #expect(report.published.count == 2)
        for path in ["a.txt", "sub/b.txt"] {
            let theirs = try String(contentsOf: folder.appendingPathComponent("emacs/" + path), encoding: .utf8)
            let ours = try String(contentsOf: folder.appendingPathComponent("ours/" + path), encoding: .utf8)
            #expect(ours == theirs, "\(path)\nours:\n\(ours)\nemacs:\n\(theirs)")
        }
    }

    /// `org-odt-publish-to-odt` writes `.odt` files, which the export closure doesn't see.
    @Test func publishesODT() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-publish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.tree(folder)
        let config = "[[publish]]\nname = \"odt\"\nbase-directory = \"\(folder.path)/src\"\npublishing-directory = \"\(folder.path)/odt\"\npublishing-function = \"org-odt-publish-to-odt\"\n"
        let loaded = Publish.projects(fromConfig: config, root: nil)
        #expect(loaded.problems.isEmpty)
        let read = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        let report = try Publish.publish(loaded.projects, all: loaded.projects, read: read) { _, _, _, _ in Issue.record("exported as text"); return "" }
        #expect(report.published.count == 3)
        let data = try Data(contentsOf: folder.appendingPathComponent("odt/a.odt"))
        #expect(data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
    }

    /// The ODT author comes from the caller: iOS passes none, as its Export menu does.
    @Test func publishesODTWithTheCallersAuthor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-publish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.tree(folder)
        let config = "[[publish]]\nname = \"odt\"\nbase-directory = \"\(folder.path)/src\"\npublishing-directory = \"\(folder.path)/odt\"\npublishing-function = \"org-odt-publish-to-odt\"\n"
        let loaded = Publish.projects(fromConfig: config, root: nil)
        let read = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        let odt = folder.appendingPathComponent("odt/a.odt")
        _ = try Publish.publish(loaded.projects, all: loaded.projects, author: "Quill Writer", read: read) { _, _, _, _ in "" }
        #expect(try Data(contentsOf: odt).range(of: Data("Quill Writer".utf8)) != nil)
        _ = try Publish.publish(loaded.projects, all: loaded.projects, force: true, author: "", read: read) { _, _, _, _ in "" }
        #expect(try Data(contentsOf: odt).range(of: Data("Quill Writer".utf8)) == nil)
    }

    @Test func skipsUpToDateFilesAndFindsProjects() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-publish-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.tree(folder)
        let loaded = Publish.projects(fromConfig: Self.projects(folder.path).toml, root: nil)
        let site = loaded.projects.first { $0.name == "site" }!
        let read = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        let first = try Publish.publish([site], all: loaded.projects, read: read) { _, text, _, _ in text }
        let second = try Publish.publish([site], all: loaded.projects, read: read) { _, text, _, _ in text }
        #expect(!first.published.isEmpty && second.published.isEmpty && second.skipped.count == first.published.count)
        let a = folder.path + "/src/a.org"
        #expect(Publish.projects(containing: a, in: loaded.projects).map(\.name) == ["site", "list", "dated"])
        let one = try Publish.publish([site], all: loaded.projects, force: true, only: a, read: read) { _, text, _, _ in text }
        #expect(one.published == [a])
        #expect(Publish.projects(fromConfig: "[[publish]]\nname = \"x\"\n", root: nil).problems.count == 1)
        #expect(throws: Publish.Failure.self) { try Publish.expand([PublishProject(name: "m")].map { var p = $0; p.components = ["nope"]; return p }, all: []) }
    }

    /// The exporter both apps publish with: each function's format, and the file named in a
    /// refusal.
    @Test func exportsByFunction() throws {
        let path = "/notes/a.org"
        let text = "#+TITLE: A\n* One\nText.\n"
        func export(_ function: String) throws -> String {
            try Publish.export(function, text: text, path: path, bodyOnly: false, settings: .default, codeStyle: nil, author: "A. Writer", language: "en")
        }
        #expect(try export("org-html-publish-to-html").contains("<title>A</title>"))
        #expect(try export("org-md-publish-to-md").contains("# One"))
        #expect(try export("org-latex-publish-to-latex").contains("\\title{A}"))
        #expect(try export("org-ascii-publish-to-ascii").contains("1 One"))
        #expect(throws: LaTeXExport.Unsupported(reason: "Can't export a.org to LaTeX: Radio targets")) {
            try Publish.export("org-latex-publish-to-latex", text: "<<<radio>>> radio\n", path: path, bodyOnly: false, settings: .default, codeStyle: nil, author: "", language: "en")
        }
    }
}

/// Publishing on iOS: a project that publishes outside the app's folders writes to the folder
/// chosen for it, kept as a bookmark.
@MainActor
struct PublishFoldersTests {
    @Test func publishesToTheBookmarkedFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-publish-ios-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try PublishTests.tree(folder)
        let chosen = folder.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let config = """
        [[publish]]
        name = "site"
        base-directory = "src"
        publishing-directory = "~/public_html"

        [[publish]]
        name = "inside"
        base-directory = "src"
        publishing-directory = "src/out"

        [[publish]]
        name = "both"
        components = "site inside"
        """
        let root = folder.path
        let loaded = Publish.projects(fromConfig: config, root: root)
        let defaults = UserDefaults(suiteName: "orgstar-publish-\(UUID().uuidString)")!
        let folders = PublishFolders(defaults: defaults, sandboxed: false)
        let both = loaded.projects.first { $0.name == "both" }!
        #expect(try folders.needed([both], all: loaded.projects, roots: [root]).map(\.name) == ["site"])
        #expect(folders.set(chosen, for: "site"))

        // After a relaunch, the bookmark gives the folder back.
        let again = PublishFolders(defaults: defaults, sandboxed: false)
        #expect(again.folder(for: "site")?.standardizedFileURL == chosen.standardizedFileURL)
        #expect(try again.needed([both], all: loaded.projects, roots: [root]).isEmpty)
        let projects = again.applied(to: loaded.projects)
        let site = projects.first { $0.name == "site" }!
        #expect(URL(fileURLWithPath: site.publishingDirectory).standardizedFileURL == chosen.standardizedFileURL)
        #expect(projects.first { $0.name == "inside" }?.publishingDirectory == root + "/src/out")
        let read = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        let report = try Publish.publish([site], all: projects, read: read) { _, text, _, _ in text }
        #expect(!report.published.isEmpty)
        #expect(FileManager.default.fileExists(atPath: chosen.appendingPathComponent("a.html").path))
    }
}
