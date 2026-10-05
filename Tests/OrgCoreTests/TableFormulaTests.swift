import Foundation
import Testing
@testable import OrgCore

struct TableFormulaTests {
    static let tables = [
        "| a | b |\n|---+---|\n| 1 |   |\n| 2 |   |\n| 3 |   |\n#+TBLFM: $2=$1*2\n",
        "| x | y | sum |\n|---+---+-----|\n| 1 | 2 |     |\n| 3.5 | 4 | |\n|---+---+-----|\n|   |   |     |\n#+TBLFM: $3=$1+$2::@>$1=vsum(@I..@II)::@>$2=vmean(@2$2..@3$2)\n",
        "| qty | price | total | share |\n|-----+-------+-------+-------|\n| 3 | 19.99 | | |\n| 1 | 5 | | |\n| 12 | 0.5 | | |\n|-----+-------+-------+-------|\n| | | | |\n#+TBLFM: $3=$1*$2;%.2f::$4=$3/@>$3;f3::@>$3=vsum(@I..@II)\n",
        "| n | sq | cube | root |\n|---+----+------+------|\n| 1 | | | |\n| 2 | | | |\n| 10 | | | |\n#+TBLFM: $2=$1^2::$3=$1^3::$4=sqrt($1)\n",
        "| a | b |\n| 1 | |\n| 2 | |\n| 7 | |\n#+TBLFM: $2=$1/2\n",
        "| a | prev | next |\n|---+------+------|\n| 1 | | |\n| 2 | | |\n| 3 | | |\n#+TBLFM: $2=@-1$1::$3=@+1$1\n",
        "| a | b | c |\n|---+---+---|\n| 1 | 2 | |\n| 4 | 5 | |\n#+TBLFM: $3=$-1*$-2::@2$3=100\n",
        "| r | v |\n|---+---|\n| 1 | |\n| 2 | |\n| 3 | |\n#+TBLFM: @2$2..@4$2=$1*10\n",
        "| r | v |\n|---+---|\n| 1 | |\n| 2 | |\n#+TBLFM: $>=@#*$#\n",
        "| a | b | c |\n|---+---+---|\n| 1 |   | |\n|   | 2 | |\n#+TBLFM: $3=$1+$2\n",
        "| a | b |\n|---+---|\n| 5 | |\n| 6 | |\n#+TBLFM: $2=$1*3\n#+TBLFM: $2=$1+100\n",
        "| a | b |\n|---+---|\n| 1 |\n| 2 | |\n#+TBLFM: $3=$1*$1\n",
        "| a | b | c |\n|---+---+---|\n| 1 | 2 | |\n| 3 | 4 | |\n#+TBLFM: $3=vsum($1..$2)::@2=7\n",
        "| a | b |\n|---+---|\n| 1.25 | |\n| 0.1 | |\n| 1e3 | |\n| -2 | |\n#+TBLFM: $2=$1/7\n",
        "| deg | sin | cos |\n|-----+-----+-----|\n| 0 | | |\n| 30 | | |\n| 45 | | |\n| 90 | | |\n#+TBLFM: $2=sin($1)::$3=cos($1);%.3f\n",
        "  | a | b |\n  |---+---|\n  | 2 |   |\n  | 3 |   |\n  #+TBLFM: $2=$1^0.5;n4\n",
        "| a | b |\n|---+---|\n| x | |\n| 2 | |\n#+TBLFM: $2=$1*2\n",
        "| a | b |\n|---+---|\n| 1 | |\n|---+---|\n| 2 | |\n| 3 | |\n#+TBLFM: $2=@I$1+@II$1+@-I$1\n",
        "| a | b | c |\n|---+---+---|\n| 1 | 2 | |\n#+TBLFM: $3=($1+$2)*2/3-1::$1=$1\n",
        "| a |\n|---|\n| 1 |\n| 2 |\n|---|\n| |\n#+TBLFM: @>$1=vmax(@I..@II)-vmin(@I..@II)+vcount(@I..@II)+vmedian(@I..@II)\n",
    ]

    static func carets(_ text: String) -> [Int] {
        let ns = text as NSString
        var result: [Int] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line)
            if let bar = content.firstIndex(of: "|"), !content.contains("|-") {
                // Inside the first field of the row.
                result.append(line.location + content.distance(from: content.startIndex, to: bar) + 2)
            }
            if content.uppercased().contains("#+TBLFM") { result.append(line.location + 3) }
            location = NSMaxRange(line)
        }
        return result
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, caret: Int, failure: String?)] = []
        for text in Self.tables {
            for caret in Self.carets(text) {
                let onTblfm = (text as NSString).substring(with: (text as NSString).lineRange(for: NSRange(location: caret, length: 0))).uppercased().contains("#+TBLFM")
                let commands: [(any OrgCommand, String)] = onTblfm
                    ? [(TableRecalculate(all: true), "(org-ctrl-c-ctrl-c)")]
                    : [(TableRecalculate(all: true), "(org-table-recalculate t)"), (TableRecalculate(all: false), "(org-table-recalculate nil)")]
                for (command, form) in commands {
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: form))
                    ours.append(runCommand(command, text, caret: caret))
                }
            }
        }
        let emacs = try EmacsOracle.run(cases)
        var fallbacks = 0
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            if let failure = mine.failure, failure.hasPrefix("external:") {
                fallbacks += 1
                // Emacs gives symbolic results for text and division by zero.
                #expect(failure.contains("non-numeric field") || failure.contains("division by zero"), "\(failure)")
                continue
            }
            if !theirs.error.isEmpty {
                // Emacs keeps the fields written before the error; nothing changes here.
                #expect(mine.failure == theirs.error && mine.text == cases[i].text)
                continue
            }
            let expected = (theirs.text, EmacsOracle.offset(theirs.point, in: theirs.text), theirs.error.isEmpty ? nil : theirs.error)
            #expect(mine.text == expected.0 && mine.caret == expected.1 && mine.failure == expected.2,
                    "\(cases[i].form) at \(cases[i].point) in\n\(cases[i].text)\nours:\n\(mine.text)@\(mine.caret) \(mine.failure ?? "")\nemacs:\n\(theirs.text)@\(expected.1) \(theirs.error)")
        }
        #expect(fallbacks < ours.count / 2, "\(fallbacks) fallbacks")
    }

    /// `ORGSTAR_ORACLE_CORPUS=<folder>`: C-c C-c on every `#+TBLFM` line below the folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func corpusMatchesEmacs() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "org" }.sorted { $0.path < $1.path }
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, caret: Int, failure: String?)] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.uppercased().contains("#+TBLFM") else { continue }
            let ns = text as NSString
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                if ns.substring(with: line).trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#+TBLFM") {
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(line.location, in: text), form: "(org-ctrl-c-ctrl-c)"))
                    ours.append(runCommand(TableRecalculate(all: true), text, caret: line.location))
                }
                location = NSMaxRange(line)
            }
        }
        let emacs = try EmacsOracle.run(cases)
        for (mine, theirs) in zip(ours, emacs) where !(mine.failure ?? "").hasPrefix("external:") {
            #expect(mine.text == theirs.text, "\(mine.failure ?? "")")
        }
        print("TBLFM lines: \(cases.count), native: \(ours.filter { !($0.failure ?? "").hasPrefix("external:") }.count)")
    }
}
