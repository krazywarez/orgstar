import Foundation
import Testing
@testable import OrgCore

/// Plays keys through `Vim` the way the editor does: printable keys in insert state type,
/// actions apply to the text.
struct VimDriver {
    var vim = Vim()
    var text: String
    var caret: Int
    var clipboard: String?
    var commands: [String] = []
    var halfPage = 15
    var visible: Range<Int>?
    var org = false

    init(_ text: String, caret: Int) {
        self.text = text
        self.caret = caret
    }

    mutating func type(_ keys: [KeyChord]) {
        for key in keys {
            if vim.mode == .insert, vim.passesThrough(key) {
                if key == KeyChord("DEL") {
                    if caret > 0 {
                        let ns = text as NSString
                        text = ns.replacingCharacters(in: NSRange(location: caret - 1, length: 1), with: "")
                        caret -= 1
                        vim.deletedBackward()
                    }
                } else {
                    let s = key.key == "SPC" ? " " : key.key == "RET" ? "\n" : key.key == "TAB" ? "\t" : key.key
                    guard key.modifiers.isEmpty, s.count == 1 else { continue }
                    let ns = text as NSString
                    text = ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: s)
                    caret += s.utf16.count
                    vim.inserted(s)
                }
                continue
            }
            let actions = vim.feed(key, Vim.Context(text: text, caret: caret, clipboard: clipboard, halfPage: halfPage, visible: visible, org: org))
            for action in actions {
                switch action {
                case .edit(let edits, let to):
                    for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { text = edit.apply(to: text) }
                    caret = to
                case .move(let to): caret = to
                case .setClipboard(let s): clipboard = s
                case .command(let id): commands.append(id)
                case .fill(let range, let keep):
                    let result = runCommand(FillRegion(range: range, keep: keep), text, caret: caret)
                    text = result.text
                    caret = result.caret
                default: break
                }
            }
        }
    }
}

struct VimTests {
    static func keys(_ s: String) -> [KeyChord] { KeySequence.parse(s)! }

