import Foundation
import Testing
@testable import OrgCore

struct ArchiveTests {
    static let now = Date(timeIntervalSince1970: 1_789_000_000)
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func context(_ text: String, _ caret: Int) -> EditContext {
        EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], now: Self.now, calendar: Self.utc)
    }

    @Test func destinations() throws {
        let plain = try Archive.destination(context("* a\n", 0), sourcePath: "/n/a.org").get()
        #expect(plain == Archive.Destination(path: "/n/a.org_archive", heading: nil, isSameFile: false))
        let keyword = try Archive.destination(context("#+ARCHIVE: done.org::* %s\n* a\n", 27), sourcePath: "/n/a.org").get()
        #expect(keyword == Archive.Destination(path: "/n/done.org", heading: "* a.org", isSameFile: false))
        let local = try Archive.destination(context("* a\n:PROPERTIES:\n:ARCHIVE: ::* Old\n:END:\n", 0), sourcePath: "/n/a.org").get()
        #expect(local.isSameFile && local.heading == "* Old")
        // org-archive-location, under the keyword and the property.
        var options = EditingOptions.org
        options.archiveLocation = "old/%s::* From %s"
        func optioned(_ text: String, _ caret: Int) -> EditContext {
            EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], now: Self.now, calendar: Self.utc, options: options)
        }
        let global = try Archive.destination(optioned("* a\n", 0), sourcePath: "/n/a.org").get()
        #expect(global == Archive.Destination(path: "/n/old/a.org", heading: "* From a.org", isSameFile: false))
        let overridden = try Archive.destination(optioned("#+ARCHIVE: done.org::\n* a\n", 22), sourcePath: "/n/a.org").get()
        #expect(overridden.path == "/n/done.org" && overridden.heading == nil)
    }

    @Test func archivesToANewFile() throws {
        let text = "* P\n** TODO a :t:\nbody\n** b\n"
        let ctx = context(text, 6)
        let destination = try Archive.destination(ctx, sourcePath: "/n/a.org").get()
        let edits = try Archive.run(ctx, sourcePath: "/n/a.org", destination: destination, archiveText: nil).get()
        #expect(edits.source.edits.reduce(text) { $1.apply(to: $0) } == "* P\n** b\n")
        let archived = try #require(edits.archive).apply(to: "")
        #expect(archived.hasPrefix("\nArchived entries from file /n/a.org\n\n\n* TODO a"))
        #expect(archived.contains(":ARCHIVE_OLPATH: P\n"))
        #expect(archived.contains(":ARCHIVE_TIME: 2026-09-10 Thu 00:26\n"))
    }

    static let sources = [
        "* a\nbody\n* b\n",
        "#+FILETAGS: :f:\n* P :p:\n** TODO a :t:\nbody\n** DONE b\n",
        "* P [1/2]\n** TODO a\n** DONE b\n",
        "#+CATEGORY: work\n* a [[https://x.org][link]]\n* b\n",
        "#+ARCHIVE: ::* Archive\n* a :x:\n* Archive\n** old\n",
        "* P\n:PROPERTIES:\n:ARCHIVE: ::* Old :t:\n:CATEGORY: c\n:END:\n** a\n* Old :t:\n",
        "* a\nSCHEDULED: <2026-01-01 Thu>\n:PROPERTIES:\n:ID: 1\n:END:\n* b",
        "#+ARCHIVE: ::datetree/\n* a\nbody\n* b\n",
        "#+ARCHIVE: %s_archive::datetree/\n* DONE a\nCLOSED: [2026-08-15 Sat 09:00]\n* b\n",
        "#+ARCHIVE: ::datetree/* Notes\n* a\n** sub\n* b\n",
    ]
    static let archives: [String?] = [nil, "", "* existing\n", "\n#+TITLE: arch\n\n* x\n:PROPERTIES:\n:ARCHIVE_TIME: t\n:END:\n\n",
                                      "* 2026\n** 2026-09 September\n*** 2026-09-10 Thursday\n**** prior\n*** 2026-09-12 Saturday\n"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func archiveMatchesEmacs() throws {
        try #require(EmacsOracle.isAvailable)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int, failed: Bool)] = []
        var index = 0
        for source in Self.sources {
            let tree = OrgParser.parse(source)
            let carets = tree.root.descendants().filter { $0.kind == .heading }.flatMap { [$0.range.lowerBound, $0.range.lowerBound + 2] }
            for caret in carets {
                for archiveText in Self.archives {
                    index += 1
                    let path = folder.appendingPathComponent("s\(index).org").path
                    let ctx = context(source, caret)
                    guard case .success(let destination) = Archive.destination(ctx, sourcePath: path) else { continue }
                    if destination.isSameFile, archiveText != nil { continue }
                    let archivePath = destination.path
                    let escaped = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
                    let writeArchive = archiveText.map { "(with-temp-file \"\(escaped(archivePath))\" (insert \"\(escaped($0))\"))" } ?? "(when (file-exists-p \"\(escaped(archivePath))\") (delete-file \"\(escaped(archivePath))\"))"
                    let form = """
                        (let ((p (point)) (src (buffer-string)) s1 s2)
                          \(writeArchive)
                          (with-temp-file "\(escaped(path))" (insert src))
                          (with-current-buffer (find-file-noselect "\(escaped(path))")
                            (org-fold-show-all) (goto-char p)
                            (cl-letf* ((orig (symbol-function 'format-time-string))
                                       ((symbol-function 'format-time-string) (lambda (f &optional time zone) (funcall orig f (or time 1789000000) zone))))
                              (org-archive-subtree))
                            (setq p (point) s1 (buffer-string))
                            (set-buffer-modified-p nil) (kill-buffer))
                          (let ((b (get-file-buffer "\(escaped(archivePath))")))
                            (when b (with-current-buffer b (setq s2 (buffer-string)) (set-buffer-modified-p nil) (kill-buffer))))
                          (erase-buffer) (insert s1 "\\n@@@@\\n" (or s2 "")) (goto-char p))
                        """
                    cases.append(EmacsOracle.Case(text: source, point: EmacsOracle.point(caret, in: source), form: form))
                    let label = "\(caret) in \(source.debugDescription) to \(archiveText.debugDescription)"
                    switch Archive.run(ctx, sourcePath: path, destination: destination, archiveText: archiveText) {
                    case .success(let edits):
                        let newSource = edits.source.edits.reduce(source) { $1.apply(to: $0) }
                        let newArchive = destination.isSameFile ? "" : (edits.archive.map { $0.apply(to: archiveText ?? "") } ?? (archiveText ?? ""))
                        ours.append((label, newSource + "\n@@@@\n" + newArchive, edits.source.selection?.first?.lowerBound ?? caret, false))
                    case .failure:
                        ours.append((label, "", 0, true))
                    }
                }
            }
        }
        var mismatches = 0
        for (mine, emacs) in zip(ours, try EmacsOracle.run(cases)) {
            let failed = !emacs.error.isEmpty
            let caret = EmacsOracle.offset(emacs.point, in: emacs.text)
            guard mine.failed != failed || (!failed && (mine.text != emacs.text || mine.caret != caret)) else { continue }
            mismatches += 1
            if mismatches <= 8 {
                let (a, b) = excerpts(mine.text, emacs.text)
                Issue.record("\(mine.label)\n  ours:  \(mine.failed ? "failed" : "\(a.debugDescription) @\(mine.caret)")\n  emacs: \(failed ? emacs.error : "\(b.debugDescription) @\(caret)")")
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(ours.count) differ")
    }
}
