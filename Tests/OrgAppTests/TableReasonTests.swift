import Foundation
import Testing
@testable import OrgApp

/// Every reason OrgCore gives for sending a table to Emacs has a translation.
struct TableReasonTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyReasonIsKnown() throws {
        let files = FileManager.default.enumerator(atPath: Self.root.appendingPathComponent("Sources/OrgCore").path)?.allObjects as? [String] ?? []
        var reasons: [String] = [], lisp: [String] = []
        for file in files where file.hasSuffix(".swift") {
            let text = try String(contentsOf: Self.root.appendingPathComponent("Sources/OrgCore/" + file), encoding: .utf8)
            // An interpolated value stands as "x", as it would read at run time.
            func sample(_ literal: Substring) -> String {
                var out = "", depth = 0, chars = Array(literal), i = 0
                while i < chars.count {
                    if depth == 0, chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                        out += "x"
                        depth = 1
                        i += 2
                        continue
                    }
                    if depth > 0 {
                        if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                    } else {
                        out.append(chars[i])
                    }
                    i += 1
                }
                return out
            }
            reasons += text.matches(of: /Unsupported\("((?:[^"\\]|\\\([^)]*\)+)*)"/).map { sample($0.1) }
            lisp += text.matches(of: /Unsupported\(what: "((?:[^"\\]|\\\([^)]*\)+)*)"/).map { sample($0.1) }
        }
        #expect(reasons.count > 30 && lisp.count >= 5)
        for reason in Set(reasons) where !reason.hasPrefix("Lisp ") {
            #expect(TableReason.translated(reason) != nil, "\(reason)")
        }
        for what in Set(lisp) {
            #expect(TableReason.translated("Lisp " + what) != nil, "Lisp \(what)")
        }
        #expect(TableReason.localized("something new") == "something new")
    }
}
