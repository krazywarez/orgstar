import Charts
import Foundation
import OrgCore
@testable import OrgApp
import Testing

@MainActor
struct PlotChartTests {
    @Test func writesImagesAndPDF() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-plotchart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let texts = [
            "#+PLOT: title:\"Lines\" ind:1 file:\"a.png\"\n| x | a | b |\n|---+---+---|\n| 1 | 2 | 3 |\n| 2 | 4 | 1 |\n| 3 | 3 | 5 |\n",
            "#+PLOT: ind:1 with:histograms file:\"b.jpg\"\n| name | n |\n|------+---|\n| a | 3 |\n| b | 5 |\n",
            "#+PLOT: type:grid ind:1 file:\"c.pdf\"\n| r | a | b |\n|---+---+---|\n| x | 1 | 2 |\n| y | 3 | 4 |\n",
            "#+PLOT: type:3d file:\"d.png\"\n| 1 | 2 | 3 |\n| 2 | 4 | 6 |\n| 3 | 6 | 9 |\n",
            "#+PLOT: ind:1 with:linespoints file:\"h.png\" set:\"grid\" set:\"xlabel 'x'\" set:\"ylabel 'y'\" set:\"key left top\" set:\"logscale y\"\n| x | a | b |\n|---+---+---|\n| 1 | 2 | 30 |\n| 2 | 4 | 10 |\n| 3 | 3 | 500 |\n",
            "#+PLOT: ind:1 with:linespoints file:\"h.svg\" set:\"grid\" set:\"xlabel 'x'\" set:\"ylabel 'y'\" set:\"key left top\" set:\"logscale y\"\n| x | a | b |\n|---+---+---|\n| 1 | 2 | 30 |\n| 2 | 4 | 10 |\n| 3 | 3 | 500 |\n",
            "#+PLOT: type:radar file:\"r.png\"\n| skill | Anna | Ben |\n|---+---+---|\n| Swift | 7 | 4 |\n| Lisp | 3 | 8 |\n| SQL | 6 | 2 |\n| Ops | 8 | 1 |\n",
        ]
        for text in texts {
            let plot = try TablePlot.plot(text, at: (text as NSString).range(of: "|").location)
            let url = try #require(PlotOutput.file(plot, directory: folder))
            try PlotOutput.write(plot, to: url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            #expect(size > 1000, "\(url.lastPathComponent) is \(size) bytes")
            if let copy = ProcessInfo.processInfo.environment["ORGSTAR_PLOT_DUMP"] {
                try? FileManager.default.removeItem(atPath: copy + "/" + url.lastPathComponent)
                try FileManager.default.copyItem(atPath: url.path, toPath: copy + "/" + url.lastPathComponent)
            }
        }
        let svg = try TablePlot.plot("#+PLOT: file:\"e.svg\"\n| 1 | 2 |\n", at: 25)
        try PlotOutput.write(svg, to: PlotOutput.file(svg, directory: folder)!)
        #expect(try String(contentsOf: folder.appendingPathComponent("e.svg"), encoding: .utf8).hasPrefix("<svg"))
        let grid = try TablePlot.plot("#+PLOT: type:grid file:\"f.svg\"\n| 1 | 2 |\n| 3 | 4 |\n", at: 35)
        #expect(throws: PlotOutput.Failure.self) { try PlotOutput.write(grid, to: PlotOutput.file(grid, directory: folder)!) }
        #expect(throws: PlotOutput.Failure.self) { try PlotOutput.write(grid, to: folder.appendingPathComponent("g.eps")) }
    }

    static func plot(_ text: String) throws -> TablePlot.Plot {
        try TablePlot.plot(text, at: (text as NSString).range(of: "\n|").location + 1)
    }

    static let table = "| x | a | b |\n|---+---+---|\n| 1 | 2 | 30 |\n| 2 | 4 | 10 |\n| 3 | 3 | 50 |\n"