    static let cases: [(String, Int, String)] = [
        ("hello world foo\nsecond line here\n", 0, "d w"),
        ("hello world foo\nsecond line here\n", 0, "j c i w X ESC"),
        ("hello world foo\nsecond line here\n", 6, "d i w"),
        ("hello world foo\nsecond line here\n", 6, "d a w"),
        ("hello world foo\nsecond line here\n", 0, "2 d w"),
        ("hello world foo\nsecond line here\n", 0, "d 2 w"),
        ("hello world foo\nsecond line here\n", 12, "d w"),
        ("hello world foo\nsecond line here\n", 4, "x"),
        ("hello world foo\nsecond line here\n", 4, "3 x"),
        ("hello world foo\nsecond line here\n", 4, "X"),
        ("hello world foo\nsecond line here\n", 4, "D"),
        ("hello world foo\nsecond line here\n", 4, "C n e w ESC"),
        ("hello world foo\nsecond line here\n", 4, "d d"),
        ("one\ntwo\nthree\nfour\n", 4, "2 d d"),
        ("one\ntwo\nthree\nfour\n", 14, "d d"),
        ("one\ntwo\nthree\nfour", 14, "d d"),
        ("one\ntwo\nthree\n", 0, "y y p"),
        ("one\ntwo\nthree\n", 0, "y y P"),
        ("one\ntwo\nthree\n", 4, "y w $ p"),
        ("one\ntwo\nthree\n", 0, "d d p"),
        ("one two three\n", 0, "d w w P"),
        ("one two three\n", 4, "Y $ p"),
        ("one\ntwo\nthree\n", 0, "J"),
        ("one\n  two\nthree\n", 0, "3 J"),
        ("one two\n", 0, "r X"),
        ("one two\n", 0, "~ ~"),
        ("Hello World\n", 0, "g U i w"),
        ("Hello World\n", 0, "g u u"),
        ("one two\n", 0, "o n e w ESC"),
        ("one two\n", 4, "O n e w ESC"),
        ("  one two\n", 6, "I x ESC"),
        ("one two\n", 2, "A ! ESC"),
        ("one two\n", 2, "a X ESC"),
        ("one two three four\n", 0, "d w ."),
        ("one two three four\n", 0, "c w X ESC w ."),
        ("one\ntwo\nthree\nfour\n", 0, "d d j ."),
        ("a(b, c) d\n", 3, "d i ("),
        ("a(b, c) d\n", 3, "d a ("),
        ("say \"hi there\" now\n", 7, "c i \" X ESC"),
        ("say \"hi there\" now\n", 7, "d a \""),
        ("x = [1, 2, 3]\n", 6, "d i ["),
        ("f {\n  body\n}\n", 6, "d i {"),
        ("one two three\n", 0, "v e d"),
        ("one two three\n", 4, "v i w y $ p"),
        ("one\ntwo\nthree\n", 4, "V d"),
        ("one\ntwo\nthree\n", 0, "V j d"),
        ("one\ntwo\nthree\n", 0, "V j y G p"),
        ("one two three\n", 0, "f t x"),
        ("one two three\n", 0, "t t x"),
        ("one two three\n", 12, "F o x"),
        ("one two three\n", 0, "f e ; x"),
        ("one two three\n", 0, "d f t"),
        ("one two three\n", 0, "d t t"),
        ("one two three\n", 0, "$ x"),
        ("one two three\n", 8, "0 x"),
        ("   one two\n", 8, "^ x"),
        ("one\ntwo\nthree\n", 0, "G x"),
        ("one\ntwo\nthree\n", 10, "g g x"),
        ("one\ntwo\nthree\n", 0, "2 G x"),
        ("one two three\n", 0, "e x"),
        ("one two three\n", 0, "w w b x"),
        ("one.two three\n", 0, "w x"),
        ("one.two three\n", 0, "W x"),
        ("one.two three\n", 12, "B x"),
        ("one two three\n", 0, "d e"),
        ("one two three\n", 8, "d b"),
        ("para one\nstill\n\npara two\n", 0, "} x"),
        ("para one\nstill\n\npara two\n", 0, "d }"),
        ("para one\nstill\n\npara two\n", 0, "d a p"),
        ("para one\nstill\n\npara two\n", 0, "y i p G p"),
        ("(a (b) c)\n", 0, "% x"),
        ("one two\nthree four\n", 0, "j l l l k x"),
        ("long line here\nab\nlonger line\n", 10, "j j x"),
        ("one two three\n", 0, "s t h x"),
        ("one two three\n", 12, "S t w x"),
        ("ab ab ab ab\n", 0, "s a b ; ; x"),
        ("ab ab ab ab\n", 0, "s a b ; ; , x"),
        ("ab ab ab ab\n", 10, "S a b ; x"),
        ("ab ab ab ab ab ab\n", 0, "2 s a b ; x"),
        ("one tw tw tw\n", 0, "f w s t w ; x"),
        ("one two three\n", 0, "\" a y w w \" a P"),
        ("one two three\n", 0, "\" _ d w"),
        ("  one\n", 2, "o x ESC"),
        ("- item\n", 3, "o x ESC"),
        ("- [ ] item\n", 3, "o x ESC"),
        ("1. item\n", 3, "o x ESC"),
        ("text\n- item\n", 8, "O x ESC"),
        ("- item\n  more\n", 9, "o x ESC"),
        ("* Heading\n", 3, "o x ESC"),
        ("one two three\n", 0, "v e ~"),
        ("one two three\n", 0, "v e U"),
        ("one\ntwo\nthree\n", 0, "V j >"),
        ("one\ntwo\nthree\n", 0, "v j J"),
        ("one two three\n", 0, "y i w w v e p"),
        ("a (b c) d\n", 0, "c i ( X ESC"),
        ("one two\n", 4, "d a w"),
        ("one   two\n", 4, "d i w"),
        ("one two three four\n", 0, "d 2 a w"),
        ("one two three\n", 4, "c $ X ESC"),
        ("one two three\n", 8, "d 0"),
        ("   one two\n", 8, "d ^"),
        ("one\ntwo\nthree\n", 4, "d G"),
        ("one\ntwo\nthree\n", 4, "d g g"),
        ("one two three\n", 4, "y $ P"),
        ("ab\n", 0, "x p"),
        ("one\ntwo\n", 0, "d d p"),
        ("abc\n", 1, "5 x"),
        ("abcdef\n", 1, "3 r x"),
        ("one two three four\n", 0, "x . ."),
        ("one two three four five\n", 0, "d w 2 ."),
        ("one   two\n", 3, "c w X ESC"),
        ("aXbXcXd\n", 0, "2 f X x"),
        ("one two three\n", 0, "w v $ d"),
        ("one\ntwo\nthree\n", 0, "j V d p"),
        ("x\n\n\ny\n", 0, "d }"),
        ("one two\n", 0, "e a X ESC b ."),
        ("one\n\nthree\n", 0, "j o x ESC"),
        ("one two\n", 0, "g U U"),
        ("a b\n", 0, "w i x ESC h ."),
        ("one two three\n", 4, "c c X ESC"),
        ("  one two\n", 4, "c c X ESC"),
        ("one two\n", 0, "> >"),
        ("    one two\n", 0, "< <"),
        ("one two\n", 0, "i a b DEL c ESC"),
        ("one two\n", 0, "i x C-w y ESC"),
        ("one two\n", 3, "a X ESC . ."),
        ("one\ntwo\n", 0, "A ; ESC j ."),
        ("one two three\n", 0, "3 l v l d"),
        ("one two three\n", 8, "v b d"),
        ("one two three\n", 0, "v 2 e c X ESC"),
        // evil-snipe-override-mode: f, F, t and T snipe one character, ; and , repeat over
        // the visible text, and the snipe's own keys repeat it right after.
        ("abc abc\nxbz abc\n", 0, "f c ; ; x"),
        ("abc abc\nxbz abc\n", 0, "f c f f x"),
        ("abc abc\nxbz abc\n", 0, "f c f F x"),
        ("abc abc abc\n", 10, "F b f x"),
        ("abc abc abc abc\n", 10, "F b F x"),
        ("abc abc\nxbz abc\n", 14, "T a ; x"),
        ("abc abc\nxbz abc\n", 0, "t c t x"),
        ("abc abc\nxbz abc\n", 0, "f c l f c x"),
        ("aAa\n", 0, "f a x"),
        ("aAa\n", 0, "f A x"),
        ("abab\n", 0, "t b x"),
        ("ab ab\n", 4, "T a x"),
        ("abc\nxbz\n", 2, "t z x"),
        ("a  b c\n", 0, "f SPC x"),
        ("a b\n", 0, "d f SPC"),
        ("a b c\n", 0, "t SPC x"),
        ("one two three\n", 0, "d t e"),
        ("one two three\n", 0, "c f o X ESC"),
        ("one two three\n", 12, "d F o"),
        ("one two three\n", 12, "d T o"),
        ("one two three\n", 0, "v f e d"),
        ("one two three\n", 0, "v t e d"),
        ("one two three\n", 0, "d f e ."),
        ("a1a2a3a4a5a6\n", 0, "2 f a ; x"),
        ("ab ab ab\n", 0, "s a b s S x"),
        ("ab ab ab\n", 0, "s a b d ;"),
        ("ab ab ab\n", 0, "v s a b d"),
        ("ab x\ncd ab\nab\n", 5, "s a b ; , x"),
        // A count after a snipe ends its repeat keys: the key snipes again with the count.
        ("a1a2a3a4a5a6a7\n", 0, "f a 2 f a x"),
        ("a1a2a3a4a5a6a7\n", 0, "f a f 2 f a x"),
        ("a1a2a3a4a5a6a7\n", 0, "f a 2 ; x"),
        ("a1a2a3a4a3\n", 0, "s a 2 2 s a 3 x"),
        // evil-snipe-char-fold: a letter matches its variants, in either case unless typed
        // as a capital.
        ("x à b á c\n", 0, "f a ; x"),
        ("x À b á c\n", 0, "f a x"),
        ("x à b À c\n", 0, "f A x"),
        ("x ü b ǜ c\n", 0, "f u ; x"),
        ("x ⓐ ａ ª\n", 0, "f a ; ; x"),
        ("x e\u{301}b\n", 0, "t b x"),
        ("x e\u{301}b\n", 0, "t e x"),
        ("x é b\n", 0, "s é SPC x"),
        ("x é É\n", 0, "f É x"),
        ("a\u{A0}b c\n", 0, "f SPC x"),
        ("one ﬁ fa\n", 0, "f f x"),
    ]

