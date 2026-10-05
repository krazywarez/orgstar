import Foundation
import Testing
@testable import OrgCore

/// Runs `calc-eval` with org's table modes over a list of expressions.
enum CalcOracle {
    static func run(_ cases: [(expression: String, format: String)]) throws -> [String] {
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
                            (let ((r (calc-eval (cons (car c) modes) nil)))
                              (if (stringp r) r (format "ERROR %S" r)))))
                        cases)))
          (with-temp-file (getenv "ORACLE_OUTPUT")
            (insert (json-encode (vconcat results)))))
        """#.write(to: script, atomically: true, encoding: .utf8)
        _ = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["ORACLE_INPUT": input.path, "ORACLE_OUTPUT": output.path])
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
    ]

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
        let emacs = try CalcOracle.run(cases)
        #expect(emacs.count == cases.count)
        var skipped: [String] = []
        for (c, expected) in zip(cases, emacs) {
            var modes = Calc.Modes()
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
            #expect(ours == expected, "\(c.0) \(c.1)")
        }
        // Only what Calc itself can't show as a number.
        #expect(skipped == [], "\(skipped)")
    }

    @Test func unsupported() {
        for e in ["abc*2", "1/0", "vmean([])", "pi", "5%", "(-8)^(1/3)", "2 3"] {
            #expect(throws: Calc.Unsupported.self, "\(e)") { try Calc.evaluate(e) }
        }
    }
}
