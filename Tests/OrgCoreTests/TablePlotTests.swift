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
    ]

    static func lisp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The script and the data file `org-plot/gnuplot` writes, gnuplot itself left out.
    static func emacs(_ text: String, data: String) throws -> (script: String, data: String) {
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
                      ((symbol-function 'org-babel-temp-stable-file) (lambda (&rest _) \(lisp(data)))))
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
        return (script, (try? String(contentsOfFile: data, encoding: .utf8)) ?? "")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil), arguments: cases.indices)
    func scriptsAndDataMatchEmacs(index: Int) throws {
        let text = Self.cases[index]
        let dataFile = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-plot-data-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dataFile) }
        let expected = try Self.emacs(text, data: dataFile)
        let offset = (text as NSString).range(of: "|").location
        let plot = try TablePlot.plot(text, at: offset)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let (data, labels): (String, [(Int, String)]) = plot.options.type == "grid" ? TablePlot.gridData(plot) : (TablePlot.data(plot, calendar: utc), [])
        let script = TablePlot.script(plot, dataFile: dataFile, output: plot.options.file, yLabels: labels)
        #expect(script == expected.script, "case \(index)\nours:\n\(script)\nemacs:\n\(expected.script)")
        #expect(data == expected.data, "case \(index)\nours:\n\(data.debugDescription)\nemacs:\n\(expected.data.debugDescription)")
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
        #expect(throws: TablePlot.Failure.self) { try TablePlot.plot("no table\n", at: 0) }
    }
}