    /// Thirty lines of seven characters: line `i` starts at `7 * i`.
    static let lines = (0..<30).map { String(format: "line%02d\n", $0) }.joined()

    func driven(_ caret: Int, _ keys: String, halfPage: Int? = nil, visible: Range<Int>? = nil) -> Int {
        var driver = VimDriver(Self.lines, caret: caret)
        if let halfPage { driver.halfPage = halfPage }
        driver.visible = visible
        driver.type(Self.keys(keys))
        return driver.caret
    }

    @Test func zzAndZqRunExCommands() {
        var vim = Vim()
        let context = Vim.Context(text: "a\n", caret: 0)
        #expect(vim.feed(KeyChord("Z"), context) == [])
        #expect(vim.feed(KeyChord("Z"), context) == [.ex("wq")])
        _ = vim.feed(KeyChord("Z"), context)
        #expect(vim.feed(KeyChord("Q"), context) == [.ex("q!")])
    }

    @Test func snipeRepeatsOverTheVisibleText() {
        let text = "ab x\ncd ab\nab\n"
        func caret(_ keys: String, visible: Range<Int>?) -> Int {
            var driver = VimDriver(text, caret: 0)
            driver.visible = visible
            driver.type(Self.keys(keys))
            return driver.caret
        }
        // The snipe itself keeps to the line; repeats search what the window shows.
        #expect(caret("s a b ;", visible: nil) == 0)
        #expect(caret("s a b ;", visible: 0..<14) == 8)
        #expect(caret("s a b ; ;", visible: 0..<14) == 11)
        #expect(caret("s a b ; ; ,", visible: 0..<14) == 8)
        // After f, ; repeats the f.
        #expect(caret("s a b f x ;", visible: 0..<14) == 3)
    }

