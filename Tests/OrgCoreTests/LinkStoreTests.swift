import Foundation
import Testing
@testable import OrgCore

struct LinkStoreTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        #+TITLE: Store
        intro (line) here
        * TODO [#A] First [1/2] heading :tag:
        body <<my target>> here
        text with [[https://x.org][a link]] in it
        * Second
        :PROPERTIES:
        :CUSTOM_ID: sec
        :END:
        #+NAME: tbl
        | a |

        #+name: code
        #+begin_src sh
        echo hi
        #+end_src
        * COMMENT Third [[https://y.org][linked]] title
        *\u{20}

        """

    /// Carets as text before them, and selections as `start…end` pairs of such text.
    static let cases: [(String, String?)] = [
        ("#+TITLE", nil), ("intro", nil), ("* TODO", nil), ("First", nil), ("<<my", nil), ("y target", nil), ("here\ntext", nil),
        ("body", nil), ("text with", nil), (":CUSTOM_ID", nil), ("#+NAME", nil), ("| a", nil), ("#+name", nil), ("echo", nil),
        ("#+end_src", nil), ("Third", nil), ("* \n", nil), ("intro", "First"), ("(line)", "here"),
    ]

    static func offset(_ s: String) -> Int { (text as NSString).range(of: s).location }

    @Test(.enabled(if: oracle))
    func storesLikeOrgStoreLink() throws {
        let points = Self.cases.map { c -> String in
            let start = EmacsOracle.point(Self.offset(c.0), in: Self.text)
            let end = c.1.map { EmacsOracle.point(Self.offset($0), in: Self.text) }
            return "(\(start) \(end.map(String.init) ?? "nil"))"
        }
        let emacs = try EmacsOracle.evaluate(Self.text, """
            (let ((dir (file-name-directory buffer-file-name)) out)
              (dolist (c '(\(points.joined(separator: " "))))
                (deactivate-mark)
                (goto-char (car c))
                (when (cadr c) (set-mark (car c)) (goto-char (cadr c)) (activate-mark))
                (setq org-stored-links nil)
                (call-interactively #'org-store-link)
                (push (format "%S" (mapcar (lambda (l) (list (replace-regexp-in-string (regexp-quote dir) "/d/" (car l) t t) (cadr l))) org-stored-links)) out))
              (nreverse out))
            """, prelude: "(transient-mark-mode 1)")
        var ours: [String] = []
        let tree = OrgParser.parse(Self.text)
        for c in Self.cases {
            let start = Self.offset(c.0)
            let selection = c.1.map { start..<Self.offset($0) } ?? start..<start
            let context = EditContext(revision: 0, text: Self.text, tree: tree, selection: [selection])
            let stored = Links.store(in: context, path: "/d/oracle.org")
            ours.append("((\(lisp(stored.link)) \(stored.description.map(lisp) ?? "nil")))")
        }
        #expect(ours == emacs)
    }

    func lisp(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    struct InsertCase {
        var text: String
        /// Where the caret goes: before this text, or with `|` marking it.
        var caret: Int
        var region: Range<Int>?
        var stored: [StoredLink]
        var link: String
        /// nil accepts the offered description.
        var description: String?
        var special: String? = nil
    }

    static func insertCase(_ marked: String, region: String? = nil, stored: [StoredLink] = [], link: String, description: String? = nil, special: String? = nil) -> InsertCase {
        let caret = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        let range = region.map { r -> Range<Int> in
            let start = (text as NSString).range(of: r).location
            return start..<(start + (r as NSString).length)
        }
        return InsertCase(text: text, caret: range?.upperBound ?? caret, region: range, stored: stored, link: link, description: description, special: special)
    }

    static let insertCases: [InsertCase] = [
        insertCase("* A\n|\n* Heading\n", stored: [StoredLink(link: "file:/d/oracle.org::*Heading", description: "Heading")], link: ""),
        insertCase("* A\n|\n", stored: [StoredLink(link: "file:/d/sub/b.org::*X", description: "X"), StoredLink(link: "file:/d/oracle.org::#c", description: "C")], link: "file:/d/sub/b.org::*X"),
        insertCase("* A\n|\n", stored: [StoredLink(link: "file:/elsewhere/c.org", description: nil)], link: "", description: "Elsewhere"),
        insertCase("* A\n|\n", stored: [StoredLink(link: "file:~/notes/x.org::42", description: nil)], link: ""),
        insertCase("Some |text\n", link: "https://orgmode.org", description: "Org"),
        insertCase("Some text here\n", region: "text", link: "https://orgmode.org"),
        insertCase("See [[https://a.org][the [a] site]] |\n", link: "https://b.org"),
        insertCase("See [[https://a.org][the site]]\n", region: nil, link: "https://b.org", description: "B"),
        insertCase("Visit https://a.org/x| now\n", link: "https://c.org"),
        insertCase("x |\n", link: "a [b] c\\", description: "ends]] with]"),
        insertCase("x |\n", link: "   "),
        insertCase("x |\n", stored: [StoredLink(link: "file:/d/oracle.org::*H", description: "Heading H")], link: "Heading H"),
        insertCase("x |\n", link: "https:", special: "https://typed.org"),
        insertCase("x |\n", link: "<https://angle.org>", description: ""),
        insertCase("x |\n", stored: [StoredLink(link: "file:/d/sub/b.org", description: "/d/sub/b.org")], link: ""),
    ]

    @Test(.enabled(if: oracle))
    func insertsLikeOrgInsertLink() throws {
        var cases = Self.insertCases
        // The edit-link case puts its caret inside the link.
        cases[7].caret = (cases[7].text as NSString).range(of: "the site").location
        var forms: [String] = []
        for c in cases {
            let stored = c.stored.map { "(list (funcall fix \(lisp($0.link))) \($0.description.map { "(funcall fix \(lisp($0)))" } ?? "nil"))" }.joined(separator: " ")
            let region = c.region.map { "(set-mark \(EmacsOracle.point($0.lowerBound, in: c.text))) (goto-char \(EmacsOracle.point($0.upperBound, in: c.text))) (activate-mark)" } ?? ""
            forms.append("""
                (progn (erase-buffer) (insert \(lisp(c.text))) (deactivate-mark) (goto-char \(EmacsOracle.point(c.caret, in: c.text))) \(region)
                  (setq org-stored-links (list \(stored)))
                  (let ((answers (list (cons "link" (funcall fix \(lisp(c.link)))) (cons "description" \(c.description.map(lisp) ?? "nil")) (cons "special" \(c.special.map(lisp) ?? "nil")))))
                    (let ((err (condition-case e
                                   (cl-letf (((symbol-function 'org-completing-read)
                                              (lambda (_prompt _coll &optional _p _r _i _h def &rest _)
                                                (let ((a (cdr (assoc "link" answers)))) (if (equal a "") (or def "") a))))
                                             ((symbol-function 'read-string)
                                              (lambda (prompt &optional initial &rest _)
                                                (cond ((string-prefix-p "Description" prompt) (or (cdr (assoc "description" answers)) initial ""))
                                                      ((string-prefix-p "Link (no" prompt) (cdr (assoc "special" answers)))
                                                      (t (cdr (assoc "link" answers)))))))
                                     (call-interactively #'org-insert-link) "")
                                 (error (error-message-string e)))))
                      (format "%s|%d|%d|%s" (replace-regexp-in-string (regexp-quote dir) "/d/" (buffer-string) t t) (1- (point)) (length org-stored-links) err))))
                """)
        }
        let emacs = try EmacsOracle.evaluate("", """
            (let* ((dir (file-name-directory buffer-file-name))
                   (fix (lambda (s) (replace-regexp-in-string "/d/" dir s t t))))
              (list \(forms.joined(separator: "\n"))))
            """, prelude: "(require 'cl-lib) (transient-mark-mode 1)")
        var ours: [String] = []
        for c in cases {
            let tree = OrgParser.parse(c.text)
            var answers: [String: String] = [:]
            let command = InsertLink(stored: c.stored, file: "/d/oracle.org", home: NSHomeDirectory())
            var line = ""
            loop: while true {
                let context = EditContext(revision: 0, text: c.text, tree: tree, selection: [c.region ?? c.caret..<c.caret], answers: answers)
                switch command.run(in: context) {
                case .prompt(let prompt):
                    switch prompt.key {
                    case "link": answers["link"] = c.link
                    case "special": answers["special"] = c.special ?? ""
                    default: answers["description"] = c.description ?? prompt.initial
                    }
                case .commit(let result):
                    var new = c.text
                    for edit in result.edits { new = edit.apply(to: new) }
                    let used = result.effects.contains { if case .storedLinkUsed = $0 { true } else { false } }
                    let point = EmacsOracle.point(result.selection!.first!.lowerBound, in: new) - 1
                    line = "\(new)|\(point)|\(c.stored.count - (used ? 1 : 0))|"
                    break loop
                case .failed(let message):
                    line = "\(c.text)|\(EmacsOracle.point(c.caret, in: c.text) - 1)|\(c.stored.count)|\(message)"
                    break loop
                case .external:
                    break loop
                }
            }
            ours.append(line)
        }
        for (o, e) in zip(ours, emacs) { #expect(o == e) }
        #expect(ours.count == emacs.count)
    }

    @Test(.enabled(if: oracle))
    func createsIDsLikeOrgIDGetCreate() throws {
        let cases = [
            ("* A\nbody\n", "body"), ("* A\nSCHEDULED: <2026-10-05 Mon>\n", "A"),
            ("* A\n:PROPERTIES:\n:ID:       old-id\n:END:\n", "A"), ("* A\n:PROPERTIES:\n:CUSTOM_ID: x\n:END:\n", "A"),
            ("#+TITLE: T\ntext\n* A\n", "text"), ("* A\n:PROPERTIES:\n:ID:\n:END:\n", "A"),
        ]
        let forms = cases.map { c in
            "(progn (erase-buffer) (insert \(lisp(c.0))) (goto-char \(EmacsOracle.point((c.0 as NSString).range(of: c.1).location, in: c.0))) (cl-letf (((symbol-function 'org-id-new) (lambda (&rest _) \"NEW-ID\")) ((symbol-function 'org-id-add-location) #'ignore)) (call-interactively #'org-id-get-create)) (format \"%s|%d\" (buffer-string) (1- (point))))"
        }
        let emacs = try EmacsOracle.evaluate("", "(list \(forms.joined(separator: " ")))", prelude: "(require 'org-id) (require 'cl-lib)")
        let ours = cases.map { c -> String in
            let result = runCommand(CreateID { "NEW-ID" }, c.0, caret: (c.0 as NSString).range(of: c.1).location)
            return "\(result.text)|\(EmacsOracle.point(result.caret, in: result.text) - 1)"
        }
        #expect(ours == emacs)
    }

    @Test(.enabled(if: oracle))
    func storesIDLinksLikeOrgIDStoreLink() throws {
        let cases = [("* TODO [#A] First [1/2] :tag:\nbody\n", "body"), ("#+TITLE: The Title\ntext\n* A\n", "text"), ("text\n* A\n", "text"), ("* A\n:PROPERTIES:\n:ID: kept\n:END:\n", "A")]
        let forms = cases.map { c in
            "(progn (erase-buffer) (insert \(lisp(c.0))) (goto-char \(EmacsOracle.point((c.0 as NSString).range(of: c.1).location, in: c.0))) (cl-letf (((symbol-function 'org-id-new) (lambda (&rest _) \"NEW-ID\")) ((symbol-function 'org-id-add-location) #'ignore)) (call-interactively #'org-id-store-link)) (format \"%s|%s\" (plist-get org-store-link-plist :link) (plist-get org-store-link-plist :description)))"
        }
        let emacs = try EmacsOracle.evaluate("", "(list \(forms.joined(separator: " ")))", prelude: "(require 'org-id) (require 'cl-lib)")
        let ours = cases.map { c -> String in
            let caret = (c.0 as NSString).range(of: c.1).location
            let created = runCommand(CreateID { "NEW-ID" }, c.0, caret: caret)
            let context = EditContext(revision: 0, text: created.text, tree: OrgParser.parse(created.text), selection: [created.caret..<created.caret])
            let stored = Links.storeID(in: context, fileName: "oracle.org")
            return "\(stored?.link ?? "nil")|\(stored?.description ?? "nil")"
        }
        #expect(ours == emacs)
    }

    @Test(.enabled(if: oracle))
    func createdIDsAreLowercaseUUIDsLikeOrgID() throws {
        let uuid = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        let emacs = try EmacsOracle.evaluate("* A\n", "(list (progn (require 'org-id) (org-id-uuid)))")
        #expect(emacs.first?.range(of: uuid, options: .regularExpression) != nil, "\(emacs)")
        let text = runCommand(CreateID(), "* A\n", caret: 0).text
        let id = try #require(text.firstMatch(of: /:ID: +(\S+)/)?.1)
        #expect(String(id).range(of: uuid, options: .regularExpression) != nil, "\(text)")
    }

    @Test func addingMovesALinkToTheFront() {
        let a = StoredLink(link: "file:a.org", description: "A")
        let b = StoredLink(link: "file:b.org", description: nil)
        var links: [StoredLink] = []
        #expect(StoredLink.add(a, to: &links) == "Stored: A")
        #expect(StoredLink.add(b, to: &links) == "Stored: file:b.org")
        #expect(StoredLink.add(b, to: &links) == "This link has already been stored")
        #expect(StoredLink.add(a, to: &links) == "Link moved to front: A")
        #expect(links == [a, b])
    }
}
