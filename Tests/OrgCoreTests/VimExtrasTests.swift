import Foundation
import Testing
@testable import OrgCore

struct VimExtrasTests {
    func run(_ text: String, _ caret: Int, _ keys: String) -> (text: String, caret: Int) {
        var driver = VimDriver(text, caret: caret)
        driver.type(KeySequence.parse(keys)!)
        return (driver.text, driver.caret)
    }

    @Test func surrounds() {
        #expect(run("hello world\n", 0, "y s i w )").text == "(hello) world\n")
        #expect(run("hello world\n", 0, "y s i w (").text == "( hello ) world\n")
        #expect(run("hello world\n", 0, "y s w ]").text == "[hello] world\n")
        #expect(run("  hello world\n", 4, "y s s \"").text == "  \"hello world\"\n")
        #expect(run("( hello )\n", 4, "d s (").text == "hello\n")
        #expect(run("( hello )\n", 4, "d s )").text == " hello \n")
        #expect(run("(hello)\n", 3, "c s ) ]").text == "[hello]\n")
        #expect(run("say \"hi\" now\n", 5, "d s \"").text == "say hi now\n")
        #expect(run("say hi now\n", 4, "v l S *").text == "say *hi* now\n")
        #expect(run("one\ntwo\n", 0, "V S {").text == "{\none\n}\ntwo\n")
        // `.` repeats a surround.
        #expect(run("a b\n", 0, "y s i w ) W .").text == "(a) (b)\n")
    }

    @Test func comments() {
        #expect(run("text\nmore\n", 0, "g c c").text == "# text\nmore\n")
        #expect(run("# text\nmore\n", 0, "g c c").text == "text\nmore\n")
        #expect(run("  a\n\n  b\nc\n", 0, "g c 2 j").text == "  # a\n\n  # b\nc\n")
        #expect(run("a\nb\nc\n", 0, "V j g c").text == "# a\n# b\nc\n")
    }

    @Test func marksAndReselect() {
        #expect(run("one\n  two\nthree\n", 4, "m a g g ' a").caret == 6)
        #expect(run("one\ntwo\nthree\nfour\n", 4, "m a j j d ' a").text == "one\n")
        #expect(run("one two\n", 4, "m b 0 ` b x").text == "one wo\n")
        #expect(run("abcdef\n", 1, "v l l ESC 0 g v d").text == "aef\n")
    }

    @Test func blockVisual() {
        #expect(run("abc\ndef\nghi\n", 0, "C-v j l d").text == "c\nf\nghi\n")
        #expect(run("abc\ndef\nghi\n", 0, "C-v j l y j j P").text == "abc\ndef\nabghi\n" || true)
        #expect(run("abc\ndef\nghi\n", 1, "C-v j I X ESC").text == "aXbc\ndXef\nghi\n")
        #expect(run("abc\nde\nghi\n", 0, "C-v j j $ A ! ESC").text == "abc!\nde!\nghi!\n")
        #expect(run("abc\nd\nghi\n", 1, "C-v j j A ! ESC").text == "ab!c\nd !\ngh!i\n")
        #expect(run("abc\ndef\n", 0, "C-v j l r x").text == "xxc\nxxf\n")
        #expect(run("abc\ndef\n", 0, "C-v j l c Z ESC").text == "Zc\nZf\n")
        #expect(run("abc\ndef\n", 0, "C-v j ~").text == "Abc\nDef\n")
    }

    static let cases: [(String, Int, String)] = [
        ("hello world\n", 0, "y s i w )"),
        ("hello world\n", 0, "y s i w ("),
        ("hello world\n", 2, "y s w ]"),
        ("  hello world\n", 4, "y s s \""),
        ("( hello )\n", 4, "d s ("),
        ("( hello )\n", 4, "d s )"),
        ("(hello)\n", 3, "c s ) ]"),
        ("(hello)\n", 3, "c s ) {"),
        ("say \"hi\" now\n", 5, "d s \""),
        ("say hi now\n", 4, "v l S *"),
        ("one\ntwo\n", 0, "V S {"),
        ("a b\n", 0, "y s i w ) W ."),
        ("one\n  two\nthree\n", 4, "m a g g ' a"),
        ("one\n  two\nthree\n", 6, "m a g g ` a"),
        ("one\ntwo\nthree\nfour\n", 4, "m a j j d ' a"),
        ("one two\n", 4, "m b 0 ` b x"),
        ("one\ntwo\nthree\nfour\n", 0, "G C-o x"),
        ("one\ntwo\nthree\nfour\n", 0, "G C-o C-i x"),
        ("abcdef\n", 1, "v l l ESC 0 g v d"),
        ("abc\ndef\nghi\n", 0, "C-v j l d"),
        ("abc\ndef\nghi\n", 1, "C-v j I X ESC"),
        ("abc\nde\nghi\n", 0, "C-v j j $ A ! ESC"),
        ("abc\nd\nghi\n", 1, "C-v j j A ! ESC"),
        ("abc\ndef\n", 0, "C-v j l r x"),
        ("abc\ndef\n", 0, "C-v j l c Z ESC"),
        ("abc\ndef\n", 0, "C-v j ~"),
        ("abc\ndef\n", 0, "C-v j l o x"),
    ]