    @Test func halfPageScrollsFollowTheWindow() {
        #expect(driven(0, "C-d", halfPage: 5) == 35)
        #expect(driven(70, "C-u", halfPage: 5) == 35)
        #expect(driven(0, "C-d") == 105)
        #expect(driven(0, "3 C-d", halfPage: 5) == 21)
    }

    @Test func windowLines() {
        let shown = 70..<140
        #expect(driven(0, "H", visible: shown) == 70)
        #expect(driven(0, "3 H", visible: shown) == 84)
        #expect(driven(0, "2 0 H", visible: shown) == 133)
        #expect(driven(0, "L", visible: shown) == 133)
        #expect(driven(0, "2 L", visible: shown) == 126)
        #expect(driven(0, "M", visible: shown) == 98)
        #expect(driven(3, "H") == 3)
        // Linewise with an operator, and a jump.
        var driver = VimDriver(Self.lines, caret: 70)
        driver.visible = shown
        driver.type(Self.keys("d L"))
        #expect(driver.text == Self.lines.replacingOccurrences(of: (10..<20).map { String(format: "line%02d\n", $0) }.joined(), with: ""))
        var vim = Vim()
        let actions = vim.feed(KeyChord("L"), Vim.Context(text: Self.lines, caret: 70, visible: shown))
        #expect(actions == [.jumped(from: 70), .move(caret: 133)])
    }

    /// Replace state, and evil-numbers on the keys Doom binds (`g=`, `g-`, visual `g=`, `g-`
    /// and `g+`) and on `C-a`.
    static let replaceAndNumbers: [(String, Int, String)] = [
        ("hello world\n", 0, "R J E L ESC"),
        ("hello\n", 3, "R a b c d ESC"),
        ("hello world\n", 0, "R a b DEL DEL c ESC"),
        ("hello world\n", 0, "3 R x y ESC"),
        ("hello world\n", 2, "R a RET b ESC"),
        ("aaaa bbbb\n", 0, "R x y ESC w ."),
        ("item 7 and 12\n", 0, "g ="),
        ("item 7 and 12\n", 6, "5 g ="),
        ("item 7 and 12\n", 6, "g -"),
        ("value -3 here\n", 0, "4 g ="),
        ("count 009\n", 0, "g ="),
        ("count 010\n", 0, "g -"),
        ("addr 0xff\n", 0, "g ="),
        ("addr 0xFE\n", 0, "g ="),
        ("bits 0b0111\n", 0, "g ="),
        ("no digits\n", 0, "g ="),
        ("1\n1\n1\n", 0, "V j j g ="),
        ("1\n1\n1\n", 0, "V j j g +"),
        ("a 1 b 2\nc 3\n", 0, "V j 2 g -"),
        ("x 1 y\n", 0, "C-a"),
        ("x 1 y 2\n", 4, "3 C-a"),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func replaceAndNumbersMatchEvil() throws {
        let repos = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/emacs/.local/straight/repos")
        guard FileManager.default.fileExists(atPath: repos.appendingPathComponent("evil-numbers/evil-numbers.el").path) else { return }
        var forms: [EmacsOracle.Case] = []
        for (text, point, keys) in Self.replaceAndNumbers {
            forms.append(EmacsOracle.Case(text: text, point: point + 1, form: """
            (progn
              (setq evil-want-Y-yank-to-eol t evil-undo-system 'undo-redo)
              (dolist (p '("evil" "goto-chg" "evil-numbers" "emacs-shift-number")) (add-to-list 'load-path (concat "\(repos.path)/" p)))
              (require 'evil)
              (require 'evil-numbers)
              (evil-define-key 'normal 'global (kbd "g=") #'evil-numbers/inc-at-pt (kbd "g-") #'evil-numbers/dec-at-pt (kbd "C-a") #'evil-numbers/inc-at-pt)
              (evil-define-key 'visual 'global (kbd "g=") #'evil-numbers/inc-at-pt-incremental (kbd "g-") #'evil-numbers/dec-at-pt-incremental (kbd "g+") #'evil-numbers/inc-at-pt)
              (switch-to-buffer (current-buffer))
              (evil-local-mode 1)
              (evil-normal-state)
              (execute-kbd-macro (kbd "\(keys.replacingOccurrences(of: "ESC", with: "<escape>").replacingOccurrences(of: "DEL", with: "DEL"))"))
              (let ((p (point)) (s evil-state))
                (goto-char (point-max))
                (insert (format "\\n@@STATE %s" s))
                (goto-char p)))
            """))
        }
        let results = try EmacsOracle.run(forms)
        for ((text, point, keys), result) in zip(Self.replaceAndNumbers, results) {
            var driver = VimDriver(text, caret: point)
            driver.visible = 0..<text.utf16.count
            driver.type(Self.keys(keys))
            guard let marker = result.text.range(of: "\n@@STATE ") else {
                Issue.record("\(keys): \(result.error)")
                continue
            }
            let emacsText = String(result.text[..<marker.lowerBound])
            let state = String(result.text[marker.upperBound...])
            let ours = driver.vim.mode == .normal ? "normal" : driver.vim.mode.rawValue
            let emacsCaret = EmacsOracle.offset(result.point, in: result.text)
            #expect(driver.text == emacsText && driver.caret == emacsCaret && ours == state,
                    "\(keys.debugDescription) on \(text.debugDescription) at \(point)\nours:  \(driver.text.debugDescription) @\(driver.caret) \(ours)\nevil:  \(emacsText.debugDescription) @\(emacsCaret) \(state) \(result.error)")
        }
    }

