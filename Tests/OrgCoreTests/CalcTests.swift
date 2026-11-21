import Foundation
import Testing
@testable import OrgCore

/// Runs `calc-eval` with org's table modes over a list of expressions.
enum CalcOracle {
    static func run(_ cases: [(expression: String, format: String)], precision: Int = 12, zone: String = "UTC", symbolic: Bool = false) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-calc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.json")
        let output = folder.appendingPathComponent("output.json")
        let script = folder.appendingPathComponent("calc.el")
        try JSONSerialization.data(withJSONObject: cases.map { [$0.expression, $0.format] }).write(to: input)
        try #"""
        ;;; -*- lexical-binding: t -*-
        (require 'calc)
        (require 'org-table)
        (require 'json)
        (let* ((cases (with-temp-buffer
                        (insert-file-contents (getenv "ORACLE_INPUT"))
                        (json-parse-buffer :array-type 'list)))
               (results
                (mapcar (lambda (c)
                          (let* ((modes (copy-sequence org-calc-default-modes))
                                 (format (car (read-from-string (nth 1 c)))))
                            (setq modes (plist-put modes 'calc-float-format format))
                            (setq modes (plist-put modes 'calc-internal-prec (string-to-number (getenv "ORACLE_PREC"))))
                            (when (getenv "ORACLE_SYMBOLIC") (setq modes (plist-put modes 'calc-symbolic-mode t)))
                            (let ((r (condition-case e (calc-eval (cons (car c) modes) nil)
                                       (error (format "LISP ERROR %S" e)))))
                              (if (stringp r) r (format "ERROR %S" r)))))
                        cases)))
          (with-temp-file (getenv "ORACLE_OUTPUT")
            (insert (json-encode (vconcat results)))))
        """#.write(to: script, atomically: true, encoding: .utf8)
        _ = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["ORACLE_INPUT": input.path, "ORACLE_OUTPUT": output.path, "ORACLE_PREC": String(precision), "TZ": zone].merging(symbolic ? ["ORACLE_SYMBOLIC": "1"] : [:]) { $1 })
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: output))
    }
}

struct CalcTests {
    static let fixed = [
        "1+2", "7/2", "6/3", "1/3", "2/3", "(2)^(0.5)", "sqrt(2)", "sqrt(4)", "sqrt(16.0)", "1.5*2", "3.0", "(3.0)", "2^-1",
        "10/4", "1e5", "1e20*1", "123456789*1000", "0.1+0.2", "1/7", "100/7", "1000000/7", "1e10/7", "1e-5/7", "0.001/7",
        "0.0001/3", "(1.23456789012345)", "vsum([1,2,3.5])", "vmean([1,2])", "vmean([1,2,4])", "vmax([1,5,3])", "vsum([])",
        "vcount([1,2])", "vmedian([1,3,2,4])", "sin(30)", "cos(60)", "tan(45)", "exp(1)", "ln(10)", "log10(1000)", "log10(2)",
        "-3", "(-3)*2", "--3", "(+3)", "2*(0)", "2^0.5*2^0.5", "99999999.5*1", "123456785*0.1", "0.5*1e-10", "1.5e3",
        "12345678.9*1", "123456789.1*1", "1.25*1", "0.000123*1", "1e100*1e100", "round(2.5)", "floor(2.7)", "abs(-3)",
        "max(1,2)", "1.05*3", "2.675*1", "8/2*2", "8/2/2", "2*3/4", "-2^2", "2^3^2", "2^-2", "(-2)^2", "sin(0)", "sin(90)",
        "cos(0)", "cos(90)", "tan(0)", "exp(0)", "ln(1)", "log10(1)", "log10(100.0)", "sqrt(2.25)", "sqrt(0)", "arcsin(1)",
        "arctan(1)", "arccos(0.5)", "1.5^2", "1.1^10", "0.1^3", "2.5*4", "10/2.5", "1/3*3", "1.0/3", "vmedian([1,3])",
        "vmedian([1,2,3])", "vmedian([1.5,2])", "vmean([1.5,2.5])", "vsum([0.1,0.2,0.3])", "vmax([1,2.5])", "vmin([3,1.0])",
        "round(-2.5)", "round(2.4)", "round(1.23456,2)", "floor(-2.5)", "ceil(2.1)", "trunc(-2.7)", "abs(-1.5)", "max(1,2.5)",
        "min(4,2)", "1e3", "1.e3", "007", "(0.5)", "(.5)", "(5.)", "123456789012*10", "1.23456789012345678", "exp(10)",
        "exp(100)", "ln(0.5)", "sqrt(1e-10)", "2.0^2", "0^0", "1-1.0", "0.0", "-0.0", "1.0-1.0", "(-1.5)*(-2)",
        "(12)+(3.5)*(2)", "vsum([12,3.5,7])/3", "(1.5)/(0.5)", "(100)*(1.07)^(5)", "(19.99)*(3)", "(0.07)*(19.99)",
        "vmean([10,20,25])", "(5)-(7.25)", "(-0.001)*(1000)", "1/(3)", "(2)/(3)*(3)",
        // Dates, nan, comparisons and logic, and the rest of the functions tables use.
        "<2026-10-05 Mon>+3", "<2026-10-12 Mon>-<2026-10-05 Mon>", "<2026-10-05 Mon 10:00>-<2026-10-05 Mon 08:30>",
        "<2026-10-05 Mon 08:30>+0.5", "<2026-10-05 Mon 10:00>+1", "<2026-10-05 Mon 08:30>-<2026-10-04 Sun>", "(<2026-12-31 Thu>)+(1)",
        "<2026-03-01 Sun>-30", "1+<2026-10-05 Mon>", "<2026-10-05 Mon 23:59>-<2026-10-05 Mon 00:01>", "<2026-10-05 Mon 12:00>-0.25",
        "vmax([<2026-10-05 Mon>,<2026-10-07 Wed>])", "<2026-10-05 Mon> < <2026-10-06 Tue>", "nan", "nan+1", "vsum([1,nan])", "2*nan",
        "3<4", "3>4", "3<=3", "4>=5", "2==2", "2!=2", "1 && 0", "1 || 0", "!0", "!2", "if(3>4, 1, 2)", "if($1, 7, 8)".replacingOccurrences(of: "$1", with: "0"),
        "if(1.5, 2.5, 3)", "7%3", "-7%3", "7%-3", "7.5%2", "7\\2", "-7\\2", "7.5\\2", "mod(10,4)", "idiv(-9,4)", "fact(5)", "fact(0)",
        "vsdev([1,2,3,4])", "vvar([1,2,3])", "vpvar([1,2,3,4])", "vpsdev([2,4,4,4,5,5,7,9])", "vsdev([1.5,2.5,4])",
        "2+3<4*2", "1<2 && 3<4", "!(1<2)", "(1<2)+(2<3)",
        // Date forms and date functions.
        "<2026-10-05 Mon 00:00>", "<2026-10-05 Mon 00:00>+1", "<2026-10-05 Mon 12:00>+0.5", "<2026-10-05 Mon>+1e-9",
        "<2026-10-05 Mon>+0.1", "<2026-10-05 Mon>+1:2", "<2026-10-05 Mon 10:00>-1:3", "<2026-10-05 Mon 23:59:59>+0",
        "<2026-10-05 Mon>+<2026-10-06 Tue>", "1+<2026-10-05 Mon>+<2026-10-06 Tue>", "<2026-10-05 Mon>+1-<2026-10-01 Thu>",
        "-(<2026-10-05 Mon>)+<2026-10-01 Thu>", "0-<2026-10-05 Mon>", "-<2026-10-05 Mon>", "<2026-10-05 Mon>-nan",
        "<2026-10-05 Mon>-<2026-10-04 Sun 12:00>", "<2026-10-05 Mon> == <2026-10-05 Mon 00:00>",
        "vsum([<2026-10-05 Mon>,1.5])", "vsum([<2026-10-05 Mon 06:00>,0.1])", "vsum([<2026-10-05 Mon>,<2026-10-06 Tue>])",
        "vsum([<2026-10-05 Mon>,<2026-10-06 Tue>,<2026-10-10 Sat>])", "vmean([<2026-10-05 Mon>,<2026-10-06 Tue>])",
        "vmean([<2026-10-05 Mon 06:00>,<2026-10-05 Mon 12:00>])", "vmin([<2026-10-05 Mon>,<2026-10-07 Wed>])",
        "vmax([<2026-10-05 Mon>],[<2026-10-06 Tue>])", "vmin([<2026-10-05 Mon 00:00>,<2026-10-05 Mon>])",
        "vcount([<2026-10-05 Mon>])", "max(<2026-10-05 Mon>,<2026-10-06 Tue>)", "abs(<2026-10-05 Mon>)",
        "floor(<2026-10-05 Mon 10:30>)", "ceil(<2026-10-05 Mon 13:00>)", "trunc(<2026-10-05 Mon 13:00>)",
        "round(<2026-10-05 Mon 13:00>)", "round(<2026-10-05 Mon 11:00>)", "floor(<2026-10-05 Mon>)",
        "year(<2026-10-05 Mon>)", "month(<2026-10-05 Mon 10:30>)", "day(<2026-10-05 Mon>)", "weekday(<2026-10-05 Mon>)",
        "weekday(<2026-10-05 Mon 10:00>)", "weekday(-1)", "weekday(5)", "hour(<2026-10-05 Mon 10:30>)",
        "minute(<2026-10-05 Mon 10:30>)", "second(<2026-10-05 Mon 10:30:45>)", "hour(<2026-10-05 Mon>)",
        "yearday(<2026-10-05 Mon>)", "yearday(<2024-12-31 Tue>)", "year(5)", "year(<2026-10-05 Mon>)+1",
        "date(2026,10,5)", "date(2026,10,5,10,30,0)", "date(2026,1,1,10)", "date(2026,1,1,10,30)", "date(2026,1,1,25,0,0)",
        "date(2026,1,1,10,70,0)", "date(2026,2,31)", "date(2026.,2.,3.)", "date(2026,10,5,0,0,0)", "date(10,5)",
        "date(<2026-10-05 Mon>)", "date(<2026-10-05 Mon 06:00>)", "date(<2026-10-05 Mon>)+1", "date(739000)",
        "date(739000.5)", "date(739000.)", "date(1:2)", "date(5)", "date(36524)", "date(36890)", "date(365250)",
        "date(-5)", "date(-400)", "date(0)", "date(-366)", "date(-367)",
        "incmonth(<2026-01-31 Sat>,1)", "incmonth(<2026-10-05 Mon 10:30>,-14)", "incmonth(<2026-10-05 Mon>)",
        "incmonth(<2026-10-05 Mon>,2.)", "incmonth(5,1)", "incmonth(<2024-02-29 Thu>,12)", "incmonth(<2026-03-31 Tue>,-1)",
        "incmonth(<2026-12-15 Tue>,1)", "incmonth(<2026-01-15 Thu>,-1)", "incmonth(<2026-01-15 Thu>,-25)",
        "incmonth(400,-24)", "incmonth(-400,24)", "incyear(<2024-02-29 Thu>,1)", "incyear(<2024-02-29 Thu>,4)",
        "incyear(<2026-10-05 Mon>)", "incyear(<2026-10-05 Mon>,1.5)", "incyear(<2026-10-05 Mon 08:00>,-3)",
        "newmonth(<2026-10-15 Thu>)", "newmonth(<2026-02-15 Sun>,31)", "newmonth(<2026-02-15 Sun>,0)",
        "newmonth(<2026-02-15 Sun 10:00>,5)", "newmonth(<2024-02-15 Thu>,30)", "newmonth(<2026-10-15 Thu>,31)",
        "newyear(<2026-10-15 Thu>)", "newyear(<2026-10-15 Thu>,0)", "newyear(<2026-10-15 Thu>,-3)",
        "newyear(<2026-10-15 Thu 10:00>,40)", "newyear(<2024-10-15 Tue>,366)", "newyear(<2026-10-15 Thu>,366)",
        "newyear(<2026-10-15 Thu>,-12)", "newweek(<2026-10-15 Thu>)", "newweek(<2026-10-15 Thu>,3)",
        "newweek(<2026-10-15 Thu 10:00>)", "newweek(<2026-10-11 Sun>,1)", "newweek(<2026-10-17 Sat>,6)",
        "badd(<2026-10-09 Fri>,1)", "badd(<2026-10-10 Sat>,1)", "badd(<2026-10-10 Sat>,-1)", "badd(<2026-10-10 Sat>,0)",
        "badd(<2026-10-09 Fri 10:00>,2.5)", "badd(1,<2026-10-09 Fri>)", "badd(<2026-10-05 Mon>,10)", "badd(<2026-10-05 Mon>,-10)",
        "badd(<2026-10-11 Sun>,1)", "badd(<2026-10-11 Sun>,-1)", "badd(<2026-10-05 Mon>,0.5)", "badd(<2026-10-05 Mon>,-0.5)",
        "bsub(<2026-10-12 Mon>,1)", "bsub(<2026-10-12 Mon>,<2026-10-09 Fri>)", "bsub(<2026-10-11 Sun>,<2026-10-09 Fri>)",
        "bsub(<2026-10-12 Mon>,<2026-10-10 Sat>)", "bsub(<2026-10-05 Mon>,<2026-10-12 Mon>)",
        "bsub(<2026-10-12 Mon 12:00>,<2026-10-09 Fri 06:00>)", "bsub(<2026-12-31 Thu>,<2026-01-01 Thu>)",
        "bsub(<2026-10-10 Sat>,<2026-10-11 Sun>)", "bsub(<2026-10-11 Sun>,<2026-10-10 Sat>)",
        "julian(<2026-10-05 Mon>)", "julian(<2026-10-05 Mon 12:00>)", "julian(2461319)", "julian(2461319.5)", "julian(1:2)",
        "unixtime(<2026-10-05 Mon>)", "unixtime(<2026-10-05 Mon 10:30>)", "unixtime(1791158400)", "unixtime(1.5)",
        "unixtime(0)", "unixtime(-86400)", "unixtime(<1970-01-01 Thu>)",
        "abs(-<2026-10-05 Mon>)", "abs(date(-1,1,1))", "abs(-<2026-10-05 Mon 06:00>)", "abs(date(1,1,1))",
        "abs(date(1,1,1)-1.5)", "abs(date(1,1,1)-0.25)",
        "badd(date(2737,12,30),1)", "badd(date(1,1,3),-1)", "bsub(date(2737,12,31),date(1,1,1))",
        "<0070-01-01 Thu>", "<0001-01-01 Mon>", "<0010-01-01 Fri>", "<0000-01-01 Sat>", "<0039-12-31 Sat>", "<0040-01-01 Sun>",
        "<0099-01-01 Fri>", "<0050-06-15 Thu 10:30>", "<0100-01-01 Fri>", "year(<0010-01-01 Fri>)", "unixtime(<0001-01-01 Mon>)",
    ]

    /// Zones without daylight saving time, as `TZ` names them for Emacs and their offsets.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func datesInFixedZonesMatchCalc() throws {
        let cases = ["unixtime(<2026-10-05 Mon>)", "unixtime(<2026-10-05 Mon 10:30>)", "unixtime(1791158400)",
                     "julian(<2026-10-05 Mon 12:00>)", "julian(2461319.5)", "julian(<2026-10-05 Mon>)"].map { ($0, "(float 8)") }
        for zone in [("EST5", -5 * 3600), ("IST-5:30", 19800)] {
            let skipped = try Self.compare(cases, zone: zone)
            #expect(skipped == [], "\(zone.0) \(skipped)")
        }
    }

    /// Every function and operator given dates where numbers go: what isn't refused must
    /// match Calc.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func everythingOnDatesMatchesCalc() throws {
        let functions = ["vsum", "vprod", "vcount", "vmean", "vmax", "vmin", "vmedian", "if", "vvar", "vpvar", "vsdev", "vpsdev",
                         "mod", "idiv", "fact", "dfact", "max", "min", "abs", "floor", "ceil", "trunc", "round", "sqrt", "exp", "ln",
                         "log10", "sin", "cos", "tan", "arcsin", "arccos", "arctan", "eq", "neq", "lt", "gt", "leq", "geq", "land",
                         "lor", "lnot", "percent", "float", "pfloat", "sign", "rounde", "roundu", "frac", "fdiv", "gcd", "lcm",
                         "choose", "perm", "pow", "exp10", "nroot", "hypot", "log", "sinh", "cosh", "tanh", "arcsinh", "arccosh",
                         "arctanh", "arctan2", "deg", "rad", "vflat", "vgmean", "vhmean", "vcov", "vpcov", "vcorr", "agmean", "date",
                         "year", "month", "day", "hour", "minute", "second", "yearday", "weekday", "newweek", "newmonth", "newyear",
                         "incmonth", "incyear", "badd", "bsub", "julian", "unixtime"]
        let (d, t) = ("<2026-10-05 Mon>", "<2026-10-07 Wed 10:30>")
        var cases: [String] = []
        for f in functions {
            for args in [d, t, "\(d),2", "2,\(d)", "\(t),1.5", "\(d),\(t)", "\(t),\(d)", "[\(d),\(t)]", "[\(d),2]", "[\(t)],[\(d)]", "1,\(d),2"] {
                cases.append("\(f)(\(args))")
            }
        }
        for op in ["+", "-", "*", "/", "%", "\\", "^", "==", "!=", "<", ">", "<=", ">=", "&&", "||"] {
            cases += ["\(d)\(op)2", "2\(op)\(d)", "\(d)\(op)\(t)", "\(t)\(op)0.5", "\(t)\(op)\(d)", "\(d)\(op)nan"]
        }
        cases += ["-\(t)", "!\(d)", "\(d)%", "\(d)!", "\(d) 2", "2 \(d)"]
        let skipped = try Self.compare(cases.map { ($0, "(float 8)") })
        #expect(skipped.count < cases.count)
    }

    @Test func now() throws {
        var modes = Calc.Modes()
        modes.timeZone = TimeZone(secondsFromGMT: 3600)!
        modes.now = Date(timeIntervalSince1970: 1_791_196_245)
        #expect(try Calc.evaluate("now()", modes: modes) == "<2026-10-05 Mon 11:30>")
        #expect(try Calc.evaluate("second(now())", modes: modes) == "45")
        #expect(try Calc.evaluate("date(10,6)-newyear(now())", modes: modes) == "278")
        modes.now = Date(timeIntervalSince1970: 1_791_158_400 - 3600)
        #expect(try Calc.evaluate("now()", modes: modes) == "<2026-10-05 Mon 00:00>")
    }

    /// Constants, functions and syntax that only some tables use.
    static let functions = [
        // Grammar: juxtaposition, percent, factorials, fractions and radix integers.
        "2 3", "2 (3)", "(2)(3)", "2 3 4", "2 3+4", "2*3 4", "-2 3", "2 -3", "2 (3) + 1", "2 .5", "1.5 2", "2 nan", "6/2 3",
        "5%", "50%*20", "5%+1", "5%3", "5% 3", "(5)%", "12.5%", "1:4%", "100%", "-5%", "2^50%", "5%-1", "5% (2)",
        "5!", "5!+1", "-5!", "0!", "(3)!", "2^3!", "3!!", "6!!", "0!!", "1!!", "5.!", "20.!", "3! 2", "5! == 120", "5!=120",
        "1:3", "2:4", "4:2", "-1:3", "1:2:3", "1:0:3", "0:5", "1:3+1", "1:3*0.5", "1:3*3", "2:3^2", "(1:3)",
        "16#FF", "16#ff", "16#FF+1", "2#101", "8#17", "36#Z", "36#zz", "016#10", "10#99",
        // Comparisons and logic as functions; `&&` and `||` give an argument.
        "eq(2,2)", "eq(2,2.0)", "neq(1,2)", "lt(1,2)", "gt(1,2)", "leq(2,2)", "geq(1,2)", "lt(1:3,0.5)",
        "land(2,3)", "land(0,3)", "lor(0,2.5)", "lor(3,0)", "lnot(0)", "lnot(2.5)", "2 && 3", "0 || 2.5", "1.5 && 0.",
        "0. || 0", "if(1:2, 1, 2)",
        // Statistics.
        "vsum([1,2],[3,4])", "vsum(1,2,3)", "vsum([1,2],3)", "vsum()", "vsum([[1,2],[3]])", "vmax([1,2],[5,3])",
        "vmax(1,7,3)", "vmin([1,2],[0,3])", "vmean([1,2],[3])", "vmean(1,2)", "vprod([1,2],[3])", "vcount([1,2],3)",
        "vcount()", "vmedian([1,2],[5])", "vvar([1,2],[3])", "vsdev(1,2,3)", "vpsdev([1,2],[3,4])", "vmax(5)",
        "vmean(5)", "vsum(vflat([1,[2,3]],4))", "vcount(vflat(1,2,3))", "vgmean([1,2,4])", "vgmean([2,8])",
        "vgmean([1,2,3])", "vgmean([1.5,2.5])", "vgmean([1:2,2])", "vgmean([0,2])", "vgmean([5])", "vgmean([2,3,4,5])",
        "vgmean([1,2,3,4,5,6,7,8,9,10,11,12])", "vgmean([1.5,2,2.5,3,3.5])", "vgmean([16,1,1,1])", "vgmean([1:8,1,1])",
        "vhmean([1,2,4])", "vhmean([1,2])", "vhmean([1.5,2.5])", "vhmean([3])", "vhmean(1,2,3)",
        "vcov([1,2,3],[1,2,4])", "vpcov([1,2,3],[1,2,4])", "vcorr([1,2,3],[1,2,4])", "vcorr([1,2,3],[3,2,1])",
        "vcov([1.5,2.5,4],[2,3.5,1])", "vpcov([5],[7])", "vcorr([1,2,3,4],[2,4,5,9])", "vcov([1:2,1,2],[1,2,3])",
        "agmean(1,2)", "agmean(1,4)", "agmean(2,2)", "agmean(1.5,2)", "agmean(0,3)", "agmean(-1,4)", "agmean(24,6)",
        // Rounding and fractions.
        "rounde(2.5)", "rounde(3.5)", "rounde(-2.5)", "rounde(-3.5)", "rounde(2.6)", "rounde(7)", "rounde(5:2)",
        "rounde(7:2)", "rounde(2.45,1)", "rounde(2.55,1)", "rounde(1234,-2)", "rounde(1250,-2)", "rounde(1:8,2)",
        "roundu(2.5)", "roundu(-2.5)", "roundu(-2.4)", "roundu(2.45,1)", "roundu(-2.45,1)", "roundu(-5:2)", "roundu(3.)",
        "fdiv(7,2)", "fdiv(6,3)", "fdiv(1:2,3)", "fdiv(3,1:2)", "fdiv(2:3,4:5)", "fdiv(7.,2)", "fdiv(-7,2)",
        "frac(2.75)", "frac(-2.75)", "frac(7)", "frac(7:2)", "frac(7.)", "frac(0.1)", "frac(0.333333333333)",
        "frac(3.14159265359)", "frac(1.5e-3)", "frac(0.142857142857)", "frac(1.5e-11)",
        "sign(-3)", "sign(0)", "sign(2.5)", "sign(-1:3)", "sign(0.)",
        "gcd(12,18)", "gcd(-12,18)", "gcd(0,5)", "gcd(12.,18)", "gcd(1:2,1:3)", "gcd(2:3,4)", "gcd(-1:2,3:4)", "gcd(0,0)",
        "lcm(4,6)", "lcm(-4,6)", "lcm(0,6)", "lcm(1:2,1:3)", "lcm(3,4)",
        "choose(5,2)", "choose(5,0)", "choose(5,6)", "choose(-5,2)", "choose(-5,3)", "choose(-3,-5)", "choose(-5,-3)",
        "choose(5,-1)", "choose(52,5)", "choose(60,30)", "perm(5,2)", "perm(5,0)", "perm(5,5)", "perm(20,10)",
        // Powers, roots and logarithms.
        "pow(2,10)", "pow(2,0.5)", "pow(2,-1)", "8^(1:3)", "pow(8,1:3)", "4^(3:2)", "pow(4,3:2)", "27^(2:3)", "8^(-1:3)",
        "2^(1:3)", "2^(1:4)", "16^(3:4)", "2^(2:7)", "2^(1:11)", "1.5^(1:3)", "2^1.5", "2^2.5", "2^0.25", "2^-0.5", "2^2.",
        "3^2.", "10^2.", "10.^3", "10.^-2.", "0^2", "0^2.", "0.^0", "1:4^(1:2)", "(1:8)^(2:3)", "2^1.1", "0.5^0.75", "exp10(2)", "exp10(-2)", "exp10(0)", "exp10(15)",
        "nroot(8,3)", "nroot(27,3)", "nroot(10,3)", "nroot(16,4)", "nroot(2.5,2)", "nroot(1:8,3)", "nroot(-8,1)",
        "nroot(2,4)", "nroot(2,5)", "nroot(100,7)", "nroot(1000,12)", "nroot(3.5,11)", "nroot(2:3,3)", "nroot(0,3)",
        "nroot(1,5)", "nroot(1024,10)", "nroot(7,6)", "nroot(1e10,9)",
        "hypot(3,4)", "hypot(1,1)", "hypot(1.5,2)", "hypot(-3,4)", "hypot(0,-2.5)", "hypot(1:3,1:4)", "hypot(5,12)",
        "log(8,2)", "log(100,10)", "log(10,2)", "log(2.5,1.5)", "log(1,2)", "log(9,3)", "log(1:8,2)", "log(2,8)",
        "log(8,1:2)", "log(1:4,1:2)", "log(1000,10.)", "log(1.,3)", "log(1,2.)", "log(27,1:3)", "log(10,3)", "log(5)",
        "log(0.5,2)", "log(81,9)", "log(3,81)", "log(1.25,10)", "log10(1.25)", "log10(5:4)", "log10(1:100)", "log10(0.001)",
        "log10(7.5e-8)", "log10(99)", "log10(2:3)",
        // Hyperbolic and angle functions.
        "sinh(1)", "sinh(0)", "sinh(-2.5)", "sinh(0.)", "sinh(1:2)", "cosh(1)", "cosh(0)", "cosh(-0.5)", "tanh(1)",
        "tanh(0)", "tanh(-3)", "tanh(0.25)", "arcsinh(1)", "arcsinh(0)", "arcsinh(-2.5)", "arcsinh(1:2)",
        "arccosh(2)", "arccosh(1)", "arccosh(1.)", "arccosh(10.5)", "arctanh(0.5)", "arctanh(0)", "arctanh(-0.25)",
        "arctanh(1:3)", "arctan2(1,1)", "arctan2(1,0)", "arctan2(0,-1)", "arctan2(-1,-1)", "arctan2(0,0)",
        "arctan2(1,2)", "arctan2(0,1)", "arctan2(-1,0)", "arctan2(3,-4)", "arctan2(-2.5,1)",
        "deg(1)", "deg(3.14159)", "deg(1:2)", "rad(180)", "rad(90)", "rad(1)", "rad(-45.5)",
        "float(7)", "float(7:2)", "float(2.5)", "pfloat(7)", "float(1:3)", "float(123456789012345)",
        "sqrt(2)", "sqrt(1e6)", "sqrt(10)", "sqrt(2:9)", "sqrt(0.5)", "sqrt(99999999)",
    ]

    /// Each case through Calc and through `Calc.evaluate`, expecting the same text; returns the
    /// cases `Calc.evaluate` doesn't support.
    static func compare(_ cases: [(String, String)], precision: Int = 12, zone: (name: String, offset: Int) = ("UTC", 0), symbolic: Bool = false) throws -> [String] {
        let emacs = try CalcOracle.run(cases, precision: precision, zone: zone.name, symbolic: symbolic)
        #expect(emacs.count == cases.count)
        var skipped: [String] = []
        for (c, expected) in zip(cases, emacs) {
            var modes = Calc.Modes()
            modes.precision = precision
            modes.symbolic = symbolic
            modes.timeZone = TimeZone(secondsFromGMT: zone.offset)!
            let f = c.1.dropFirst().dropLast().split(separator: " ")
            let n = Int(f[1])!
            switch f[0] {
            case "fix": modes.format = .fix(n)
            case "sci": modes.format = .sci(n)
            case "eng": modes.format = .eng(n)
            default: modes.format = .float(n)
            }
            let ours: String
            do { ours = try Calc.evaluate(c.0, modes: modes) } catch { ours = "unsupported: \(error)" }
            if ours.hasPrefix("unsupported") {
                skipped.append(c.0)
                continue
            }
            #expect(ours == expected, "\(c.0) \(c.1) p\(precision)")
        }
        return skipped
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesCalc() throws {
        var cases = Self.fixed.map { ($0, "(float 8)") }
        for format in ["(float 3)", "(fix 2)", "(fix 0)", "(sci 3)", "(eng 2)"] {
            for e in ["2/3", "3", "1.5", "1234.5678", "0.000123", "1e20*1", "-2/3", "1/7*100"] { cases.append((e, format)) }
        }
        // Generated: random operands and operators.
        var generator = SystemRandomNumberGenerator()
        let numbers = ["1", "2", "3", "7", "10", "0.5", "1.25", "3.14159", "100", "0.001", "12.5", "99", "0.3", "1e3", "2.5e-2"]
        let ops = ["+", "-", "*", "/"]
        for _ in 0..<300 {
            var e = numbers.randomElement(using: &generator)!
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                e = "(\(e))\(ops.randomElement(using: &generator)!)(\(numbers.randomElement(using: &generator)!))"
            }
            cases.append((e, "(float 8)"))
        }
        // Only what Calc itself can't show as a number.
        let skipped = try Self.compare(cases)
        #expect(skipped == [], "\(skipped)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func functionsMatchCalc() throws {
        var cases = Self.functions.map { ($0, "(float 12)") }
        let sample = ["vgmean([1,2,3])", "agmean(1,2)", "sinh(1)", "arctan2(1,2)", "frac(0.1)", "log(10,2)", "nroot(10,3)",
                      "vcorr([1,2,3],[1,2,4])", "5%", "1:3*3", "rounde(2.45,1)", "hypot(1,1)", "rad(1)", "16#FF/7"]
        for format in ["(float 8)", "(fix 2)", "(sci 3)", "(eng 2)"] {
            for e in sample { cases.append((e, format)) }
        }
        // Generated: functions of random integers, fractions and floats. Arguments outside a
        // function's domain are refused, so only what is computed is compared.
        var generator = SystemRandomNumberGenerator()
        let numbers = ["1", "2", "3", "7", "10", "0.5", "1.25", "3.14159", "100", "0.001", "12.5", "99", "1:3", "5:4", "2.5e-2"]
        let unary = ["sinh", "cosh", "tanh", "arcsinh", "rad", "deg", "frac", "sign", "rounde", "roundu", "float", "sqrt", "arctanh"]
        let binary = ["log", "hypot", "arctan2", "agmean", "nroot", "gcd", "lcm", "fdiv"]
        for _ in 0..<200 {
            let x = numbers.randomElement(using: &generator)!
            let y = numbers.randomElement(using: &generator)!
            cases.append(("\(unary.randomElement(using: &generator)!)(\(x))", "(float 12)"))
            cases.append(("\(binary.randomElement(using: &generator)!)(\(x),\(y))", "(float 12)"))
            cases.append(("vgmean([\(x),\(y),\(numbers.randomElement(using: &generator)!)])", "(float 12)"))
        }
        let skipped = Set(try Self.compare(cases)).intersection(Self.functions + sample)
        #expect(skipped == [], "\(skipped)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func precisionMatchesCalc() throws {
        var generator = SystemRandomNumberGenerator()
        let numbers = ["1", "2", "3", "7", "10", "0.5", "1.25", "3.14159", "100", "0.001", "12.5", "99", "0.3", "1e3", "2.5e-2",
                       "1.23456789012345678", "123456789.987654321"]
        let ops = ["+", "-", "*", "/"]
        for precision in [3, 6, 15, 18] {
            var cases = ["1/3", "2/3", "1/7", "1.23456789012345678", "round(2/3,2)", "rounde(2.45,1)", "frac(0.1)", "1:3+0.5",
                         "5%", "fact(18)", "(0.3/3.14159)-100", "123456+0.5"].map { ($0, "(float 0)") }
            // Two digits more must fit in 18.
            if precision <= 16 {
                cases += ["vsum([0.1,0.2,0.3])", "vmean([1,2,4])", "vsum([1e-13,1,-1])", "vsdev([1.5,2.25,3e-12])", "0.7^-3"].map { ($0, "(float 0)") }
            }
            // Above 12 digits Calc keeps fractions of a second, which isn't supported.
            if precision < 12 {
                cases += ["<2026-10-05 Mon 08:30>+1", "<2026-10-05 Mon>+0.5", "julian(<2026-10-05 Mon 12:00>)", "unixtime(<2026-10-05 Mon 10:30>)",
                          "badd(<2026-10-09 Fri 10:00>,2.5)", "date(2026,1,1,10,30,15)", "minute(<2026-10-05 Mon 10:30>)",
                          "vsum([<2026-10-05 Mon 06:00>,0.1])"].map { ($0, "(float 0)") }
            }
            cases += ["vmax([1000., 1001])", "vmin([1001, 1000.])", "vmax([1234567890120., 1234567890123])", "1.1^10",
                      "8^(1:3)", "1.5^3"].map { ($0, "(float 0)") }
            if precision <= 14 {
                cases += ["sqrt(2)", "sinh(1)", "log(10,2)", "nroot(10,3)", "vgmean([1,2,3])", "exp(1)", "sin(30)", "2^0.5",
                          "exp(1.58)", "ln(9.44)", "0.08^1.5", "0.11^1.5", "exp(8.44)", "pow(2.5,1:3)"].map { ($0, "(float 0)") }
                // exp, ln and powers round at two digits more first.
                for _ in 0..<150 {
                    let x = "\(Int.random(in: 1...999, using: &generator))e-2"
                    let y = ["1.5", "0.5", "2.5", "1:3", "0.25", "-1.5", "2.", "3.7", "1.1", "-0.75", "5:7", "1:12"].randomElement(using: &generator)!
                    cases += [("exp(\(x))", "(float 0)"), ("ln(\(x))", "(float 0)"), ("(\(x))^(\(y))", "(float 0)")]
                }
            }
            for _ in 0..<100 {
                var e = numbers.randomElement(using: &generator)!
                for _ in 0..<Int.random(in: 1...3, using: &generator) {
                    e = "(\(e))\(ops.randomElement(using: &generator)!)(\(numbers.randomElement(using: &generator)!))"
                }
                cases.append((e, "(float 0)"))
            }
            let skipped = try Self.compare(cases, precision: precision)
            #expect(skipped == [], "p\(precision) \(skipped)")
        }
    }

    /// Formulas Calc leaves unevaluated: variables, text from fields, quotients by zero and
    /// infinities.
    static let symbolic = [
        "x", "pi", "e", "phi", "gamma", "2 pi", "pi*2", "pi+pi", "pi*pi", "e^2", "i*i", "abc*2", "x+5", "5 + x", "y + x",
        "(N/A)+5", "(N/A)*(2)", "(N/A)+(N/A)", "(TBD)-(3)", "(5 kg)+(3)", "(5 kg)+(3 kg)", "a b c", "x2", "2x", "2e", ".5x",
        "x+x", "x*2", "x+1+2", "x-x", "x/x", "x^2", "x*x", "(x)*(3)+(x)", "2 x + 3 y", "x - 5", "5 - x", "-x + 5", "-(x)",
        "(x+1)*2", "(x+1)/2", "2/x", "x*y", "y*x", "x*x*x", "x + 2.5", "x * 2.5", "x * 1:3", "x*0", "x*0.", "x+0.",
        "x - 0.5 x", "x / -2", "2^x", "x^0", "x^1", "x^-1", "x*(y+1)", "(y+1)*x", "x/(2 y)", "x/2 + x", "x/2 + x/3",
        "a-(b-c)", "-(a+b)", "-(a/2)", "(a b)^2", "(a/b)^2", "(-a)^3", "a^2^3", "(a^2)^3", "1/a^2", "a^2/a", "2^x*2^x",
        "x/1:2", "0/x", "0./x", "(2 x)^0.5", "(x/2)^0.5", "(2/x)^0.5", "(x^2)^0.5", "(-x)^2.", "(-x)^-3", "x^2*x^-3",
        "2^x*3^x", "x/y/z", "(x/y)/(z/w)", "2/(3/x)", "-x*y", "x+2y-x", "(x+1)-(x+1)", "x^0.", "1^x", "0^x", "0.^x", "0^-x",
        "1/0", "x/0", "0/0", "(5)/(0)", "(5.5)/(0)", "(0.)/(0)", "5/0.", "1:2/0", "x/0+1", "2*(1/0)", "(1/0)*2", "-(1/0)",
        "(1/0)+(1/0)", "(1/0)^2", "2^(1/0)", "x/0 - x/0", "2*x/0", "0^-1", "0^0.", "2^(0^-1)", "x+0^-1",
        "inf", "-inf", "uinf", "inf+1", "inf-inf", "inf*0", "1/inf", "inf*2", "x*inf", "inf*-2", "inf+x", "-inf-inf",
        "uinf+1", "inf/0", "uinf/0", "inf^-1", "x/inf", "2^inf", "0.5^inf", "(-2)^inf", "inf^0", "nan*x", "x+nan", "x/nan",
        "vsum([x,1,2])", "vmean([x,1])", "vmean([x,2,3])", "vsum([x,y,1])", "vprod([x,2,3])", "vmean([a,b])", "vcount([x,1])",
        "vsum([1/0, 2])", "vsum([5 kg,3])", "vsum([2 (3),1])",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func symbolicMatchesCalc() throws {
        var cases = Self.symbolic.map { ($0, "(float 8)") }
        for format in ["(fix 2)", "(sci 3)"] {
            for e in ["x/3 + 1/3", "vmean([x,2,3])", "2.5 x - 1:3"] { cases.append((e, format)) }
        }
        // Generated: a variable or two mixed with numbers. What Calc would decide from more
        // than this arithmetic is refused, so only what is computed is compared.
        var generator = SystemRandomNumberGenerator()
        let leaves = ["x", "x", "y", "1", "2", "3", "0", "0.5", "2.5", "1:3", "-1", "10", "inf", "a b"]
        let ops = ["+", "-", "*", "/", "^"]
        func expression(_ depth: Int) -> String {
            if depth == 0 || Int.random(in: 0..<3, using: &generator) == 0 { return leaves.randomElement(using: &generator)! }
            let op = ops.randomElement(using: &generator)!
            let right = op == "^" ? ["2", "3", "-1", "0.5", "x", "-2"].randomElement(using: &generator)! : expression(depth - 1)
            let e = "(\(expression(depth - 1)))\(op)(\(right))"
            return Int.random(in: 0..<6, using: &generator) == 0 ? "-\(e)" : e
        }
        for _ in 0..<2000 { cases.append((expression(4), "(float 8)")) }
        let skipped = try Self.compare(cases)
        #expect(Set(skipped).intersection(Self.symbolic) == [], "\(skipped)")
        #expect(skipped.count < cases.count / 4, "\(skipped.count) of \(cases.count) refused")
    }

    @Test func unsupported() throws {
        for e in ["sqrt(x)", "vmax([x,1])", "vsum(x,1)", "x<1", "if(x,1,2)", "x%2", "x_1", "x'", "Holidays+1", "café+1",
                  "x+<2026-10-05 Mon>", "[x,1]", "vcount([x -1])", "(1/0)+1", "vmean([])", "(-8)^(1/3)", "vvar([5])", "1<2<3",
                  "vmax([])", "vmin([])", "vrms([1,2])", "vmeane([1,2])", "vcov([1,2],[3])", "vcov([1],[2])",
                  "fdiv(7.5,2)", "fdiv(7,0)", "perm(5,6)", "log(8,1)", "log(0,2)", "log(-8,2)", "arctanh(1)", "arccosh(0.5)",
                  "nroot(-8,3)", "vgmean([-1,2])", "vhmean([0,1])", "gcd(1.5,3)", "gcd(12,18,4)", "5%%3", "1:0", "1:2:3:4",
                  "16#1.8", "16#FG", "2##11", "2.5!", "(-1)!", "(-3)!!", "choose(5.5,2)", "exp10(0.5)", "3!!!",
                  "eq(1,1,1)", "percent(nan)", "frac(0.5,0.1)", "frac(1e-20)",
                  "(2..5)", "[2..5]", "vmax([1..5])", "vcount([1..5])", "2...5", "(-8)^(1:3)", "(-2)^1.5", "ln(0)", "ln(-1)",
                  // Calc leaves these date expressions unevaluated.
                  "<2026-10-05 Mon>*2", "2*<2026-10-05 Mon>", "<2026-10-05 Mon>/2", "<2026-10-05 Mon>*0", "<2026-10-05 Mon> < 5",
                  "vmedian([<2026-10-05 Mon>,<2026-10-07 Wed>])", "vmean([<2026-10-05 Mon>,1])", "vmean([<2026-10-05 Mon>])",
                  "vmean([<2026-10-05 Mon>,<2026-10-06 Tue>,<2026-10-10 Sat>])", "vvar([<2026-10-05 Mon>,<2026-10-07 Wed>])",
                  "max(<2026-10-05 Mon>,1)", "if(<2026-10-05 Mon>,1,2)", "round(<2026-10-05 Mon 13:00>,1)", "date(2026,13,1)",
                  "date(2026,2,32)", "date(2026.5,1,1)", "date(2026,1,1,10,30,1.5)", "date([1,2])", "year([1,2])",
                  "newweek(<2026-10-15 Thu>,7)", "newyear(<2026-10-15 Thu>,400)", "incmonth(<2026-10-05 Mon>,1.5)",
                  "badd(<2026-10-09 Fri>,<2026-10-09 Fri>)", "bsub(5,1)", "now(5)", "julian(<2026-10-05 Mon>,5)", "1<<2026-10-05 Mon>",
                  // Outside the years 1 to 2737, Calc's holiday range.
                  "badd(date(2737,12,31),1)", "badd(<2026-10-05 Mon>,200000)", "bsub(date(2738,1,10),date(2026,1,1))",
                  "badd(date(-100,1,3),1)", "badd(date(1,1,3),-3)", "bsub(date(1,1,10),date(-1,12,20))", "badd(date(10000,1,3),1)",
                  // Calc leaves abs of day number 0 unevaluated.
                  "abs(date(1,1,1)-1)", "abs(date(-1,12,31))"] {
            #expect(throws: Calc.Unsupported.self, "\(e)") { try Calc.evaluate(e) }
        }
        var modes = Calc.Modes()
        // Calc's daylight saving rules aren't reproduced.
        modes.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(throws: Calc.Unsupported.self) { try Calc.evaluate("unixtime(<2026-10-05 Mon>)", modes: modes) }
        #expect(try Calc.evaluate("julian(<2026-10-05 Mon>)", modes: modes) == "2461319")
        modes.precision = 15
        #expect(throws: Calc.Unsupported.self) { try Calc.evaluate("sinh(1)", modes: modes) }
        #expect(throws: Calc.Unsupported.self) { try Calc.evaluate("<2026-10-05 Mon 10:00>+1", modes: modes) }
        modes.precision = 19
        #expect(throws: Calc.Unsupported.self) { try Calc.evaluate("1+1", modes: modes) }
        // `calc-eval` with `num`: a formula is an error, unless Calc explains it.
        #expect(throws: Calc.Failure("Number expected")) { try Calc.evaluate("x+1", numeric: true) }
        #expect(throws: Calc.Unsupported.self) { try Calc.evaluate("1/0", numeric: true) }
        var symbolic = Calc.Modes()
        symbolic.symbolic = true
        for e in ["sqrt(2)", "2^0.5", "ln(2)", "x^0.5"] {
            #expect(throws: Calc.Unsupported.self, "\(e)") { try Calc.evaluate(e, modes: symbolic) }
        }
    }

    /// `;S`: what is computed matches; functions and powers that may not be exact are refused.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func symbolicModeMatchesCalc() throws {
        let cases = (Self.fixed + Self.functions + Self.symbolic).map { ($0, "(float 8)") }
        let skipped = try Self.compare(cases, symbolic: true)
        #expect(Set(skipped).isDisjoint(with: ["1/3", "x+5", "1/0", "2 pi", "vmean([x,2,3])", "sin(30)", "x^2", "round(2.5)"]))
        #expect(skipped.count < cases.count / 3, "\(skipped.count) of \(cases.count) refused")
    }
}
