import Foundation
import OrgCore
import Testing
@testable import OrgApp

struct EmacsImportTests {
    static let config = #"""
    (setq user-full-name "Someone")
    (setq doom-theme 'doom-homage-black)
    (setq doom-font (font-spec :family "JetBrains Mono" :size 14))
    (setq display-line-numbers-type t)
    (setq org-support-shift-select t)
    (setq org-directory "~/notes/")
    (setq org-roam-directory (file-name-concat org-directory "roam"))
    (after! org
      (setq org-hide-emphasis-markers t
            org-pretty-entities t
            org-agenda-files '("~/notes/" "~/work/plan.org")
            org-tags-column -80))
    (setq org-tags-column 4)
    (setq org-log-done 'note org-log-into-drawer t org-log-reschedule 'time)
    (setq org-agenda-prefix-format '((agenda . " %i %-12:c%?-12t% s%b") (todo . " %-8:c")))
    (setq fill-column (+ 70 2))
    (setq org-capture-templates
          '(("t" "Todo" entry (file+headline "~/notes/todo.org" "Inbox") "* TODO %?\n%a")
            ("j" "Journal" entry (file+olp+datetree "~/notes/journal.org") "* %?" :tree-type week :empty-lines 1 :time-prompt t)
            ("c" "Clocked" item (clock) "%?" :immediate-finish t)
            ("x" "Function" entry (function ignore) "* %?")
            ("w" "Work")
            ("wn" "Work note" plain (file "~/work/notes.org") "%?" :prepend t)))
    (map! :leader :desc "Report" "z t" #'tr/report
          :localleader "x" #'org-toggle-checkbox)
    (map! :n "g s" #'save-buffer)
    (global-set-key (kbd "C-c a") #'org-agenda)
    (with-eval-after-load 'org (define-key org-mode-map (kbd "C-c l") (lambda () (interactive))))
    """#

    static let doomOrg = #"""
    (defun +org-init-appearance-h ()
      (setq org-tags-column 0
            org-agenda-span 10
            org-agenda-start-day "-3d"
            org-clock-idle-time 15
            org-clock-history-length 10
            org-todo-keywords '((sequence "TODO(t)" "WAIT(w)" "|" "DONE(d)") (sequence "[ ](T)" "|" "[X](D)") (sequence "BUG" "|" "FIXED"))))
    (after! org (setq org-M-RET-may-split-line nil org-list-allow-alphabetical t))
    (map! :map org-mode-map "C-c q" #'org-set-tags-command)
    """#

    func scan() throws -> EmacsImport {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "(doom! :editor (evil +everywhere) :lang (org +pretty))".write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        try Self.config.write(to: folder.appendingPathComponent("config.el"), atomically: true, encoding: .utf8)
        let doom = folder.appendingPathComponent("doom-org.el")
        try Self.doomOrg.write(to: doom, atomically: true, encoding: .utf8)
        return EmacsImport.scan(EmacsImport.files(in: folder), doomDefaults: [doom])
    }

    func settings(_ result: EmacsImport) -> [String: TOML.Value] {
        var out: [String: TOML.Value] = [:]
        for item in result.items { if case .setting(let key, let value) = item.change { out[key] = value } }
        return out
    }

    @Test func readsSettingsWithDoomDefaultsUnderneath() throws {
        let result = try scan()
        #expect(result.isDoom)
        let s = settings(result)
        #expect(s["keymap"] == .string("doom"))
        #expect(s["display-line-numbers-type"] == .bool(true))
        #expect(s["org-hide-emphasis-markers"] == .bool(true))
        #expect(s["org-pretty-entities"] == .bool(true))
        #expect(s["org-log-done"] == .string("note"))
        #expect(s["org-log-reschedule"] == .string("time"))
        #expect(s["org-log-into-drawer"] == .string("LOGBOOK"))
        #expect(s["org-agenda-prefix-format.agenda"] == .string(" %i %-12:c%?-12t% s%b"))
        #expect(s["org-agenda-prefix-format.todo"] == .string(" %-8:c"))
        // after! org runs after the top-level setq.
        #expect(s["org-tags-column"] == .integer(-80))
        #expect(s["org-agenda-span"] == .integer(10))
        #expect(s["org-agenda-start-day"] == .string("-3d"))
        #expect(s["org-clock-idle-time"] == .integer(15))
        #expect(s["org-clock-history-length"] == .integer(10))
        #expect(s["org-M-RET-may-split-line"] == .bool(false))
        #expect(s["org-todo-keywords"] == .string("TODO(t) WAIT(w) | DONE(d)\nBUG | FIXED"))
        #expect(s["fill-column"] == nil)
        #expect(s["font"] == .string("JetBrains Mono") && s["font-size"] == .integer(14))
        let folders = result.items.compactMap { if case .folder(let f) = $0.change { f } else { nil } }
        #expect(folders == ["~/notes/", "~/work"])
        #expect(result.unreadable.map(\.name) == ["fill-column"])
        #expect(Set(result.unsupported.map(\.name)) == ["org-support-shift-select", "doom-theme", "org-roam-directory",
            "capture \"j\"", "capture \"x\"", "SPC z t → tr/report", "C-c l"])
        #expect(result.skipped == 1)
        #expect(result.doomDefaultsLeftOut == 1)
    }

    @Test func readsCaptureTemplatesAndBindings() throws {
        let result = try scan()
        let captures = result.items.compactMap { if case .capture(let key, let toml) = $0.change { (key, toml) } else { nil } }
        #expect(captures.map(\.0) == ["t", "j", "c", "wn"])
        #expect(captures[1].1 == "[[template]]\nkey = \"j\"\nname = \"Journal\"\ntype = \"entry\"\nfile = \"~/notes/journal.org\"\ndatetree = true\ntree-type = \"week\"\nempty-lines = 1\ntemplate = \"* %?\"\n")
        #expect(captures[2].1.contains("clock = true\n") && captures[2].1.contains("immediate-finish = true\n"))
        #expect(result.unsupported.contains { $0.name == "capture \"j\"" && $0.reason == ":time-prompt left out" })
        #expect(captures[0].1 == "[[template]]\nkey = \"t\"\nname = \"Todo\"\ntype = \"entry\"\nfile = \"~/notes/todo.org\"\nheadline = \"Inbox\"\ntemplate = \"* TODO %?\\n%a\"\n")
        #expect(captures[3].1.contains("prepend = true\n") && captures[3].1.contains("type = \"plain\""))

        let bindings = result.items.compactMap { if case .binding(let keys, let command, let mode) = $0.change { "\(keys) \(command) \(mode ?? "-")" } else { nil } }
        #expect(bindings == ["SPC m x org.checkbox.toggle normal", "g s app.save normal", "C-c a app.agenda normal"])
        #expect(result.unsupported.contains { $0.name == "SPC z t → tr/report" })
        #expect(result.unsupported.contains { $0.name == "C-c l" && $0.reason == "bound to code, not a command" })
    }

    @Test func readsCaptureTargetsFromVariablesAndForms() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"""
            (defvar my-inbox "~/old.org")
            (setq org-directory "~/org"
                  org-default-notes-file (expand-file-name "notes.org" org-directory)
                  my-inbox (concat org-directory "/inbox.org"))
            (setq org-capture-templates
                  `(("n" "Note" entry (file+headline org-default-notes-file "Notes") "* %?")
                    ("i" "Inbox" entry (file my-inbox) "* TODO %?")
                    ("w" "Work" entry (file ,(concat org-directory "/work.org")) "* %?")
                    ("j" "Journal" entry (file+olp+datetree (concat org-directory "/journal.org")) "* %?")))
            """#.write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        let result = EmacsImport.scan(EmacsImport.files(in: folder))
        let files = result.items.compactMap { item -> String? in
            guard case .capture(let key, let toml) = item.change else { return nil }
            return key + " " + (toml.firstMatch(of: /file = "([^"]*)"/).map { String($0.1) } ?? "-")
        }
        #expect(files == ["n ~/org/notes.org", "i ~/org/inbox.org", "w ~/org/work.org", "j ~/org/journal.org"])
    }

    /// The user's own Doom configuration, when there is one.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/doom/config.el")))
    func readsTheInstalledDoomConfig() {
        let result = EmacsImport.scan(EmacsImport.files(in: URL(fileURLWithPath: NSHomeDirectory() + "/.config/doom")))
        #expect(result.problems.isEmpty, "\(result.problems)")
        let s = settings(result)
        #expect(s["keymap"] == .string("doom"))
        #expect(s["org-agenda-start-day"] == .string("-3d"))
        #expect(s["org-tags-column"] == .integer(0))
        let report = result.items.map { "\($0.name) | \($0.summary) | \($0.source)" }
            + result.unsupported.map { "NO \($0.name): \($0.reason) | \($0.source)" }
            + result.unreadable.map { "?? \($0.name): \($0.reason) | \($0.source)" }
        print(report.joined(separator: "\n"))
    }

    @MainActor
    @Test func appliesToDefaultsAndFiles() async throws {
        let result = try scan()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[[template]]\nkey = \"t\"\nfile = \"x.org\"\ntemplate = \"* %?\"\n".write(to: folder.appendingPathComponent("capture.toml"), atomically: true, encoding: .utf8)
        let name = "orgstar-import-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let summary = await EmacsImport.apply(result.items, defaults: defaults, workspace: nil, directory: folder)
        #expect(defaults.string(forKey: "keymap") == "doom")
        #expect(defaults.integer(forKey: "tagsColumn") == -80)
        #expect(defaults.integer(forKey: "agendaStartOffset") == -3)
        #expect(defaults.string(forKey: "todoKeywords") == "TODO(t) WAIT(w) | DONE(d)\nBUG | FIXED")
        let capture = try String(contentsOf: folder.appendingPathComponent("capture.toml"), encoding: .utf8)
        #expect(capture.components(separatedBy: "[[template]]").count == 5)
        #expect(CaptureTemplates.load(userFile: folder.appendingPathComponent("capture.toml")).problems.isEmpty)
        let keymap = folder.appendingPathComponent("keymap.toml")
        #expect(KeymapLoader.load(.doom, userFile: keymap).problems.isEmpty)
        #expect(KeymapLoader.load(.doom, userFile: keymap).keymap.keyLabels(for: "app.agenda", modes: ["normal"]).contains("C-c a"))
        #expect(summary.hasPrefix("Imported 19 settings, 3 capture templates, 3 key bindings."), "\(summary)")
        #expect(defaults.string(forKey: "themeFont") == "JetBrains Mono")
        #expect(defaults.integer(forKey: "themeFontSize") == 14)

        // Importing again adds no bindings or templates.
        let before = try String(contentsOf: keymap, encoding: .utf8)
        let again = await EmacsImport.apply(result.items, defaults: defaults, workspace: nil, directory: folder)
        #expect(try String(contentsOf: keymap, encoding: .utf8) == before)
        #expect(!again.contains("key binding") && !again.contains("capture template"), "\(again)")
    }
}
