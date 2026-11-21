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
        // Errors partway through: the fields written before them stay.
        "| a | b | c |\n|---+---+---|\n| 1 | | |\n| 22 | | |\n| 3 | | |\n#+TBLFM: $2=$1*2::$3=@-2$1\n",
        "| a | b | c |\n|---+---+---|\n| 1 | | |\n| 22 | | |\n| 3 | | |\n#+TBLFM: $2=$1*2::@3$3=@-5$1::@2$3=7\n",
        "| a | b |\n|---+---|\n| 1 |  |\n| 2 |  |\n#+TBLFM: $2=$1::@I$1=3\n",
        "| a | b |\n|---+---|\n| 1 |  |\n| 2 |  |\n#+TBLFM: $2=$1*3::@2$2=1::@2$1..@3$2=5\n",
        // A field formula's field of one space still gets the column formula first.
        "| a | b |\n|---+---|\n| # | |\n| 2 | |\n#+TBLFM: $2=@0$1+1::@3$2=$2*10\n",
        "| a | b |\n|---+---|\n| # |  |\n| 2 |  |\n| 3 ||\n#+TBLFM: $2=@0$1+1::@3$2=$2*10::@4$2=$2*10\n",
    ]

    /// Lisp formulas, names, parameters, marked rows, remote tables, durations, dates and
    /// the rest that once needed Emacs: all run natively.
    static let native = [
        "| a | b | c | d | mean | ratio | gmean | more |\n|---+---+---+---+------+-------+-------+------|\n| 1:30 | 2 | 3 | 4.5 | | | | |\n| 2:4 | 5 | 1 | 2 | | | | |\n#+TBLFM: $5=vmean($2..$3,$4)::$6=$2/$3;p15::$7=vgmean($2..$4);f3::$8=$4% + $1 2 + roundu($4) + hypot($2,$3)\n",
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
        "| 10 | 20 | |\n| 1 | 2 | |\n| 3 | 4 | |\n#+TBLFM: $3=@0$1+@0$2*10\n",
        "#+NAME: t1\n| 5 | 6 |\n| 1 | 2 |\n\n#+NAME: t2\n| 7 | 8 |\n\n| name | val | sum |\n|------+-----+-----|\n| t1 | | |\n| t2 | | |\n#+TBLFM: $2=remote($1,@1$1)::$3=vsum(remote(t1,$1..$2))+vsum($1..$2)\n",
    ]

    /// Timestamps in fields and formulas, with and without the duration flags, and Calc's
    /// date functions.
    static let dates = [
        "| d1 | d2 | diff | T | t | U | N |\n|----+----+------+---+---+---+---|\n| <2026-01-01 Thu> | <2026-01-03 Sat> | | | | | |\n| <2026-01-01 Thu 10:00> | <2026-01-03 Sat 12:30> | | | | | |\n| [2026-01-01 Thu] | <2026-01-03 Sat 00:00> | | | | | |\n#+TBLFM: $3=$2-$1::$4=$2-$1;T::$5=$2-$1;t::$6=$2-$1;U::$7=$2-$1;N\n",
        "| d | later | T | left |\n|---+-------+---+------|\n| <2026-10-05 Mon 00:00> | | | |\n| <2026-10-05 Mon 23:30> | | | |\n| [2026-10-05 Mon 12:00] | | | |\n#+TBLFM: $2=$1+0.5::$3=$1+1;T::$4=<2026-12-25 Fri>-$1\n",
        "| d | y | m | wd | yd | h | next | start | week | year |\n|---+---+---+----+----+---+------+-------+------+------|\n| <2026-10-05 Mon> | | | | | | | | | |\n| <2026-01-31 Sat 09:15> | | | | | | | | | |\n| [2024-02-29 Thu] | | | | | | | | | |\n#+TBLFM: $2=year($1)::$3=month($1)::$4=weekday($1)::$5=yearday($1)::$6=hour($1)+minute($1)::$7=incmonth($1,1)::$8=newmonth($1)::$9=newweek($1,1)::$10=incyear($1)\n",
        "| d | due | days | jd | n | back |\n|---+-----+------+----+---+------|\n| <2026-10-09 Fri> | | | | | |\n| <2026-10-10 Sat 08:00> | | | | | |\n#+TBLFM: $2=badd($1,3)::$3=bsub(badd($1,10),$1)::$4=julian(floor($1))::$5=date($1)::$6=date(2026,1,1)+floor($1-date(2026,1,1))\n",
        "| d | abs | next |\n|---+-----+------|\n| <2026-01-01 Thu> | | |\n| <0070-01-01 Thu> | | |\n| [0010-01-01 Fri] | | |\n#+TBLFM: $2=abs(-$1)::$3=$1+1\n",
        "| d |\n|---|\n| <2026-10-05 Mon> |\n| <2026-10-07 Wed 06:00> |\n|---|\n| |\n| |\n| |\n#+TBLFM: @4$1=vmean(@I..@II)::@5$1=vmin(@I..@II)::@6$1=vmax(@I..@II)\n",
    ]

    /// Results that aren't numbers under `N` and the duration flags: `#ERROR`, or for a
    /// duration an error.
    static let numericResults = [
        "| a | b | c | d | e | f | g |\n|---+---+---+---+---+---+---|\n| <2026-01-01 Thu> | | | | | | |\n#+TBLFM: $2=<2026-01-01 Thu>+$1;N::$3=<2026-01-01 Thu>;E::$4=<2026-01-01 Thu>;EN::$5=<2026-01-01 Thu>;ET::$6=nan;N::$7=1/3;NF\n",
        "| a | b |\n|---+---|\n| 1 | |\n#+TBLFM: $2=$1/3;TF\n",
        "| a | b |\n|---+---|\n| 1 | |\n#+TBLFM: $2=nan;T\n",
        "| a | b |\n|---+---|\n| <2026-01-01 Thu> | |\n#+TBLFM: $2=<2026-12-25 Fri>-$1;U\n",
    ]

    /// Text and blank fields, which Calc reads as variables and zero, and the `S` flag.
    static let symbolic = [
        "| item | cost |\n|------+------|\n| a | 5 |\n| b | N/A |\n| c | 3 |\n|------+------|\n| total | |\n| mean | |\n#+TBLFM: @>>$2=vsum(@I..@II)::@>$2=vmean(@I..@II)\n",
        "| a | b | ratio | twice |\n|---+---+-------+-------|\n| 6 | 0 | | |\n| 6 | | | |\n| 4.5 | 2 | | |\n| TBD | 4 | | |\n| 5 kg | 2 | | |\n#+TBLFM: $3=$1/$2::$4=2*$1+$2\n",
        "| r | area | half |\n|---+------+------|\n| 3 | | |\n| x | | |\n#+TBLFM: $2=$1^2*pi::$3=$2/2;S\n",
        "| a | b | c | d |\n|---+---+---+---|\n| 1 | | n/a | |\n| 2 | 3 | | |\n#+TBLFM: $4=vsum($1..$3)::@2$2=$1 + inf;S\n",
        "| a | b | c |\n|---+---+---|\n| x | 1 | |\n| | 2 | |\n#+TBLFM: $3=$1*$2;E\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func textAndBlankFieldsMatchEmacsNatively() throws {
        try compare(Self.symbolic, fallbacksAllowed: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func datesMatchEmacs() throws {
        try compare(Self.dates + Self.numericResults, fallbacksAllowed: false)
    }

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

    /// Lisp formulas with regexps, math, sequences, loops and dates: all run natively.
    static let lisp = [
        "| name | starred | words |\n|------+---------+-------|\n| apple pie | | |\n| kiwi | | |\n#+TBLFM: $2='(replace-regexp-in-string \"[aeiou]\" \"*\" $1)::$3='(length (split-string $1))\n",
        "| code | number |\n|------+--------|\n| ab-12 | |\n| none | |\n#+TBLFM: $2='(if (string-match \"[0-9]+\" $1) (match-string 0 $1) \"-\")\n",
        "| n | root | square | sum |\n|---+------+--------+-----|\n| 4 | | | |\n| 10 | | | |\n#+TBLFM: $2='(sqrt $1);N::$3='(expt $1 2);N::$4='(cl-loop for i from 1 to $1 sum i);N\n",
        "| day | weekday | since |\n|-----+---------+-------|\n| <2026-11-20 Fri> | | |\n| [2026-03-01 Sun] | | |\n#+TBLFM: $2='(format-time-string \"%A\" (org-time-string-to-time $1))::$3='(- (org-time-string-to-absolute $1) (org-time-string-to-absolute \"<2026-01-01 Thu>\"))\n",
        "| tags | sorted |\n|------+--------|\n| c,a,b | |\n#+TBLFM: $2='(string-join (sort (split-string $1 \",\") #'string<) \"+\")\n",
        "| kind | label |\n|------+-------|\n| 1 | |\n| 2 | |\n| 7 | |\n#+TBLFM: $2='(pcase $1 (1 \"one\") (2 \"two\") (_ \"many\"));N\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func lispFormulasMatchEmacsNatively() throws {
        try compare(Self.lisp, fallbacksAllowed: false)
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
                    ours.append(Self.recalculate(command, text, caret: caret))
                }
            }
        }
        let emacs = try EmacsOracle.run(cases)
        var fallbacks = 0
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            if let failure = mine.failure, failure.hasPrefix("external:") {
                fallbacks += 1
                // Formulas over a header's text that Calc would leave symbolic in ways not
                // reproduced go to Emacs.
                #expect(fallbacksAllowed || failure.contains("symbolic") || failure.contains("of a formula"), "\(failure) in\n\(cases[i].text)")
                continue
            }
            let expected = (theirs.text, EmacsOracle.offset(theirs.point, in: theirs.text), theirs.error.isEmpty ? nil : theirs.error)
            #expect(mine.text == expected.0 && mine.caret == expected.1 && mine.failure == expected.2,
                    "\(cases[i].form) at \(cases[i].point) in\n\(cases[i].text)\nours:\n\(mine.text)@\(mine.caret) \(mine.failure ?? "")\nemacs:\n\(theirs.text)@\(expected.1) \(theirs.error)")
        }
        #expect(fallbacks < ours.count / 2, "\(fallbacks) fallbacks")
    }

    /// Two formulas, then one only Emacs can do: in row order, as Emacs applies them.
    static let unsupported = "| a | b | c | d |\n|---+---+---+---|\n| 1 | | | |\n| 2 | | | |\n#+TBLFM: $2=$1*2::$3=$1+1::$4='(shell-command-to-string $1)\n"

    @Test func keepsFieldsWrittenBeforeAFormulaOnlyEmacsCanDo() {
        let text = Self.unsupported
        let caret = (text as NSString).range(of: "#+TBLFM").location + 3
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
        guard case .external(.emacsTable(_, _, _, let reason, let lisp, let formula, let partial?)) = TableRecalculate(all: true).run(in: context) else {
            Issue.record("not a request")
            return
        }
        #expect(reason == "Lisp function shell-command-to-string")
        #expect(lisp)
        #expect(formula == "$4")
        let result = partial.edits.reduce(text) { $1.apply(to: $0) }
        #expect(result == "| a | b | c | d |\n|---+---+---+---|\n| 1 | 2 | 2 | |\n| 2 | | | |\n#+TBLFM: $2=$1*2::$3=$1+1::$4='(shell-command-to-string $1)\n")
        // Point stays on the #+TBLFM line, after the two digits written.
        #expect(partial.selection == [(caret + 4)..<(caret + 4)])
    }

    /// The fields kept before a formula only Emacs can do are what Emacs leaves when that
    /// formula fails instead.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func keptFieldsMatchEmacsAfterAnError() throws {
        let failing = "@-9$1"
        let lisp = "'(shell-command-to-string $1)"
        let tables = [
            Self.unsupported,
            "| a | b | c |\n|---+---+---|\n| 1 | | |\n| 2 | | |\n| 3 | | |\n#+TBLFM: $2=$1*3::@3$3=\(lisp)::@2$3=7::@4$3=8\n",
            "| a | b |\n|---+---|\n| # | |\n| 2 | |\n#+TBLFM: $2=@0$1+1::@3$2=\(lisp)\n",
            "|   | a | b | c |\n|---+---+---+---|\n| # | 1 |   |   |\n#+TBLFM: $3=$2*2::$4=\(lisp)\n",
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, caret: Int)] = []
        for text in tables {
            let emacsText = text.replacingOccurrences(of: lisp, with: failing)
            for caret in Self.carets(text) {
                let onTblfm = (text as NSString).substring(with: (text as NSString).lineRange(for: NSRange(location: caret, length: 0))).contains("#+TBLFM")
                let commands: [(any OrgCommand, String)] = onTblfm
                    ? [(TableRecalculate(all: true), "(org-ctrl-c-ctrl-c)")]
                    : [(TableRecalculate(all: true), "(org-table-recalculate t)"), (TableRecalculate(all: false), "(org-table-recalculate nil)"), (TableIterate(), "(org-table-iterate)"),
                       (TableCommand(.nextField), "(org-table-next-field)"), (TableCommand(.previousField), "(org-table-previous-field)"), (TableCommand(.nextRow), "(org-table-next-row)")]
                for (command, form) in commands {
                    let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
                    let step = command.run(in: context)
                    // Rows at point without the Lisp formula, and header rows Calc reads as symbols.
                    guard case .external(.emacsTable(_, _, _, let reason, _, _, let partial?)) = step, reason.hasPrefix("Lisp") else { continue }
                    cases.append(EmacsOracle.Case(text: emacsText, point: EmacsOracle.point(caret, in: emacsText), form: form))
                    let new = partial.edits.reduce(text) { $1.apply(to: $0) }
                    ours.append((new, partial.selection?.first?.lowerBound ?? caret))
                }
            }
        }
        #expect(cases.count >= 8)
        #expect(cases.filter { ["(org-table-next-field)", "(org-table-previous-field)", "(org-table-next-row)"].contains($0.form) }.count == 3)
        for (i, (theirs, mine)) in zip(try EmacsOracle.run(cases), ours).enumerated() {
            #expect(theirs.error.contains("leads outside table"), "\(theirs.error)")
            let text = theirs.text.replacingOccurrences(of: failing, with: lisp)
            let point = EmacsOracle.offset(theirs.point, in: theirs.text)
            let shifted = point > (theirs.text as NSString).range(of: failing).location ? point + (text as NSString).length - (theirs.text as NSString).length : point
            #expect(mine.text == text && mine.caret == shifted, "\(cases[i].form) at \(cases[i].point)\nours:\n\(mine.text)@\(mine.caret)\nemacs:\n\(text)@\(shifted)")
        }
    }

    /// TAB, S-TAB and RET in a row marked `#`, and recalculations with point inside a field,
    /// when a formula fails: the fields written before it stay and point goes to the field's start.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func errorsKeepFieldsAndMovePointAsEmacs() throws {
        let marked = "|   | a | b | c |\n|---+---+---+---|\n| # | 1 |   |   |\n#+TBLFM: $3=$2*2::$4=@-9$2\n"
        let early = "| a | b |\n|---+---|\n| 1 |x|\n| 2 |y |\n#+TBLFM: $2=$1*2::@2$2=7::@3$2=8::@2$1=@-9$1\n"
        let fine = "|   | a | b |\n|---+---+---|\n| # | 1 |   |\n|   | 2 |   |\n#+TBLFM: $3=$2*2\n"
        func after(_ needle: String, in text: String) -> Int { NSMaxRange((text as NSString).range(of: needle)) }
        let runs: [(text: String, caret: Int, command: any OrgCommand, form: String)] = [
            (marked, after("| # | 1", in: marked), TableCommand(.nextField), "(org-table-next-field)"),
            (marked, after("| # | 1", in: marked), TableCommand(.previousField), "(org-table-previous-field)"),
            (marked, after("| # | 1", in: marked), TableCommand(.nextRow), "(org-table-next-row)"),
            (marked, after("| # | 1 |  ", in: marked), TableCommand(.nextField), "(org-table-next-field)"),
            (early, after("| 2", in: early), TableRecalculate(all: true), "(org-table-recalculate t)"),
            (early, after("| 2 |y", in: early), TableRecalculate(all: true), "(org-table-recalculate t)"),
            (early, after("| 1 |", in: early), TableRecalculate(all: false), "(org-table-recalculate nil)"),
            (fine, after("| # | 1", in: fine), TableCommand(.nextField), "(org-table-next-field)"),
            (fine, after("| # | 1", in: fine), TableCommand(.previousField), "(org-table-previous-field)"),
            (fine, after("| # | 1", in: fine), TableCommand(.nextRow), "(org-table-next-row)"),
        ]
        let cases = runs.map { EmacsOracle.Case(text: $0.text, point: EmacsOracle.point($0.caret, in: $0.text), form: $0.form) }
        for (i, theirs) in try EmacsOracle.run(cases).enumerated() {
            let mine = Self.recalculate(runs[i].command, runs[i].text, caret: runs[i].caret)
            let expected = (theirs.text, EmacsOracle.offset(theirs.point, in: theirs.text), theirs.error.isEmpty ? nil : theirs.error)
            #expect(mine.text == expected.0 && mine.caret == expected.1 && mine.failure == expected.2,
                    "\(runs[i].form) at \(runs[i].caret) in\n\(runs[i].text)\nours:\n\(mine.text)@\(mine.caret) \(mine.failure ?? "")\nemacs:\n\(theirs.text)@\(expected.1) \(theirs.error)")
        }
    }

    /// `runCommand`, with the message of an error that left fields written as the failure.
    static func recalculate(_ command: any OrgCommand, _ text: String, caret: Int) -> (text: String, caret: Int, failure: String?) {
        let result = runCommand(command, text, caret: caret)
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
        guard case .commit(let commit) = command.run(in: context), case .message(let message) = commit.effects.last else { return result }
        return (result.text, result.caret, message)
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
