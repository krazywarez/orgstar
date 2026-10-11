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
        #expect(throws: PlotOutput.Failure.self) { try PlotOutput.write(svg, to: PlotOutput.file(svg, directory: folder)!) }
    }

    @Test func interpolatesTheMatrix() {
        let m: [[Double]] = [[1, 2], [3, 4]]
        #expect(PlotChart.Surface.interpolate(m, 1, 1) == 1)
        #expect(PlotChart.Surface.interpolate(m, 2, 2) == 4)
        #expect(PlotChart.Surface.interpolate(m, 1.5, 1.5) == 2.5)
    }
}
