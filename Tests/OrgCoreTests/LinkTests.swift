import Foundation
import Testing
@testable import OrgCore

struct LinkTests {
    static let links = [
        "[[https://orgmode.org/manual][the manual]]", "[[file:notes.org::*Heading two]]", "[[./sub/a.org::#custom]]",
        "[[~/x.org::42]]", "[[/abs/path.txt]]", "[[file+sys:/a.pdf]]", "[[id:3F2A-77]]", "[[#my-id][custom]]", "[[(ref)]]",
        "[[Some heading]]", "[[*Starred title]]", "[[gh:krz/orgstar]]", "[[wiki:Org mode]]", "[[mailto:a@b.c]]",
        "[[doi:10.1000/182]]", "[[a \\[b\\] c]]", "[[file:a.org::target text]]", "[[shell:ls -l]]", "[[unknown:thing]]",
        "<https://example.com/a b>", "https://example.com/x?y=1", "file:plain.org::*H",
    ]

    static let header = "#+LINK: gh https://github.com/%s\n#+LINK: wiki https://en.wikipedia.org/wiki/\n"

    static func emacsParse() throws -> [String] {
        let text = header + links.map { "- " + $0 + "\n" }.joined()
        return try EmacsOracle.evaluate(text, """
            (let (out)
              (goto-char (point-min))
              (forward-line 2)
              (while (not (eobp))
                (forward-char 2)
                (let ((l (org-element-link-parser)))
                  (push (format "%s|%s|%s|%s" (org-element-property :type l) (org-element-property :path l)
                                (or (org-element-property :search-option l) "-") (org-element-property :raw-link l)) out))
                (forward-line 1))
              (nreverse out))
            """)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func parsesLikeOrgElement() throws {
        let emacs = try Self.emacsParse()
        let text = Self.header + Self.links.map { "- " + $0 + "\n" }.joined()
        let tree = OrgParser.parse(text)
        let ns = text as NSString
        var ours: [String] = []
        for link in Self.links {
            let offset = ns.range(of: "- " + link).location + 3
            guard let found = Links.link(at: offset, text: text, tree: tree) else { ours.append("none"); continue }
            let l = found.link
            ours.append("\(l.type)|\(l.path)|\(l.searchOption ?? "-")|\(l.raw)")
        }
        #expect(ours == emacs)
    }

    static let searchText = """
        #+TITLE: Search
        * First heading
        Body with <<a target>> and <<<radio>>>.
        * TODO [#A] Second [1/2] heading :tag:
        :PROPERTIES:
        :CUSTOM_ID: second
        :END:
        #+NAME: my table
        | a |
        * COMMENT Third
        ** Nested heading

        """

    static let searches = [
        "a target", "A   Target", "my table", "Second heading", "*Second heading", "#second", "#missing", "Third", "nested heading",
        "radio", "no such thing", "*a target", "(ref)", "/re/",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func searchesLikeOrgLinkSearch() throws {
        let quoted = Self.searches.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: " ")
        let emacs = try EmacsOracle.evaluate(Self.searchText, """
            (let ((org-link-search-must-match-exact-headline t) out)
              (dolist (s (list \(quoted)))
                (goto-char (point-min))
                (push (condition-case err (progn (org-link-search s) (format "at %d" (point)))
                        (error (error-message-string err)))
                      out))
              (nreverse out))
            """)
        let tree = OrgParser.parse(Self.searchText)
        for (s, expected) in zip(Self.searches, emacs) {
            let ours: String = switch Links.search(s, text: Self.searchText, tree: tree) {
            case .found(let offset): "at \(EmacsOracle.point(offset, in: Self.searchText))"
            case .failed(let message): message
            }
            // Org opens a sparse tree for regexps and finds coderefs only in blocks; Orgstar says so.
            if s == "(ref)" || s == "/re/" { continue }
            #expect(ours == expected, "\(s)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func followsRadioLinksLikeOrg() throws {
        let text = "* A\nSome <<<Radio  Target>>> here.\n* B\nThen radio\ntarget again, and RADIO TARGET.\n"
        let tree = OrgParser.parse(text)
        let ns = text as NSString
        let offsets = [ns.range(of: "radio\ntarget").location + 1, ns.range(of: "RADIO TARGET").location + 2]
        let emacs = try EmacsOracle.run(offsets.map { EmacsOracle.Case(text: text, point: EmacsOracle.point($0, in: text), form: "(org-open-at-point)") })
        for (offset, theirs) in zip(offsets, emacs) {
            let link = try #require(Links.link(at: offset, text: text, tree: tree)?.link)
            #expect(link.type == "radio")
            #expect(Links.searchRadio(link.path, tree: tree) == .found(EmacsOracle.offset(theirs.point, in: theirs.text)), "\(theirs)")
        }
        #expect(Links.searchRadio("elsewhere", tree: tree) == .failed("No match for radio target: elsewhere"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func findsAttachmentsLikeOrgAttach() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-attach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for dir in ["top", "files", "data/3f/2a77c0-1111", "data/202601/05T101010"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let text = """
            :PROPERTIES:
            :DIR: top
            :END:
            [[attachment:t.txt]]
            * Dir
            :PROPERTIES:
            :DIR: files
            :END:
            [[attachment:a.txt::3]]
            * By ID
            :PROPERTIES:
            :ID: 3f2a77c0-1111
            :END:
            [[attachment:b.txt]]
            ** Child without its own
            [[attachment:inherit.txt]]
            * Missing
            :PROPERTIES:
            :ID: zz99-none
            :END:
            [[attachment:c.txt]]
            * Timestamp ID
            :PROPERTIES:
            :ID: 20260105T101010
            :END:
            [[attachment:sub/d.txt]]

            """
        let file = folder.appendingPathComponent("notes.org").path
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        let ns = text as NSString
        let offsets = ["t.txt", "a.txt", "b.txt", "inherit.txt", "c.txt", "d.txt"].map { ns.range(of: $0).location }
        let points = offsets.map { String(EmacsOracle.point($0, in: text)) }.joined(separator: " ")
        let output = try EmacsOracle.run(["-Q", "--batch", "--eval", """
            (progn (require 'org) (require 'org-attach)
              (with-current-buffer (find-file-noselect "\(file)")
                (dolist (p '(\(points)))
                  (goto-char p)
                  (princ (format "%s\\n" (org-attach-expand (org-element-property :path (org-element-context))))))))
            """])
        let emacs = output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
        let tree = OrgParser.parse(text)
        let ours = offsets.map { offset -> String in
            guard let link = Links.link(at: offset, text: text, tree: tree)?.link,
                  let target = Links.attachmentFile(link, tree: tree, path: file, isDirectory: { path in
                      var directory: ObjCBool = false
                      return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
                  }) else { return "none" }
            return target.path + (target.searchOption.map { "::" + $0 } ?? "")
        }
        #expect(ours == emacs, "\(output)")
    }
}