    @Test func followsTheSetSubset() throws {
        let sets = ["title 'Set'", "xlabel 'Day'", "ylabel 'Count'", "xrange [0:10]", "yrange [*:60]",
                    "grid", "key left top", "xtics 2", "ytics 0.5"]
        let plot = try Self.plot("#+PLOT: title:\"Given\" ind:1 " + sets.map { "set:\"\($0)\"" }.joined(separator: " ") + "\n" + Self.table)
        let s = TablePlot.settings(plot)
        #expect(s.title == "Set" && s.xlabel == "Day" && s.ylabel == "Count")
        #expect(s.xrange?.low == 0 && s.xrange?.high == 10 && s.yrange?.low == nil && s.yrange?.high == 60)
        #expect(!s.logY && !s.logX && s.grid && s.xtics == 2 && s.ytics == 0.5)
        #expect(s.key == .at(vertical: "top", horizontal: "left"))
        #expect(s.unfollowed.isEmpty && PlotOutput.note(plot) == nil)

        #expect(TablePlot.settings(try Self.plot("#+PLOT: set:\"logscale\"\n" + Self.table)).logX)
        #expect(TablePlot.settings(try Self.plot("#+PLOT: set:\"logscale y\"\n" + Self.table)).logY)
        #expect(TablePlot.settings(try Self.plot("#+PLOT: set:\"key off\"\n" + Self.table)).key == .off)
        #expect(TablePlot.settings(try Self.plot("#+PLOT: line:\"set key bottom\"\n" + Self.table)).key == .at(vertical: "bottom", horizontal: nil))
        // gnuplot reads title:, then line:, then set:, so a set: wins.
        #expect(TablePlot.settings(try Self.plot("#+PLOT: line:\"set title 'L'\" set:\"title 'S'\"\n" + Self.table)).title == "S")
    }

    @Test func reportsWhatItDoesntFollow() throws {
        let plot = try Self.plot("#+PLOT: ind:1 script:\"plot.gp\" line:\"plot sin(x)\" set:\"style fill solid\" set:\"xrange [a:b]\" set:\"grid\"\n" + Self.table)
        #expect(TablePlot.settings(plot).unfollowed == ["line:\"plot sin(x)\"", "set:\"style fill solid\"", "set:\"xrange [a:b]\"", "script:\"plot.gp\""])
        #expect(PlotOutput.note(plot) == "Not followed without gnuplot: line:\"plot sin(x)\", set:\"style fill solid\", set:\"xrange [a:b]\", script:\"plot.gp\"")
        // Text on the x axis has no range or steps; a heat map has no log scale; a radar plot sets its own key.
        let text = try Self.plot("#+PLOT: ind:1 set:\"xtics 2\" set:\"ytics 2\"\n| n | v |\n|---+---|\n| a | 1 |\n| b | 2 |\n")
        #expect(TablePlot.settings(text).unfollowed == ["set:\"xtics 2\""])
        let grid = try Self.plot("#+PLOT: type:grid set:\"logscale\" set:\"xlabel 'C'\"\n| 1 | 2 |\n| 3 | 4 |\n")
        #expect(TablePlot.settings(grid).unfollowed == ["set:\"logscale\""] && TablePlot.settings(grid).xlabel == "C")
        // gnuplot's key leaves a heat map's colour scale alone.
        let heat = try Self.plot("#+PLOT: type:grid set:\"key off\"\n| 1 | 2 |\n| 3 | 4 |\n")
        #expect(TablePlot.settings(heat).unfollowed == ["set:\"key off\""] && TablePlot.settings(heat).key == nil)
        let map = try Self.plot("#+PLOT: type:3d map:t set:\"key left\"\n| 1 | 2 |\n| 3 | 4 |\n")
        #expect(TablePlot.settings(map).unfollowed == ["set:\"key left\""])
        // On a log axis gnuplot's step is a factor, whichever comes first.
        let logTics = try Self.plot("#+PLOT: ind:1 set:\"ytics 2\" set:\"logscale y\" set:\"xtics 1\"\n" + Self.table)
        #expect(TablePlot.settings(logTics).unfollowed == ["set:\"ytics 2\""] && TablePlot.settings(logTics).ytics == nil && TablePlot.settings(logTics).xtics == 1)
        let logX = try Self.plot("#+PLOT: ind:1 line:\"set xtics 2\" set:\"logscale x\"\n" + Self.table)
        #expect(TablePlot.settings(logX).unfollowed == ["line:\"set xtics 2\""])
        // gnuplot reverses an axis whose range runs high to low.
        let reversed = try Self.plot("#+PLOT: ind:1 set:\"xrange [10:0]\" set:\"yrange [5:0]\" set:\"yrange [0:5]\"\n" + Self.table)
        #expect(TablePlot.settings(reversed).unfollowed == ["set:\"xrange [10:0]\"", "set:\"yrange [5:0]\""] && TablePlot.settings(reversed).xrange == nil)
        let radar = try Self.plot("#+PLOT: type:radar ticks:2 set:\"key off\" set:\"title 'R'\"\n| n | a |\n|---+---|\n| x | 1 |\n| y | 2 |\n| z | 3 |\n")
        #expect(TablePlot.settings(radar).unfollowed == ["set:\"key off\""] && TablePlot.settings(radar).title == "R")
    }

