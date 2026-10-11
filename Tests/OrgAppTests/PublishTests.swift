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
}
