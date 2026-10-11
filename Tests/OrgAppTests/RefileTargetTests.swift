import Foundation
import Testing
@testable import OrgApp
import OrgCore
import OrgDocument

/// `org-refile-get-targets` against Emacs.
@MainActor
struct RefileTargetTests {
    static let files = [
        ("a.org", "* Projects :proj:\n** TODO Website\n*** Plan the copy\n** Taxes/2026\n* NEXT Write report\n* Notes\n"),
        ("b.org", "* Inbox\n** Plan ahead :proj:\n* Someday\n** NEXT Read\n"),
        ("sub/x.org", "#+TITLE: Extra file\n* Deep\n** Deeper\n"),
    ]

    static var emacs: String { ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs" }

    /// Emacs's labels as `org-refile-get-location` shows them, without the `/` it adds for
    /// completion, with the file and the heading's start (0-based) of each.
    static func emacsTargets(_ folder: URL, targets: String, mode: String) throws -> [String] {
        let form = """
        (progn
          (require 'org) (require 'org-refile) (require 'json)
          (let* ((dir "\(folder.path)/")
                 (a (expand-file-name "a.org" dir)))
            (setq org-agenda-files (list a (expand-file-name "b.org" dir)))
            (with-current-buffer (find-file-noselect a)
              (let* ((org-refile-targets '\(targets))
                     (org-refile-use-outline-path '\(mode))
                     (extra (if org-refile-use-outline-path "/" ""))
                     (out nil))
                (dolist (x (org-refile-get-targets))
                  (let ((label (if (and (not (memq org-refile-use-outline-path '(file full-file-path title)))
                                        (not (equal (file-truename a) (file-truename (nth 1 x)))))
                                   (concat (car x) " (" (file-name-nondirectory (nth 1 x)) ")")
                                 (car x))))
                    (push (format "%s | %s | %s" label (file-name-nondirectory (nth 1 x))
                                  (let ((p (nth 3 x))) (if p (1- (if (markerp p) (marker-position p) p)) "-")))
                          out)))
                (princ (json-encode (nreverse out)))))))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [emacs, "-Q", "--batch", "--eval", form]
        let pipe = Pipe()
        process.standardOutput = pipe
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            Issue.record("Emacs printed \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
            return []
        }
        return decoded
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func targetsLikeOrg() async throws {
        let notes = try Folder()
        for (name, text) in Self.files { try notes.write(name, text) }
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let a = notes.url.appendingPathComponent("a.org").standardizedFileURL.path
        let document = DocumentState(bytes: Array(Self.files[0].1.utf8))
        let cases: [(String, String)] = [
            ("((nil :maxlevel . 2))", "file"),
            ("((org-agenda-files :level . 2))", "t"),
            ("((nil :tag . \"proj\") (org-agenda-files :todo . \"NEXT\"))", "nil"),
            ("((org-agenda-files :regexp . \"Plan\"))", "buffer-name"),
            ("((\"sub/x.org\" :maxlevel . 9) (nil . t))", "title"),
            ("((org-agenda-files :maxlevel . 1))", "file"),
        ]
        for (targets, mode) in cases {
            let parsed = try RefileSettings.parseTargets(targets).get()
            let settings = RefileSettings(targets: parsed, outlinePath: RefileSettings.OutlinePath(rawValue: mode)!)
            let ours = workspace.refileTargets(openPath: a, document: document, settings: settings).map {
                "\($0.label) | \(($0.path as NSString).lastPathComponent) | \($0.start.map(String.init) ?? "-")"
            }
            let theirs = try Self.emacsTargets(notes.url, targets: targets, mode: mode).map {
                $0.replacingOccurrences(of: "/ (", with: " (").replacingOccurrences(of: "/ | ", with: " | ")
            }
            #expect(ours == theirs, "\(targets) \(mode)")
        }
    }

    @Test func newChildGoesAtTheSubtreesEnd() {
        func run(_ text: String, _ start: Int?, _ title: String) -> (String, Int, Int) {
            let r = DocumentSession.newChild(text, under: .some(start), title: title)
            return (r.edit.apply(to: text), r.start, r.level)
        }
        #expect(run("* A\nbody\n\n* B\n", 0, "New") == ("* A\nbody\n\n** New\n\n* B\n", 10, 2))
        #expect(run("* A\n** a1\n* B", 0, "New") == ("* A\n** a1\n\n** New\n* B", 11, 2))
        #expect(run("* A\nx", nil, "New") == ("* A\nx\n\n* New\n", 7, 1))
        #expect(run("* A\n\n\n", nil, "New") == ("* A\n\n* New\n\n\n", 5, 1))
    }

    @Test func splitsNewNodes() {
        let parent = RefileTarget(label: "a.org/Projects", path: "/a.org", start: 0, title: "Projects", level: 1, contentHash: "")
        #expect(RefileSettings.newNode("a.org/Projects/Garden", in: [parent])?.child == "Garden")
        #expect(RefileSettings.newNode("a.org/Projects//Garden", in: [parent])?.child == "Garden")
        #expect(RefileSettings.newNode("a.org/Other/Garden", in: [parent]) == nil)
        #expect(RefileSettings.newNode("Garden", in: [parent]) == nil)
    }
}
