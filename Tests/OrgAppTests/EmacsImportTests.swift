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
    (setq org-agenda-sorting-strategy '((agenda time-up priority-down) (todo . (alpha-up))) org-agenda-sort-notime-is-late nil)
    (setq org-agenda-time-grid '((daily today) (800 1300) "......" "----") org-agenda-use-time-grid nil org-habit-show-habits-only-for-today nil)
    (setq org-stuck-projects '("+project/-DONE" ("NEXT" "TODO") ("errand") "\\<IGNORE\\>"))
    (setq org-agenda-custom-commands
          '(("d" "Daily" ((agenda "" ((org-agenda-span 'day) (org-agenda-overriding-header "Today")))
                          (todo "NEXT" ((org-agenda-skip-function '(org-agenda-skip-entry-if 'scheduled 'deadline))))
                          (tags-todo "+work" ((org-agenda-sorting-strategy '(priority-down alpha-up)))))
             ((org-agenda-prefix-format " %e ")))
            ("w" "Work" tags "+work-boss" ((org-agenda-skip-function '(org-agenda-skip-subtree-if 'regexp "IGNORE"))))
            ("x" "Prefix")
            ("f" "Function" my-agenda-function)))
    (add-to-list 'org-agenda-custom-commands '("s" "Stuck" stuck ""))
    (setq org-refile-targets '((nil :maxlevel . 2) (org-agenda-files :tag . "project"))
          org-refile-use-outline-path 'title
          org-refile-allow-creating-parent-nodes 'confirm)
    (setq fill-column (+ 70 2))
    (add-to-list 'org-structure-template-alist '("el" . "src emacs-lisp"))
    (with-eval-after-load 'org (add-to-list 'org-structure-template-alist '("q" . "QUOTE")))
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
            org-deadline-warning-days 7
            org-agenda-start-on-weekday 0
            org-track-ordered-property-with-tag t
            org-archive-location "archive/%s::"
            org-agenda-todo-ignore-scheduled 'future
            org-agenda-todo-ignore-deadlines 7
            org-agenda-log-mode-items '(closed clock state)
            org-clock-into-drawer "CLOCKS"
            org-clock-rounding-minutes 5
            org-clock-out-when-done '("DONE" "KILL")
            org-use-tag-inheritance "^@"
            org-tags-exclude-from-inheritance '("proj" "crypt")
            org-tag-alist '(("work" . ?w) ("home" . ?h) (:newline) (:startgroup) ("@office" . ?o) "@home" (:endgroup))
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
        #expect(s["org-agenda-sorting-strategy.agenda"] == .string("time-up priority-down"))
        #expect(s["org-agenda-sorting-strategy.todo"] == .string("alpha-up"))
        #expect(s["org-agenda-sort-notime-is-late"] == .bool(false))
        #expect(s["org-agenda-time-grid.when"] == .string("daily today"))
        #expect(s["org-agenda-time-grid.times"] == .string("800 1300"))
        #expect(s["org-agenda-use-time-grid"] == .bool(false))
        #expect(s["org-habit-show-habits-only-for-today"] == .bool(false))
        #expect(s["org-agenda-files"] == .string("~/notes/\n~/work/plan.org"))
        #expect(s["org-refile-targets"] == .string("((nil :maxlevel . 2) (org-agenda-files :tag . \"project\"))"))
        #expect(s["org-refile-use-outline-path"] == .string("title"))
        #expect(s["org-refile-allow-creating-parent-nodes"] == .string("confirm"))
        #expect(s["org-stuck-projects.match"] == .string("+project/-DONE"))
        #expect(s["org-stuck-projects.todo"] == .string("NEXT TODO"))
        #expect(s["org-stuck-projects.tags"] == .string("errand"))
        #expect(s["org-stuck-projects.regexp"] == .string("\\<IGNORE\\>"))
        // after! org runs after the top-level setq.
        #expect(s["org-tags-column"] == .integer(-80))
        #expect(s["org-agenda-span"] == .integer(10))
        #expect(s["org-deadline-warning-days"] == .integer(7))
        #expect(s["org-agenda-start-on-weekday"] == .string("0"))
        #expect(s["org-track-ordered-property-with-tag"] == .string("t"))
        #expect(s["org-archive-location"] == .string("archive/%s::"))
        #expect(s["org-agenda-log-mode-items"] == .string("closed clock state") && s["org-clock-into-drawer"] == .string("CLOCKS"))
        #expect(s["org-use-tag-inheritance"] == .string("{^@}") && s["org-tags-exclude-from-inheritance"] == .string("proj crypt"))
        #expect(s["org-tag-alist"] == .string("work(w) home(h)\n{ @office(o) @home }"))
        #expect(s["org-clock-rounding-minutes"] == .integer(5) && s["org-clock-out-when-done"] == .string("DONE KILL"))
        #expect(s["org-agenda-todo-ignore-scheduled"] == .string("future") && s["org-agenda-todo-ignore-deadlines"] == .string("7"))
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
        #expect(s["org-roam-directory"] == .string("~/notes/roam"))
        #expect(Set(result.unsupported.map(\.name)) == ["org-support-shift-select", "doom-theme",
            "capture \"x\"", "SPC z t → tr/report", "C-c l", "agenda command \"f\""])
        #expect(result.skipped == 1)
        #expect(result.doomDefaultsLeftOut == 1)
    }

    @Test func readsCaptureTemplatesAndBindings() throws {
        let result = try scan()
        let captures = result.items.compactMap { if case .capture(let key, let toml) = $0.change { (key, toml) } else { nil } }
        #expect(captures.map(\.0) == ["t", "j", "c", "w", "wn"])
        #expect(captures[1].1 == "[[template]]\nkey = \"j\"\nname = \"Journal\"\ntype = \"entry\"\nfile = \"~/notes/journal.org\"\ndatetree = true\ntree-type = \"week\"\ntime-prompt = true\nempty-lines = 1\ntemplate = \"* %?\"\n")
        #expect(captures[2].1.contains("clock = true\n") && captures[2].1.contains("immediate-finish = true\n"))
        #expect(captures[3].1 == "[[template]]\nkey = \"w\"\nname = \"Work\"\n")
        #expect(captures[0].1 == "[[template]]\nkey = \"t\"\nname = \"Todo\"\ntype = \"entry\"\nfile = \"~/notes/todo.org\"\nheadline = \"Inbox\"\ntemplate = \"* TODO %?\\n%a\"\n")
        #expect(captures[4].1.contains("prepend = true\n") && captures[4].1.contains("type = \"plain\""))

        let bindings = result.items.compactMap { if case .binding(let keys, let command, let mode) = $0.change { "\(keys) \(command) \(mode ?? "-")" } else { nil } }
        #expect(bindings == ["SPC m x org.checkbox.toggle normal", "g s app.save normal", "C-c a app.agenda normal"])
        #expect(result.unsupported.contains { $0.name == "SPC z t → tr/report" })
        #expect(result.unsupported.contains { $0.name == "C-c l" && $0.reason == "bound to code, not a command" })
    }

    @Test func readsICalendarSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"""
            (setq org-icalendar-use-deadline '(event-if-todo todo-due)
                  org-icalendar-use-scheduled '(event-if-not-todo)
                  org-icalendar-include-todo '("NEXT" "WAIT")
                  org-icalendar-combined-agenda-file (concat "~/cal" "/org.ics"))
            """#.write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        let s = settings(EmacsImport.scan(EmacsImport.files(in: folder)))
        #expect(s["org-icalendar-use-deadline"] == .string("event-if-todo todo-due"))
        #expect(s["org-icalendar-use-scheduled"] == .string("event-if-not-todo"))
        #expect(s["org-icalendar-include-todo"] == .string("NEXT WAIT"))
        #expect(s["org-icalendar-combined-agenda-file"] == .string("~/cal/org.ics"))
    }

    @Test func readsYankSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"""
            (setq org-yank-image-save-method "images/"
                  org-yank-dnd-method 'attach)
            """#.write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        let s = settings(EmacsImport.scan(EmacsImport.files(in: folder)))
        #expect(s["org-yank-image-save-method"] == .string("images/"))
        #expect(s["org-yank-dnd-method"] == .string("attach"))
    }

    @Test func readsLiterateConfig() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "(doom! :lang org)".write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        try #"""
            #+title: Config
            * Org
            #+begin_src emacs-lisp
            (setq org-tags-column 0)
            #+end_src
            #+begin_src emacs-lisp :tangle no
            (setq org-log-done 'note)
            #+end_src
            * COMMENT Old
            #+begin_src emacs-lisp
            (setq org-startup-folded t)
            #+end_src
            """#.write(to: folder.appendingPathComponent("config.org"), atomically: true, encoding: .utf8)
        #expect(EmacsImport.files(in: folder).map(\.lastPathComponent) == ["init.el", "config.org"])
        let result = EmacsImport.scan(EmacsImport.files(in: folder), doomDefaults: [])
        #expect(result.problems.isEmpty, "\(result.problems)")
        #expect(result.isDoom)
        let s = settings(result)
        #expect(s["org-tags-column"] == .integer(0))
        #expect(s["org-log-done"] == nil && s["org-startup-folded"] == nil)
        #expect(result.items.first { $0.name == "org-tags-column" }?.source == "config.org:4")
        // A config.el tangled from it is read instead.
        try "(setq org-tags-column 4)".write(to: folder.appendingPathComponent("config.el"), atomically: true, encoding: .utf8)
        #expect(EmacsImport.files(in: folder).map(\.lastPathComponent) == ["init.el", "config.el"])
    }

    @MainActor
    @Test func writesSettingsIntoConfigFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "(setq org-tags-column 0 org-log-done 'time)\n(add-to-list 'org-structure-template-alist '(\"el\" . \"src emacs-lisp\"))"
            .write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        let result = EmacsImport.scan(EmacsImport.files(in: folder))
        let name = "orgstar-import-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        _ = await EmacsImport.apply(result.items, defaults: defaults, workspace: nil, directory: folder, writeConfig: true)
        let config = try String(contentsOf: folder.appendingPathComponent("config.toml"), encoding: .utf8)
        let values = UserConfig.values(in: config)
        #expect(values["org-tags-column"] == .integer(0), "\(config)")
        #expect(values["org-log-done"] == .string("time"), "\(config)")
        #expect(values["org-structure-template-alist.el"] == .string("src emacs-lisp"), "\(config)")
    }

    @Test func readsDailies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"""
            (setq org-roam-dailies-directory "journal/")
            (setq org-roam-dailies-capture-templates
                  '(("d" "default" entry "* %<%H:%M> %?" :target (file+head "%<%Y-%m-%d>.org" "#+title: %<%A %d %B>\n"))))
            """#.write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        let s = settings(EmacsImport.scan(EmacsImport.files(in: folder)))
        #expect(s["org-roam-dailies-directory"] == .string("journal/"))
        #expect(s["org-roam-dailies-file"] == .string("%<%Y-%m-%d>.org"))
        #expect(s["org-roam-dailies-head"] == .string("#+title: %<%A %d %B>\n"))
        #expect(s["org-roam-dailies-entry"] == .string("* %<%H:%M> %?"))
    }

    @Test func readsPublishingProjects() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"""
            (setq org-publish-project-alist
                  `(("notes" :base-directory "~/notes" :base-extension "org" :publishing-directory ,(concat "~/public" "_html")
                     :recursive t :publishing-function org-html-publish-to-html :auto-sitemap t :sitemap-style list
                     :include ("extra.org") :html-head "<link>")
                    ("static" :base-directory "~/notes" :base-extension "css\\|png" :publishing-directory "~/public_html"
                     :publishing-function (org-publish-attachment))
                    ("pdf" :base-directory "~/notes" :publishing-directory "~/pdf" :publishing-function org-latex-publish-to-pdf)
                    ("site" :components ("notes" "static"))))
            """#.write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        let result = EmacsImport.scan(EmacsImport.files(in: folder))
        let projects = result.items.compactMap { if case .publish(let name, let toml) = $0.change { (name, toml) } else { nil } }
        #expect(projects.map(\.0) == ["notes", "static", "site"])
        #expect(projects[0].1 == "[[publish]]\nname = \"notes\"\nbase-directory = \"~/notes\"\nbase-extension = \"org\"\npublishing-directory = \"~/public_html\"\nrecursive = true\npublishing-function = \"org-html-publish-to-html\"\nauto-sitemap = true\nsitemap-style = \"list\"\ninclude = \"extra.org\"\n")
        #expect(projects[1].1.contains("base-extension = \"css\\\\|png\"\n") && projects[1].1.contains("publishing-function = \"org-publish-attachment\"\n"))
        #expect(projects[2].1 == "[[publish]]\nname = \"site\"\ncomponents = \"notes static\"\n")
        #expect(result.unsupported.contains { $0.name == "publishing project \"pdf\"" })
        #expect(result.unsupported.contains { $0.name == "publishing project \"notes\"" && $0.reason == ":html-head left out" })

        let config = folder.appendingPathComponent("conf")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "fill-column = 72\n".write(to: config.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let summary = await EmacsImport.apply(result.items.filter { if case .publish = $0.change { true } else { false } },
                                              defaults: UserDefaults(suiteName: "orgstar-import-\(UUID().uuidString)")!, workspace: nil, directory: config)
        #expect(summary == "Imported 3 publishing projects.")
        let written = try String(contentsOf: config.appendingPathComponent("config.toml"), encoding: .utf8)
        let loaded = await Publish.projects(fromConfig: written, root: nil)
        #expect(loaded.problems.isEmpty && loaded.projects.map(\.name) == ["notes", "static", "site"])
        #expect(UserConfig.setting(written, section: "", key: "fill-column", to: .integer(80)).hasPrefix("fill-column = 80\n"))
        #expect(!UserConfig.setting(written, section: "theme", key: "font", to: .string("X")).contains("[[publish]]\nname = \"site\"\ncomponents = \"notes static\"\nfont"))
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
                    ("j" "Journal" entry (file+olp+datetree (concat org-directory "/journal.org")) "* %?")
                    ("q" "Quarter" entry (file+olp+datetree "~/q.org") "* %?" :tree-type (year quarter))
                    ("r" "Reading" plain (file+regexp "~/r.org" "^\\* Reading") "%?")))
            """#.write(to: folder.appendingPathComponent("init.el"), atomically: true, encoding: .utf8)
        let result = EmacsImport.scan(EmacsImport.files(in: folder))
        let files = result.items.compactMap { item -> String? in
            guard case .capture(let key, let toml) = item.change else { return nil }
            return key + " " + (toml.firstMatch(of: /file = "([^"]*)"/).map { String($0.1) } ?? "-")
        }
        #expect(files == ["n ~/org/notes.org", "i ~/org/inbox.org", "w ~/org/work.org", "j ~/org/journal.org", "q ~/q.org", "r ~/r.org"])
        let tomls = result.items.compactMap { if case .capture(_, let toml) = $0.change { toml } else { nil } }
        #expect(tomls[4].contains("tree-type = \"year quarter\"\n"))
        #expect(tomls[5].contains("regexp = \"^\\\\* Reading\"\n"))
        #expect(!result.unsupported.contains { $0.name.hasPrefix("capture") }, "\(result.unsupported)")
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
        #expect(capture.components(separatedBy: "[[template]]").count == 6)
        #expect(CaptureTemplates.load(userFile: folder.appendingPathComponent("capture.toml")).problems.isEmpty)
        let keymap = folder.appendingPathComponent("keymap.toml")
        #expect(KeymapLoader.load(.doom, userFile: keymap).problems.isEmpty)
        #expect(KeymapLoader.load(.doom, userFile: keymap).keymap.keyLabels(for: "app.agenda", modes: ["normal"]).contains("C-c a"))
        #expect(summary.hasPrefix("Imported 48 settings, 3 capture templates, 3 key bindings, 2 structure templates, 3 agenda views."), "\(summary)")
        let views = AgendaViewLoader.load(userFile: folder.appendingPathComponent("views.toml"))
        #expect(views.problems.isEmpty, "\(views.problems)")
        #expect(views.views.dropFirst(3).map(\.name) == ["Daily", "Work", "Stuck"])
        if case .blocks(let blocks) = views.views[3].mode {
            #expect(blocks.map(\.mode) == [.agenda(span: 1, startOffset: nil), .todo(keywords: "NEXT"), .match("+work", todoOnly: true)])
            #expect(blocks[0].settings.header == "Today" && blocks.allSatisfy { $0.settings.prefixFormat == " %e " })
            #expect(blocks[1].settings.skip == AgendaSkip(subtree: false, conditions: [.scheduled, .deadline]))
            #expect(blocks[2].settings.sortingStrategy == ["priority-down", "alpha-up"])
        } else {
            Issue.record("Daily isn't a block view")
        }
        #expect(views.views[4].mode == .match("+work-boss", todoOnly: false))
        #expect(views.views[4].settings.skip == AgendaSkip(subtree: true, conditions: [.regexp("IGNORE")]))
        #expect(views.views[5].mode == .stuck(nil))
        #expect(UserConfig.structureTemplates(defaults) == [.init(key: "el", type: "src emacs-lisp"), .init(key: "q", type: "QUOTE")])
        #expect(OrgPreferences.options(defaults).structureTemplates?.first { $0.key == "q" }?.type == "QUOTE")
        #expect(defaults.string(forKey: "themeFont") == "JetBrains Mono")
        #expect(defaults.integer(forKey: "themeFontSize") == 14)

        // Importing again adds no bindings or templates.
        let before = try String(contentsOf: keymap, encoding: .utf8)
        let again = await EmacsImport.apply(result.items, defaults: defaults, workspace: nil, directory: folder)
        #expect(try String(contentsOf: keymap, encoding: .utf8) == before)
        #expect(!again.contains("key binding") && !again.contains("capture template") && !again.contains("agenda view"), "\(again)")
    }
}
