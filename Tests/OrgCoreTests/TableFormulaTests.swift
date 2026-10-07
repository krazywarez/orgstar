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
        "#+CONSTANTS: c=10 k=2.5\n| a | b |\n|---+---|\n| 1 | |\n| 2 | |\n#+TBLFM: $2=$1*$c+$k\n",
        "* Rates\n:PROPERTIES:\n:Rate:     3\n:END:\n| h | pay |\n|---+-----|\n| 2 | |\n#+TBLFM: $2=$1*$PROP_Rate\n",
    ]

    /// Lisp formulas, names, parameters, marked rows, remote tables, durations, dates and
    /// the rest that once needed Emacs: all run natively.
    static let native = [
        "| a | b |\n|---+---|\n| hello | |\n| x \"q\" | |\n|  | |\n#+TBLFM: $2='(concat $1 \"!\")\n",
        "| a | b |\n|---+---|\n| 1 | |\n| 2.5 | |\n| x | |\n#+TBLFM: $2='(* 2 $1);N\n",
        "| a | b | c |\n|---+---+---|\n| 1 | 2 | |\n| 3 | 4 | |\n#+TBLFM: $3='(+ $1 $2);L\n",
        "| a |\n|---|\n| 1 |\n| 2 |\n|---|\n| |\n#+TBLFM: @>$1='(apply '+ '(@I..@II));N\n",
        "| a | b |\n|---+---|\n| 1 | |\n#+TBLFM: $2='(car 1)\n",
        "| a | b | c |\n|---+---+---|\n| 3.14159 | | |\n| 2 | | |\n#+TBLFM: $2='(format \"%05.1f\" $1);N::$3='(+ $1 1);N%.2f\n",
        "| a | b |\n|---+---|\n| 5 | |\n| 12 | |\n#+TBLFM: $2='(if (> $1 10) \"big\" \"small\");N\n",
        "| ! | qty | price | total |\n|---+-----+-------+-------|\n|   | 2 | 3 | |\n|   | 4 | 0.5 | |\n#+TBLFM: $4=$qty*$price\n",
        "|   | x | y |\n|---+---+---|\n| # | 2 |   |\n|   | 3 |   |\n| * | 4 |   |\n| $ | k=10 | |\n#+TBLFM: $3=$2*$k\n",
        "|   | a  | b  |\n|---+----+----|\n|   | 1  | 2  |\n| ^ | aa | bb |\n| _ |    | cc |\n|   |    |    |\n#+TBLFM: $cc=$aa+$bb::$2=7\n",
        "|   | a  | b  |\n|---+----+----|\n|   | 1  | 2  |\n| _ |    | dd |\n#+TBLFM: $dd=1\n",
        "| start | end | sum | diff | hours |\n|-------+-----+-----+------+-------|\n| 1:30 | 0:45 | | | |\n| 10:00:30 | 2:15:10 | | | |\n|-------+-----+-----+------+-------|\n| | | | | |\n#+TBLFM: $3=$1+$2;T::$4=$1-$2;U::$5=$1*2;t::@>$1=vsum(@I..@II);T\n",
        "| d1 | d2 | days | later |\n|----+----+------+-------|\n| <2026-10-05 Mon> | <2026-10-12 Mon> | | |\n| [2026-01-31 Sat] | [2026-03-01 Sun] | | |\n| <2026-10-05 Mon 08:30> | <2026-10-05 Mon 10:00> | | |\n#+TBLFM: $3=$2-$1::$4=$1+7\n",
        "| d | until |\n|---+-------|\n| <2026-10-05 Mon> | |\n#+TBLFM: $2=<2026-12-25 Fri>-$1\n",
        "| a | b | c | d |\n|---+---+---+---|\n| 1 |   | | |\n| 2 | 3 | | |\n#+TBLFM: $3=$1+$2;E::$4=vcount($1..$2);E\n",
        "| a | b | c |\n|---+---+---|\n| 5 | 3 | |\n| 2 | 9 | |\n#+TBLFM: $3=if($1>$2, $1, $2)\n",
        "| a | b | c |\n|---+---+---|\n| 7 | 3 | |\n| -7 | 2 | |\n#+TBLFM: $3=$1%$2+$1\\$2*100\n",
        "#+NAME: rates\n| item | rate |\n|------+------|\n| a    | 2    |\n| b    | 3    |\n\n| x | y | z | w |\n|---+---+---+---|\n| 4 | | | |\n#+TBLFM: $2=$1*remote(rates,@2$2)::$3=remote(rates, B3)::$4=vsum(remote(rates,@2$2..@>$2))\n",
        "#+NAME: prices\n| fruit | price |\n|-------+-------|\n| apple | 1.5 |\n| pear | 2 |\n\n| item | cost |\n|------+------|\n| pear | |\n| plum | |\n#+TBLFM: $2='(org-lookup-first $1 '(remote(prices,@2$1..@>$1)) '(remote(prices,@2$2..@>$2)))\n",
        "#+CONSTANTS: c=3\n| a | b | c |\n|---+---+---|\n| 2 | | |\n#+TBLFM: $2='(* $c $1);N::$3=$1*$c\n",
        "|   | a | b |\n|---+---+---|\n|   | 2 | |\n|   | 3 | |\n| $ | %=%.2f | |\n#+TBLFM: $3=$2/3;\n",
        "| a | b |\n|---+---|\n| 4 | |\n| 9 | |\n#+TBLFM: $2=vsdev(@I$1..@II$1)+fact(3)\n",
        "| a | b |\n|---+---|\n| 1 |   |\n| 2 |   |\n#+TBLFM: @-1$2=5\n",
        "| a | b | f |\n|---+---+---|\n| 1 | 3 |  |\n| 7 | 2 |  |\n| -7 | 2 |  |\n| 6 | 3 |  |\n| 1 | 0.5 |  |\n| 4 | 6 |  |\n#+TBLFM: $3=$1/$2;F\n",
        "| a |\n|---|\n|  |\n|  |\n|  |\n|  |\n|  |\n|  |\n|  |\n|  |\n|  |\n#+TBLFM: @2$1=1/3+1/6;F::@3$1=(1/3)^2;F::@4$1=vsum([1/2,1/3]);F::@5$1=1/3*3;F::@6$1=sqrt(1/4);F::@7$1=vmean([1,2]);F::@8$1=2^-2;F::@9$1=abs(-1/3)+max(1/3,1/4);F::@10$1=round(7/2)+floor(7/2);F\n",
    ]

    @Test func remoteFindsTablesByIDInOtherFiles() {
        let other = "* Elsewhere\n:PROPERTIES:\n:ID: far\n:END:\n| v |\n|---|\n| 7 |\n"
        RemoteTables.fileWithID = { $0 == "far" ? other : nil }
        defer { RemoteTables.fileWithID = nil }
        let text = "| x | y |\n|---+---|\n| 3 | |\n#+TBLFM: $2=$1*remote(far,@2$1)\n"
        let result = runCommand(TableRecalculate(all: true), text, caret: (text as NSString).range(of: "#+TBLFM").location + 3)
        #expect(result.text.contains("| 3 | 21 |"), "\(result)")
        // As Emacs does in a file buffer (`org-id-find` needs one): the entry's first table.
        let local = "* Rates\n:PROPERTIES:\n:ID: rates-id\n:END:\n| item | rate |\n|------+------|\n| a    | 2    |\n* Use\n| x | y |\n|---+---|\n| 4 | |\n#+TBLFM: $2=$1*remote(rates-id,@2$2)\n"
        #expect(runCommand(TableRecalculate(all: true), local, caret: (local as NSString).range(of: "#+TBLFM").location + 3).text.contains("| 4 | 8 |"))
        let missing = runCommand(TableRecalculate(all: true), text.replacingOccurrences(of: "far", with: "nowhere"), caret: 2)
        #expect(missing.failure == "Can't find remote table \"nowhere\"")
    }

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
        try compare(Self.tables, fallbacksAllowed: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func extendedFormulasMatchEmacsNatively() throws {
        try compare(Self.native, fallbacksAllowed: false)
    }

    func compare(_ tables: [String], fallbacksAllowed: Bool) throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, caret: Int, failure: String?)] = []
        for text in tables {
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
                // Calc keeps text as symbols, which goes to Emacs.
                #expect(fallbacksAllowed || failure.contains("non-numeric field"), "\(failure) in\n\(cases[i].text)")
                // Emacs gives symbolic results for text and division by zero.
                #expect(failure.contains("non-numeric field") || failure.contains("division by zero"), "\(failure)")
                continue
            }
            if !theirs.error.isEmpty {
                // Emacs keeps the fields written before the error; nothing changes here.
                #expect(mine.failure == theirs.error && mine.text == cases[i].text,
                        "\(cases[i].form) at \(cases[i].point): ours \(mine.failure ?? "-"), emacs \(theirs.error)\n\(cases[i].text)")
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
