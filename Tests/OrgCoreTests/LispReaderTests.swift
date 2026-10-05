import Foundation
import Testing
@testable import OrgCore

struct LispReaderTests {
    @Test func readsForms() throws {
        let text = #"""
        ;; comment
        (setq org-tags-column -77 ; inline
              fill-column 80)
        (after! org (setq org-agenda-start-day "-3d\n" x 1.5 c ?a d ?\C-x))
        (map! :leader :desc "Save" "f s" #'save-buffer)
        '(a . b) `(x ,y ,@z) [1 2] nil
        """#
        let forms = try LispReader.read(text)
        #expect(forms.map(\.line) == [2, 4, 5, 6, 6, 6, 6])
        #expect(forms[0].sexp == .list([.symbol("setq"), .symbol("org-tags-column"), .integer(-77), .symbol("fill-column"), .integer(80)]))
        #expect(forms[1].sexp.description == "(after! org (setq org-agenda-start-day \"-3d\\n\" x 1.5 c ?a d ?x))")
        #expect(forms[2].sexp.elements?.last == .list([.symbol("function"), .symbol("save-buffer")]))
        #expect(forms[3].sexp == .list([.symbol("quote"), .dotted([.symbol("a")], .symbol("b"))]))
        #expect(forms[4].sexp.description == "`(x ,y ,@z)")
        #expect(forms[5].sexp == .vector([.integer(1), .integer(2)]))
        #expect(throws: LispReader.ReadError.self) { try LispReader.read("(setq a") }
    }

    /// Every Lisp file of the installed Doom Emacs and the user's Doom config reads.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/emacs/lisp")))
    func readsDoom() throws {
        var failures: [String] = []
        for folder in ["/.config/emacs/lisp", "/.config/emacs/modules/lang/org", "/.config/doom"] {
            guard let files = FileManager.default.enumerator(atPath: NSHomeDirectory() + folder) else { continue }
            for case let file as String in files where file.hasSuffix(".el") {
                let path = NSHomeDirectory() + folder + "/" + file
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                do { _ = try LispReader.read(text) } catch { failures.append("\(path): \(error)") }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
