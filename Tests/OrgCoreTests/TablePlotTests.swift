import Foundation
import Testing
@testable import OrgCore

struct TablePlotTests {
    static let cases: [String] = [
        """
        #+PLOT: title:"Sales" ind:1 deps:(2 3) type:2d with:lines set:"grid" set:"xrange [0:10]" line:"set key left"
        | x | a | b | c |
        |---+---+---+---|
        | 1 | 2 | 3 | 4 |
        | 2 | 4 | 5 | 6 |
        """,
        """
        #+PLOT: with:points
        | 1 | 10 |
        | 2 | 20 |
        | 3 | 15 |
        """,
        """
        #+PLOT: ind:1 with:histograms title:"By name"
        | name  | count |
        |-------+-------|
        | apple | 3     |
        | "pear | 5     |
        """,
        """
        #+NAME: series
        #+PLOT: ind:1 deps:(2) with:linespoints
        | day              | value |
        |------------------+-------|
        | <2026-01-05 Mon> | 1.5   |
        | [2026-01-06 Tue 10:30] | 2   |
        """,
        """
        #+PLOT: type:3d map:t with:lines
        | 1 | 2 | 3 |
        | 4 | 5 | 6 |
        | 7 | 8 | 9 |
        """,
        """
        #+PLOT: type:grid ind:1 title:"Heat"
        | row | a | b |
        |-----+---+---|
        | r1  | 1 | 2 |
        | r2  | 3 | 4 |
        """,
        """
        #+PLOT: transpose:yes ind:1
        | x | 1 | 2 | 3 |
        |---+---+---+---|
        | y | 4 | 5 | 6 |
        """,
        """
        #+PLOT: labels:("first" "second") ind:1 file:"/tmp/orgstar-plot-test.png"
        #+PLOT: set:"title 'Upper'"
        | 1 | 2 |
        | 3 | 4 |
        """,
        """
        #+PLOT: type:radar title:"Skills"
        | skill  | Anna | Ben | Cleo |
        |--------+------+-----+------|
        | Swift  | 7    | 4   | 9    |
        | Lisp   | 3    | 8   | 5    |
        | SQL    | 6    | 6   | 2    |
        | Design | 2.5  | 9   | 4    |
        | Ops    | 8    | 1   | 7    |
        """,
        """
        #+PLOT: type:radar ymin:0 ymax:8
        | axis | a  | b  |
        |------+----+----|
        | x    | 1  | 9  |
        | y    | 4  | 4  |
        | z    | 8  | 3  |
        """,
        """
        #+PLOT: type:radar ticks:0
        | axis | a   | b   |
        |------+-----+-----|
        | p    | 120 | 340 |
        | q    | 0.5 | 0.2 |
        | r    | 15  | 90  |
        """,
        """
        #+PLOT: type:radar ticks:4 file:"/tmp/orgstar-radar.png"
        | axis | a  |
        |------+----|
        | one  | 3  |
        | two  | 12 |
        | three | 7 |
        """,
        """
        #+PLOT: type:radar
        | axis | a    | b    | c   | d   |
        |------+------+------+-----+-----|
        | u    | 1    | 2    | 3   | 4   |
        | v    | 10   | 40   | 25  | 33  |
        | w    | 0.01 | 0.05 | 0.2 | 0.3 |
        | x    | 100  | 700  | 350 | 250 |
        """,
    ]