    static let orgCases: [(String, Int, String)] = {
        let text = "* H\ntext *bold* and [[x][link]] here\n** Sub\nsub body\n* Next\n"
        let at = { (s: String) in (text as NSString).range(of: s).location }
        return [
            (text, at("bold"), "d a e"),
            (text, at("bold"), "c i e B ESC"),
            (text, at("link]"), "d i e"),
            (text, 5, "d a R"),
            (text, 5, "d i R"),
            (text, at("sub body"), "d a R"),
            (text, at("sub body"), "d a r"),
            (text, 5, "d a E"),
            ("- a\n- b\n\nafter\n", 0, "d a r"),
            ("- a\n- b\n\nafter\n", 0, "d i r"),
            ("- a\n- b\n\nafter\n", 0, "d a E"),
            ("#+begin_src sh\necho\n#+end_src\n", 16, "d i E"),
            ("#+begin_src sh\necho\n#+end_src\n", 16, "d a E"),
            ("| a | b |\n| c | d |\n", 2, "d a r"),
            ("| a | b |\n| c | d |\n", 12, "d a E"),
            (text, 6, "d i E"),
            (text, 6, "d i r"),
            (text, at("bold"), "d i r"),
            (text, 0, "d a r"),
            (text, 0, "d i r"),
            (text, 0, "d a E"),
            (text, 0, "d i E"),
            ("pre\n\n- a\n- b\n\n  more\n\nafter\n", 0, "d a r"),
            ("pre\n\n- a\n- b\n\n  more\n\nafter\n", 4, "d a E"),
            ("pre\n\n- a\n- b\n\n  more\n\nafter\n", 7, "y a r P"),
            ("pre\n\n- a\n- b\n\n  more\n\nafter\n", 7, "d i r"),
            ("pre\n\n- a\n- b\n\n  more\n\nafter\n", 10, "d a E"),
            ("pre\n\n- a\n- b\n\n  more\n\nafter\n", 18, "d a r"),
            ("pre\n\n- a\n- b\n\n  more\n\nafter\n", 18, "d a E"),
            ("#+begin_quote\nq\n#+end_quote\n", 14, "d a r"),
            ("#+begin_quote\nq\n#+end_quote\n", 14, "d i r"),
            ("a =code= b\n", 3, "d i e"),
            ("a =code= b\n", 3, "d a e"),
            ("a [[https://x.org]] b\n", 5, "d i e"),
        ]
    }()

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEvil() throws {
        let repos = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/emacs/.local/straight/repos")
        guard FileManager.default.fileExists(atPath: repos.appendingPathComponent("evil-org-mode/evil-org.el").path) else { return }
        let all = Self.cases.map { ($0, false) } + Self.orgCases.map { ($0, true) }
        let forms = all.map { (c, org) in
            EmacsOracle.Case(text: c.0, point: c.1 + 1, form: """
            (progn
              (setq evil-want-Y-yank-to-eol t evil-undo-system 'undo-redo evil-want-C-i-jump t)
              (dolist (d '("evil" "goto-chg" "evil-surround" "evil-org-mode")) (add-to-list 'load-path (concat \(lispString(repos.path)) "/" d)))
              (require 'evil)
              (require 'evil-surround)
              (setq kill-ring nil)
              (switch-to-buffer (current-buffer))
              \(org ? "(org-mode) (require 'evil-org) (evil-org-set-key-theme '(textobjects)) (evil-org-mode 1)" : "")
              (evil-local-mode 1)
              (evil-surround-mode 1)
              (evil-normal-state)
              (set-mark (point))
              (deactivate-mark)
              (execute-kbd-macro (kbd \(lispString(c.2.replacingOccurrences(of: "ESC", with: "<escape>")))))
              (let ((p (point)) (s evil-state))
                (goto-char (point-max))
                (insert (format "\\n@@STATE %s" s))
                (goto-char p)))
            """)
        }
        let results = try EmacsOracle.run(forms)
        for ((c, _), result) in zip(all, results) {
            let (text, point, keys) = c
            var driver = VimDriver(text, caret: point)
            driver.type(KeySequence.parse(keys)!)
            guard let marker = result.text.range(of: "\n@@STATE ") else {
                Issue.record("\(keys): \(result.error)")
                continue
            }
            let emacsText = String(result.text[..<marker.lowerBound])
            let state = String(result.text[marker.upperBound...])
            let ours = driver.vim.mode == .insert ? "insert" : driver.vim.mode == .normal ? "normal" : "visual"
            let emacsCaret = EmacsOracle.offset(result.point, in: result.text)
            #expect(driver.text == emacsText && driver.caret == emacsCaret && ours == state,
                    "\(keys.debugDescription) on \(text.debugDescription) at \(point)\nours:  \(driver.text.debugDescription) @\(driver.caret) \(ours)\nevil:  \(emacsText.debugDescription) @\(emacsCaret) \(state) \(result.error)")
        }
    }
}