    @Test func scrollsAndOpensTheCommandWindow() {
        var vim = Vim()
        let text = "one\n  two\nthree\n"
        #expect(vim.feed(KeyChord("z"), Vim.Context(text: text, caret: 0)) == [])
        #expect(vim.feed(KeyChord("z"), Vim.Context(text: text, caret: 0)) == [.scroll(.center)])
        _ = vim.feed(KeyChord("2"), Vim.Context(text: text, caret: 0))
        _ = vim.feed(KeyChord("z"), Vim.Context(text: text, caret: 0))
        #expect(vim.feed(KeyChord("RET"), Vim.Context(text: text, caret: 0)) == [.move(caret: 6), .scroll(.top)])
        _ = vim.feed(KeyChord("q"), Vim.Context(text: text, caret: 0))
        #expect(vim.feed(KeyChord(":"), Vim.Context(text: text, caret: 0)) == [.commandWindow(":")])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEvil() throws {
        let evil = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/emacs/.local/straight/repos")
        guard FileManager.default.fileExists(atPath: evil.appendingPathComponent("evil/evil.el").path) else { return }
        var forms: [EmacsOracle.Case] = []
        for (text, point, keys) in Self.cases {
            forms.append(EmacsOracle.Case(text: text, point: point + 1, form: """
            (progn
              (setq evil-want-Y-yank-to-eol t evil-undo-system 'undo-redo evil-want-C-w-delete t evil-want-C-u-delete t evil-shift-width 8)
              (add-to-list 'load-path "\(evil.path)/evil")
              (add-to-list 'load-path "\(evil.path)/goto-chg")
              (add-to-list 'load-path "\(evil.path)/evil-snipe")
              (require 'evil)
              (require 'evil-snipe)
              (setq evil-snipe-smart-case t evil-snipe-scope 'line evil-snipe-repeat-scope 'visible evil-snipe-char-fold t)
              (setq kill-ring nil)
              (switch-to-buffer (current-buffer))
              (evil-local-mode 1)
              (evil-snipe-local-mode 1)
              (evil-snipe-override-local-mode 1)
              (evil-normal-state)
              (execute-kbd-macro (kbd "\(keys.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "ESC", with: "<escape>").replacingOccurrences(of: "DEL", with: "DEL"))"))
              (let ((p (point)) (s evil-state))
                (goto-char (point-max))
                (insert (format "\\n@@STATE %s" s))
                (goto-char p)))
            """))
        }
        let results = try EmacsOracle.run(forms)
        for ((text, point, keys), result) in zip(Self.cases, results) {
            var driver = VimDriver(text, caret: point)
            // A batch Emacs window shows the whole buffer.
            driver.visible = 0..<text.utf16.count
            driver.type(Self.keys(keys))
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