    static func lisp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The script and the data file `org-plot/gnuplot` writes, gnuplot itself left out.
    static func emacs(_ text: String, data: String, setup: String = "") throws -> (script: String, data: String, setup: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-plot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("script.txt").path
        let form = """
        (progn
          (require 'org) (require 'org-plot)
          (defun gnuplot-mode ())
          (defun gnuplot-send-buffer-to-gnuplot ())
          (provide 'gnuplot)
          (let ((captured nil))
            (cl-letf (((symbol-function 'gnuplot-send-buffer-to-gnuplot) (lambda () (setq captured (buffer-string))))
                      ((symbol-function 'org-babel-temp-stable-file) (lambda (&rest _) \(lisp(data))))
                      ((symbol-function 'make-temp-file) (lambda (&rest _) \(lisp(setup)))))
              (with-temp-buffer
                (insert \(lisp(text)))
                (org-mode)
                (goto-char (point-min))
                (re-search-forward "^|")
                (org-plot/gnuplot)))
            (with-temp-file \(lisp(output)) (insert captured))))
        """
        let log = try EmacsOracle.run(["-Q", "--batch", "--eval", form], environment: ["TZ": "UTC"])
        guard let script = try? String(contentsOfFile: output, encoding: .utf8) else { throw EmacsOracle.EvaluateError(log: log) }
        return (script, (try? String(contentsOfFile: data, encoding: .utf8)) ?? "", (try? String(contentsOfFile: setup, encoding: .utf8)) ?? "")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil), arguments: cases.indices)
    func scriptsAndDataMatchEmacs(index: Int) throws {
        let text = Self.cases[index]
        let dataFile = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-plot-data-\(UUID().uuidString)").path
        let setupFile = dataFile + "-setup"
        defer { try? FileManager.default.removeItem(atPath: dataFile); try? FileManager.default.removeItem(atPath: setupFile) }
        let expected = try Self.emacs(text, data: dataFile, setup: setupFile)
        let offset = (text as NSString).range(of: "|").location
        let plot = try TablePlot.plot(text, at: offset)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let (data, labels): (String, [(Int, String)]) = plot.options.type == "grid" ? TablePlot.gridData(plot) : (TablePlot.data(plot, calendar: utc), [])
        let script = TablePlot.script(plot, dataFile: dataFile, output: plot.options.file, yLabels: labels, setupFile: setupFile)
        if plot.options.type == "radar" {
            let setup = try TablePlot.radarSetup(plot)
            #expect(setup == expected.setup, "case \(index)\nours:\n\(setup)\nemacs:\n\(expected.setup)")
        }
        #expect(script == expected.script, "case \(index)\nours:\n\(script)\nemacs:\n\(expected.script)")
        #expect(data == expected.data, "case \(index)\nours:\n\(data.debugDescription)\nemacs:\n\(expected.data.debugDescription)")
    }

    /// `org--plot/sensible-tick-num` over tables of varied ranges; "error" where Emacs signals one.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func radarTicksMatchEmacs() throws {
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        let scales = [1.0, 10, 100, 0.1, 1000, 3]
        var tables: [[[String]]] = []
        for _ in 0..<60 {
            let scale = scales[next(scales.count)]
            let rows = (0..<(2 + next(4))).map { r in
                // Distinct values, so no axis is flat (Emacs never returns on one).
                ["r\(r)"] + (0..<(2 + next(3))).map { c in TablePlot.printed((Double(next(50) * 10 + c) * scale / 10, scale >= 10)) }
            }
            tables.append(rows)
        }
        let forms = tables.map { t in
            "(condition-case nil (format \"%S\" (org--plot/sensible-tick-num '(" + t.map { "(" + $0.map { Self.lisp($0) }.joined(separator: " ") + ")" }.joined(separator: " ") + "))) (error \"error\"))"
        }
        let expected = try EmacsOracle.evaluate("", "(progn (require 'org-plot) (list " + forms.joined(separator: " ") + "))")
        #expect(Set(expected).count > 4 && expected.count == tables.count)
        for (t, want) in zip(tables, expected) {
            let ours = TablePlot.sensibleTicks(t, hardMin: nil, hardMax: nil).map(String.init) ?? "error"
            #expect(ours == want, "\(t)")
        }
        let rows = [["a", "1", "5"], ["b", "3", "4"]]
        let bounds: [(Double?, Double?, String)] = [(100, nil, "100 nil"), (nil, 0, "nil 0"), (0, 10, "0 10"), (-5, nil, "-5 nil")]
        let hard = try EmacsOracle.evaluate("", "(progn (require 'org-plot) (list " + bounds.map {
            "(condition-case nil (format \"%S\" (org--plot/sensible-tick-num '((\"a\" \"1\" \"5\") (\"b\" \"3\" \"4\")) \($0.2))) (error \"error\"))"
        }.joined(separator: " ") + "))")
        for (b, want) in zip(bounds, hard) {
            #expect((TablePlot.sensibleTicks(rows, hardMin: b.0, hardMax: b.1).map(String.init) ?? "error") == want, "\(b.2)")
        }
    }

    @Test func seriesAndMatrices() throws {
        let plot = try TablePlot.plot(Self.cases[0], at: 100)
        let series = TablePlot.series(plot)
        #expect(series.map(\.label) == ["a", "b"])
        #expect(series[0].points.map(\.y) == [2, 4] && series[0].points.first?.x == .number(1))
        let text = try TablePlot.plot(Self.cases[2], at: 60)
        #expect(text.textInd && TablePlot.series(text)[0].points.first?.x == .label("apple"))
        let dated = try TablePlot.plot(Self.cases[3], at: 80)
        #expect(dated.timeInd)
        if case .date = TablePlot.series(dated)[0].points[0].x {} else { Issue.record("not a date") }
        let grid = try TablePlot.plot(Self.cases[5], at: 60)
        let m = TablePlot.matrix(grid)
        #expect(m.values == [[1, 2], [3, 4]] && m.rowLabels == ["r1", "r2"])
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("#+PLOT: type:radar\n| 1 |\n", at: 0) }
        // Emacs never returns choosing ticks for an axis whose values are all the same.
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("#+PLOT: type:radar\n| a | 1 | 1 |\n| b | 2 | 3 |\n", at: 0) }
        // Emacs signals an error where the ranges leave nothing to pick ticks from.
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("#+PLOT: type:radar ymin:0 ymax:10\n| a | 1 | 9 |\n| b | 2 | 3 |\n", at: 0) }
        _ = try TablePlot.plot("#+PLOT: type:radar ticks:3\n| a | 1 | 1 |\n| b | 2 | 3 |\n", at: 0)
        // A ymin above a row's values, or a ymax below them: Emacs signals overflow-error.
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("#+PLOT: type:radar ymin:100\n| x | 1 | 5 |\n| y | 2 | 3 |\n", at: 0) }
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("#+PLOT: type:radar ymax:0\n| x | 1 | 5 |\n| y | 2 | 3 |\n", at: 0) }
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("#+PLOT: type:radar ticks:-1\n| x | 1 | 5 |\n| y | 2 | 3 |\n", at: 0) }
        // string-to-number reads the reader's infinities and NaNs; Emacs then signals overflow-error.
        #expect(TablePlot.lispNumber("-2.0e+INF").value == -.infinity && TablePlot.lispNumber("1e+NaN").value.isNaN)
        #expect(TablePlot.lispNumber("1.0e-INF").value == 1 && TablePlot.lispNumber("1.0e+inf").value == 1 && TablePlot.stringToNumber(".5e+INFx") == .infinity)
        for field in ["1.0e+INF", "1.0e+NaN"] {
            #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("#+PLOT: type:radar ticks:4\n| a | 1 | \(field) |\n| b | 2 | 5 |\n", at: 0) }
        }
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("#+PLOT: type:radar ticks:99999999999999999999\n| x | 1 | 5 |\n| y | 2 | 3 |\n", at: 0) }
        // gnuplot draws as many rings as it's given.
        _ = try TablePlot.plot("#+PLOT: type:radar ticks:2000\n| x | 1 | 5 |\n| y | 2 | 3 |\n", at: 0)
        // Emacs scales every row with or without ticks:, and signals overflow-error past a double.
        for row in ["| x | 1e400 | 5 |", "| x | 1e400 | 1e400 |", "| x | -1e400 | 5 |", "| x | 1e308 | -1e308 |"] {
            #expect(throws: TablePlot.Failure.self, "\(row)") { try TablePlot.plot("#+PLOT: type:radar ticks:3\n\(row)\n| y | 2 | 3 |\n", at: 0) }
            #expect(throws: TablePlot.Failure.self, "\(row)") { try TablePlot.plot("#+PLOT: type:radar ticks:3 ymin:0 ymax:10\n\(row)\n| y | 2 | 3 |\n", at: 0) }
        }
        // Emacs prints a bignum as it is.
        let big = try TablePlot.radarSetup(TablePlot.plot("#+PLOT: type:radar ticks:3\n| x | 100000000000000000000 | 100000000000000000000 |\n| y | -007 | -007 |\n", at: 0))
        #expect(big.contains("\"x\" 100000000000000000000 100000000000000000000 3\n\"y\" -7 -7 3\n"), "\(big)")
        let radar = try TablePlot.radar(TablePlot.plot(Self.cases[9], at: 40))
        #expect(radar.series == ["a", "b"] && radar.axes.map(\.label) == ["x", "y", "z"] && radar.sharedTicks)
        #expect(radar.axes[2].values == [8, 3] && radar.axes[0].low == 0 && radar.axes[0].high == 8)
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("no table\n", at: 0) }
    }
}