    @Test func drawsRadarPlots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-radar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let plot = try Self.plot("#+PLOT: type:radar title:\"Skills\"\n| skill | Anna | Ben |\n|---+---+---|\n| Swift | 7 | 4 |\n| Lisp | 3 | 8 |\n| SQL | 6 | 2 |\n| Ops | 8 | 1 |\n")
        for name in ["radar.png", "radar.pdf"] {
            try PlotOutput.write(plot, to: folder.appendingPathComponent(name))
            let size = (try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            #expect(size > 1000, "\(name) is \(size) bytes")
        }
        #expect(throws: PlotOutput.Failure.self) { try PlotOutput.write(plot, to: folder.appendingPathComponent("radar.svg")) }
        // With script:, TablePlot.plot leaves the radar to gnuplot; drawn here, it's refused.
        let scripted = try Self.plot("#+PLOT: type:radar script:\"r.gp\"\n| n | a | b |\n|---+---+---|\n| x | 1 | 1 |\n| y | 2 | 3 |\n")
        #expect(throws: PlotOutput.Failure.self) { try PlotOutput.check(scripted) }
        #expect(throws: PlotOutput.Failure.self) { try PlotOutput.write(scripted, to: folder.appendingPathComponent("scripted.png")) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("scripted.png").path))
        try PlotOutput.check(plot)
    }

