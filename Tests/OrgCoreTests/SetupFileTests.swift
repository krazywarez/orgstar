import Foundation
import Testing
@testable import OrgCore

/// `#+SETUPFILE` keywords, nested setup files included, as Org reads them.
struct SetupFileTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let common = """
        #+TODO: NEXT WAIT | DONE CANCELLED
        #+PRIORITIES: A E C
        #+TAGS: work home
        #+FILETAGS: :shared:
        #+PROPERTY: owner alice
        #+PROPERTY: header-args :results silent
        #+TITLE: Setup Title
        #+OPTIONS: toc:nil num:nil
        #+MACRO: who Alice
        #+SETUPFILE: ../deep.org
        #+SETUPFILE: ../loop.org
        """ + "\n"
    static let deep = "#+TYP_TODO: BUG | FIXED\n#+SETUPFILE: setup/common.org\n"
    static let main = """
        #+SETUPFILE: setup/common.org

        * NEXT [#E] Task :local:
        {{{who}}}
        * BUG Other
        """ + "\n"

    @Test func collectsNestedKeywordLines() {
        let files = ["/w/setup/common.org": Self.common, "/w/deep.org": Self.deep]
        let lines = SetupFile.keywordLines(in: Self.main, directory: "/w") { files[$0] }
        #expect(lines.hasPrefix("#+TODO: NEXT WAIT | DONE CANCELLED\n"))
        #expect(lines.contains("#+TYP_TODO: BUG | FIXED\n#+TITLE") == false)
        #expect(lines.contains("#+TYP_TODO: BUG | FIXED\n"))
        #expect(lines.components(separatedBy: "#+TODO:").count == 2)
        #expect(SetupFile.keywordLines(in: "* x\n", directory: "/w") { files[$0] } == "")
        #expect(SetupFile.keywordLines(in: "#+SETUPFILE: https://example.com/a.org\n", directory: "/w") { _ in "#+TODO: X\n" } == "")
    }

    @Test(.enabled(if: oracle))
    func matchesOrg() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("setup"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.common.write(to: folder.appendingPathComponent("setup/common.org"), atomically: true, encoding: .utf8)
        try Self.deep.write(to: folder.appendingPathComponent("deep.org"), atomically: true, encoding: .utf8)
        let path = folder.appendingPathComponent("main.org").path
        try Self.main.write(toFile: path, atomically: true, encoding: .utf8)

        let emacs = try EmacsOracle.evaluate("", """
            (with-current-buffer (find-file-noselect \(lispString(path)))
              (require 'ox)
              (goto-char (point-min))
              (re-search-forward "^\\\\* NEXT")
              (let ((env (org-export-get-environment)))
                (list (mapconcat #'identity org-todo-keywords-1 " ")
                      (format "%c %c %c" org-priority-highest org-priority-lowest org-priority-default)
                      (mapconcat #'identity (org-get-tags) " ")
                      (or (cdr (assoc "owner" org-keyword-properties)) "")
                      (mapconcat #'identity (delq nil (mapcar (lambda (x) (and (stringp (car x)) (car x))) org-current-tag-alist)) " ")
                      (org-element-interpret-data (plist-get env :title))
                      (format "%s" (plist-get env :with-toc))
                      (progn (org-macro-initialize-templates) (or (cdr (assoc "who" org-macro-templates)) "")))))
            """)

        let settings = OrgSettings.default.resolvingSetupFiles(in: Self.main, path: path, read: OrgSettings.readFile)
        let tree = OrgParser.parse(Self.main, defaults: settings)
        let model = DocumentModel(tree: tree)
        let task = try #require(model.headings.firstIndex { $0.title.contains("Task") })
        let priorities = tree.settings.priorities
        let tagNames = (FastSelection.tagTable(settings.setupKeywords + Self.main) ?? []).compactMap { item -> String? in
            if case .option(_, let name) = item { name } else { nil }
        }
        let options = ExportOptions.parse(settings.setupKeywords + Self.main)
        let page = HTMLExport.page(Self.main, fallbackTitle: "main", settings: settings, path: path)
        let ours = [
            tree.settings.todoSequences.flatMap { ($0.active + $0.done).map(\.name) }.joined(separator: " "),
            "\(priorities.highest) \(priorities.lowest) \(priorities.default)",
            model.tags(of: task).map(\.value).joined(separator: " "),
            model.property("owner", of: nil)?.value ?? "",
            tagNames.joined(separator: " "),
            HTMLExport.metadata(Self.main, settings: settings).title ?? "",
            options.toc == nil ? "nil" : "\(options.toc!)",
            page.contains("Alice") ? "Alice" : "",
        ]
        #expect(ours == emacs)
        #expect(page.contains("<h1 class=\"title\">Setup Title</h1>") && !page.contains("id=\"table-of-contents\""))
    }
}