    @Test func refusesLogRangesAndDrawsLogBars() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = "| 1 | 3 |\n| 2 | 4 |\n"
        for options in ["set:\"logscale y\" set:\"yrange [0:100]\"", "set:\"logscale x\" set:\"xrange [0:10]\"",
                        "set:\"logscale y\" set:\"yrange [-1:100]\"", "set:\"logscale y\" ymin:0", "set:\"logscale x\" xmin:-1"] {
            let plot = try Self.plot("#+PLOT: ind:1 \(options)\n" + data)
            #expect(throws: PlotOutput.Failure.self, "\(options)") { try PlotOutput.check(plot) }
            for name in ["o.png", "o.pdf"] {
                #expect(throws: PlotOutput.Failure.self, "\(options)") { try PlotOutput.write(plot, to: folder.appendingPathComponent(name)) }
            }
        }
        for options in ["with:boxes set:\"logscale y\"", "with:impulses set:\"logscale y\"", "with:histograms set:\"logscale y\"",
                        "with:boxes set:\"logscale y\" set:\"yrange [0.5:10]\"", "with:impulses set:\"logscale y\" set:\"yrange [2:10]\"", "with:boxes set:\"logscale xy\"", "with:lines set:\"logscale y\""] {
            let plot = try Self.plot("#+PLOT: ind:1 \(options)\n| 1 | 1 |\n| 2 | 5 |\n")
            for name in ["b.png", "b.pdf"] {
                let url = folder.appendingPathComponent(name)
                try PlotOutput.write(plot, to: url)
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                #expect(size > 1000, "\(options) \(name) is \(size) bytes")
            }
        }
    }

    @Test func skipsLogPointsPastADouble() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for axis in ["x", "y"] {
            for field in ["1e400", "3e-324", "1e-320", "1.5e308", "1.0e+INF"] {
                let row = axis == "x" ? "| \(field) | 5 |" : "| 2 | \(field) |"
                let plot = try Self.plot("#+PLOT: ind:1 set:\"logscale \(axis)\"\n| x | y |\n|---+---|\n| 1 | 10 |\n\(row)\n| 3 | 20 |\n")
                try PlotOutput.check(plot)
                let svg = try TablePlot.svg(plot)
                #expect(!svg.contains("inf") && !svg.contains("nan"), "\(axis) \(field)")
                try PlotOutput.write(plot, to: folder.appendingPathComponent("l.png"))
            }
        }
        for range in ["[1:1e400]", "[1e-320:10]"] {
            let plot = try Self.plot("#+PLOT: ind:1 set:\"logscale y\" set:\"yrange \(range)\"\n| 1 | 10 |\n| 2 | 20 |\n")
            #expect(throws: PlotOutput.Failure.self, "\(range)") { try PlotOutput.check(plot) }
        }
    }

    @Test func placesALoneKeyDirectionAsGnuplot() throws {
        func position(_ set: String) throws -> String {
            String(describing: PlotChart.keyPosition(TablePlot.settings(try Self.plot("#+PLOT: set:\"\(set)\"\n" + Self.table)).key))
        }
        #expect(try position("key top") == String(describing: AnnotationPosition.topTrailing))
        #expect(try position("key left") == String(describing: AnnotationPosition.topLeading))
        #expect(try position("key bottom") == String(describing: AnnotationPosition.bottomTrailing))
        #expect(try position("key right") == String(describing: AnnotationPosition.topTrailing))
        #expect(try position("key bottom left") == String(describing: AnnotationPosition.bottomLeading))
    }

    @Test func capsRadarRingsWithoutGnuplot() throws {
        let plot = try Self.plot("#+PLOT: type:radar ticks:2000\n| n | a | b |\n|---+---+---|\n| x | 1 | 5 |\n| y | 2 | 3 |\n")
        #expect(try TablePlot.radarSetup(plot).hasSuffix(" 2000\nEOD\n"))
        #expect(throws: PlotOutput.Failure.self) { try PlotOutput.check(plot) }
        try PlotOutput.check(Self.plot("#+PLOT: type:radar ticks:1000\n| n | a | b |\n|---+---+---|\n| x | 1 | 5 |\n| y | 2 | 3 |\n"))
    }

    @Test func writesSVG() throws {
        let lines = try TablePlot.svg(Self.plot("#+PLOT: ind:1 set:\"title 'T&C'\" set:\"xlabel 'Day'\" set:\"grid\"\n" + Self.table))
        #expect(lines.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"640\" height=\"480\""))
        #expect(lines.components(separatedBy: "<polyline").count - 1 == 2)
        #expect(lines.contains(">T&amp;C</text>") && lines.contains(">Day</text>") && lines.contains("stroke-dasharray"))
        #expect(lines.contains(">a</text>") && lines.contains(">b</text>"))
        let bars = try TablePlot.svg(Self.plot("#+PLOT: ind:1 with:histograms set:\"key off\"\n| n | v |\n|---+---|\n| a | 3 |\n| b | 5 |\n"))
        #expect(bars.components(separatedBy: "<rect x=").count - 1 == 2 + 2)
        #expect(bars.contains(">a</text>") && !bars.contains(">v</text>") && !bars.contains("stroke-dasharray"))
        let log = try TablePlot.svg(Self.plot("#+PLOT: ind:1 with:points set:\"logscale y\"\n| x | v |\n|---+---|\n| 1 | 5 |\n| 2 | 500 |\n| 3 | 0 |\n"))
        #expect(log.contains(">1</text>") && log.contains(">1000</text>") && log.components(separatedBy: "<circle").count - 1 == 2)
        // A log range with no power of ten in it is labelled at its ends.
        let narrow = try TablePlot.svg(Self.plot("#+PLOT: ind:1 set:\"logscale y\" set:\"yrange [2:5]\"\n| 1 | 3 |\n| 2 | 4 |\n"))
        #expect(narrow.contains(">2</text>") && narrow.contains(">5</text>"))
        #expect(throws: TablePlot.Failure.self) { try TablePlot.svg(Self.plot("#+PLOT: ind:1 set:\"logscale y\"\n| 1 | 0 |\n| 2 | -4 |\n")) }
        #expect(throws: TablePlot.Failure.self) { try TablePlot.svg(Self.plot("#+PLOT: ind:1 set:\"logscale y\" set:\"yrange [0:100]\"\n| 1 | 3 |\n| 2 | 4 |\n")) }
        #expect(throws: TablePlot.Failure.self) { try TablePlot.svg(Self.plot("#+PLOT: ind:1 set:\"logscale x\" set:\"xrange [*:10]\"\n| 0 | 3 |\n| -1 | 4 |\n")) }
        let ranged = try TablePlot.svg(Self.plot("#+PLOT: ind:1 set:\"xrange [0:10]\" set:\"ytics 25\"\n" + Self.table))
        #expect(ranged.contains(">10</text>") && ranged.contains(">25</text>") && ranged.contains(">50</text>"))
        #expect(throws: TablePlot.Failure.self) { try TablePlot.svg(Self.plot("#+PLOT: type:3d\n| 1 | 2 |\n| 3 | 4 |\n")) }
    }

    @Test func interpolatesTheMatrix() {
        let m: [[Double]] = [[1, 2], [3, 4]]
        #expect(PlotChart.Surface.interpolate(m, 1, 1) == 1)
        #expect(PlotChart.Surface.interpolate(m, 2, 2) == 4)
        #expect(PlotChart.Surface.interpolate(m, 1.5, 1.5) == 2.5)
    }
}
