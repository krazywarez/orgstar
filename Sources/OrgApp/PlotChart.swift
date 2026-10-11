import Charts
import Foundation
import OrgCore
import SwiftUI

/// A `#+PLOT` table drawn by Swift Charts, as gnuplot would draw it for org-plot: 2d as lines,
/// points, bars or impulses per `with:`, grid as a heat map, 3d as a surface (seen from above
/// with `map:t`). `still` draws 3d as a wireframe, which an image can hold.
public struct PlotChart: View {
    let plot: TablePlot.Plot
    let still: Bool

    public init(_ plot: TablePlot.Plot, still: Bool = false) {
        self.plot = plot
        self.still = still
    }

    public var body: some View {
        VStack(spacing: 8) {
            if let title = plot.options.title { Text(title).font(.headline) }
            switch plot.options.type {
            case "grid": HeatMap(plot: plot)
            case "3d" where plot.options["map"]?.truthy == true: HeatMap(plot: plot)
            case "3d" where still: Wireframe(values: TablePlot.matrix(plot).values)
            case "3d": Surface(plot: plot)
            default: Lines(plot: plot)
            }
        }
        .padding()
    }

    /// The `ymin`/`ymax` (or `xmin`/`xmax`) range, filling in from `values` what isn't given.
    static func domain(_ low: TablePlot.Value?, _ high: TablePlot.Value?, values: [Double]) -> ClosedRange<Double>? {
        func number(_ v: TablePlot.Value?) -> Double? { if case .number(let n)? = v { n } else { nil } }
        guard number(low) != nil || number(high) != nil else { return nil }
        let lower = number(low) ?? values.min() ?? 0
        let upper = number(high) ?? values.max() ?? lower + 1
        return lower < upper ? lower...upper : nil
    }

    struct Lines: View {
        let plot: TablePlot.Plot

        var body: some View {
            let series = TablePlot.series(plot)
            let o = plot.options
            let ys = series.flatMap { $0.points.map(\.y) }
            let xs = series.flatMap { $0.points.compactMap { if case .number(let n) = $0.x { n } else { nil } } }
            let ticks = o["ticks"].flatMap { if case .number(let n) = $0 { Int(n) } else { nil } }
            let numericX = series.allSatisfy { $0.points.allSatisfy { if case .number = $0.x { true } else { false } } }
            let bars = ["boxes", "histograms", "hist", "impulses"].contains(o.with)
            let chart = Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    ForEach(Array(s.points.enumerated()), id: \.offset) { _, point in
                        mark(point.x, point.y, series: s.label)
                    }
                }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: ticks ?? 5)) }
            .chartLegend(series.count > 1 ? .visible : .hidden)
            // As gnuplot autoscales: to the data, from zero for bars.
            let y = Group {
                if let domain = PlotChart.domain(o["ymin"], o["ymax"], values: ys) {
                    chart.chartYScale(domain: domain)
                } else {
                    chart.chartYScale(domain: .automatic(includesZero: bars))
                }
            }
            if numericX, let domain = PlotChart.domain(o["xmin"], o["xmax"], values: xs) {
                y.chartXScale(domain: domain)
            } else if numericX {
                y.chartXScale(domain: .automatic(includesZero: false))
            } else {
                y
            }
        }

        @ChartContentBuilder
        func mark(_ x: TablePlot.Series.X, _ y: Double, series: String) -> some ChartContent {
            switch x {
            case .number(let n): marks(.value("x", n), y, series)
            case .date(let d): marks(.value("x", d), y, series)
            case .label(let l): marks(.value("x", l), y, series)
            }
        }

        @ChartContentBuilder
        func marks<X: Plottable>(_ x: PlottableValue<X>, _ y: Double, _ series: String) -> some ChartContent {
            switch plot.options.with {
            case "points", "dots":
                PointMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series))
            case "linespoints":
                LineMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series)).symbol(by: .value("Series", series))
            case "impulses":
                BarMark(x: x, y: .value("y", y), width: 2).foregroundStyle(by: .value("Series", series))
            case "boxes", "histograms", "hist":
                BarMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series)).position(by: .value("Series", series))
            case "steps":
                LineMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series)).interpolationMethod(.stepEnd)
            case "fsteps":
                LineMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series)).interpolationMethod(.stepStart)
            default:
                LineMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series))
            }
        }
    }

    struct HeatMap: View {
        let plot: TablePlot.Plot

        var body: some View {
            let (values, rowLabels) = TablePlot.matrix(plot)
            let columnLabels = columnNames(values.first?.count ?? 0)
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { r, row in
                    ForEach(Array(row.enumerated()), id: \.offset) { c, value in
                        RectangleMark(x: .value("Column", columnLabels[c]), y: .value("Row", rowName(r, rowLabels)),
                                      width: .ratio(1), height: .ratio(1))
                            .foregroundStyle(by: .value("Value", value))
                    }
                }
            }
            .chartForegroundStyleScale(range: Gradient(colors: [.indigo, .teal, .yellow]))
            // The first row at the bottom, as gnuplot draws it.
            .chartYScale(domain: values.indices.reversed().map { rowName($0, rowLabels) })
            .chartXScale(domain: columnLabels)
        }

        func rowName(_ r: Int, _ labels: [String]) -> String { r < labels.count ? labels[r] : "\(r + 1)" }

        /// The header's names for the plotted columns, or their numbers.
        func columnNames(_ count: Int) -> [String] {
            let ind = plot.options.ind - 1
            let header = plot.options.labels ?? []
            var deps = plot.options.deps.map { $0.map { $0 - 1 } } ?? Array(0..<plot.columns)
            deps.removeAll { $0 == ind }
            return (0..<count).map { i in i < deps.count && deps[i] < header.count ? header[deps[i]] : "\(i + 1)" }
        }
    }

    struct Surface: View {
        let plot: TablePlot.Plot

        var body: some View {
            let values = TablePlot.matrix(plot).values
            let rows = max(1, values.count), columns = max(1, values.first?.count ?? 1)
            Chart3D {
                SurfacePlot(x: "Column", y: "Value", z: "Row") { x, z in Self.interpolate(values, x, z) }
            }
            .chartXScale(domain: 1...Double(max(2, columns)))
            .chartZScale(domain: 1...Double(max(2, rows)))
        }

        /// The matrix's value at a fractional column and row, from its four neighbours.
        static func interpolate(_ m: [[Double]], _ x: Double, _ z: Double) -> Double {
            guard !m.isEmpty, !m[0].isEmpty else { return 0 }
            let c = min(max(x - 1, 0), Double(m[0].count - 1)), r = min(max(z - 1, 0), Double(m.count - 1))
            let c0 = Int(c), r0 = Int(r), c1 = min(c0 + 1, m[0].count - 1), r1 = min(r0 + 1, m.count - 1)
            func at(_ r: Int, _ c: Int) -> Double { c < m[r].count ? m[r][c] : 0 }
            let fc = c - Double(c0), fr = r - Double(r0)
            let top = at(r0, c0) * (1 - fc) + at(r0, c1) * fc
            let bottom = at(r1, c0) * (1 - fc) + at(r1, c1) * fc
            return top * (1 - fr) + bottom * fr
        }
    }
}

/// A matrix as gnuplot's `splot … matrix with lines` draws it: a wireframe seen from its
/// default view, rows and columns along the floor and values up.
struct Wireframe: View {
    let values: [[Double]]

    var body: some View {
        Canvas { context, size in
            let rows = values.count, columns = values.map(\.count).max() ?? 0
            guard rows > 0, columns > 0 else { return }
            let all = values.flatMap { $0 }
            let low = all.min() ?? 0, high = max(all.max() ?? 1, low + 1e-9)
            // gnuplot's view: 60° from the vertical, 30° around.
            let rotation = 30.0 * .pi / 180, tilt = 60.0 * .pi / 180
            func project(_ c: Double, _ r: Double, _ v: Double) -> CGPoint {
                let x = c / Double(max(1, columns - 1)) - 0.5, y = r / Double(max(1, rows - 1)) - 0.5, z = (v - low) / (high - low) - 0.5
                let px = x * cos(rotation) - y * sin(rotation)
                let depth = x * sin(rotation) + y * cos(rotation)
                let py = z * sin(tilt) - depth * cos(tilt)
                let scale = min(size.width, size.height) * 0.75
                return CGPoint(x: size.width / 2 + px * scale, y: size.height / 2 - py * scale)
            }
            var path = Path()
            for r in 0..<rows {
                for c in 0..<values[r].count {
                    let p = project(Double(c), Double(r), values[r][c])
                    if c == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }
            for c in 0..<columns {
                var started = false
                for r in 0..<rows where c < values[r].count {
                    let p = project(Double(c), Double(r), values[r][c])
                    if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
            var floor = Path()
            for (c, r) in [(0.0, 0.0), (Double(columns - 1), 0), (Double(columns - 1), Double(rows - 1)), (0, Double(rows - 1)), (0, 0)] {
                let p = project(c, r, low)
                if c == 0, r == 0, floor.isEmpty { floor.move(to: p) } else { floor.addLine(to: p) }
            }
            context.stroke(floor, with: .color(.secondary), lineWidth: 0.5)
        }
    }
}

/// Plots written to files and run through gnuplot.
@MainActor
public enum PlotOutput {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// `file:` relative to the Org file's folder.
    public static func file(_ plot: TablePlot.Plot, directory: URL?) -> URL? {
        guard let name = plot.options.file, !name.isEmpty else { return nil }
        let expanded = (name as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : (directory ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent(expanded)
    }

    /// The chart as gnuplot's default 640×480, as PNG, JPEG or PDF by the file's extension.
    public static func write(_ plot: TablePlot.Plot, to url: URL) throws {
        let renderer = ImageRenderer(content: PlotChart(plot, still: true).frame(width: 640, height: 480).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch url.pathExtension.lowercased() {
        case "pdf":
            var box = CGRect(x: 0, y: 0, width: 640, height: 480)
            guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw Failure(description: "Can't write \(url.lastPathComponent)")
            }
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
            }
        case "png", "jpg", "jpeg", "":
            guard let image = renderer.cgImage else { throw Failure(description: "The plot couldn't be drawn") }
            let type = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? "public.jpeg" : "public.png"
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
                throw Failure(description: "Can't write \(url.lastPathComponent)")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure(description: "Can't write \(url.lastPathComponent)") }
        default:
            throw Failure(description: "Without gnuplot, plots are written as .png, .jpg or .pdf, not .\(url.pathExtension)")
        }
    }

    #if os(macOS)
    /// gnuplot on the `PATH` Babel uses, when installed.
    public static var gnuplot: URL? {
        let path = BabelRunner.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("gnuplot") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `org-plot/gnuplot` through gnuplot: the data file and script org-plot writes, run with
    /// the output at `file:`, or a PNG for showing when there's none. Returns the image.
    public static func runGnuplot(_ plot: TablePlot.Plot, directory: URL?, gnuplot: URL) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-plot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dataFile = folder.appendingPathComponent("data.tsv")
        var plot = plot
        let output = file(plot, directory: directory) ?? folder.appendingPathComponent("plot.png")
        if plot.options.file == nil { plot.options.values["file"] = .string(output.path) }
        let (data, labels): (String, [(Int, String)]) = plot.options.type == "grid" ? TablePlot.gridData(plot) : (TablePlot.data(plot), [])
        try data.write(to: dataFile, atomically: true, encoding: .utf8)
        var script = TablePlot.script(plot, dataFile: dataFile.path, output: output.path, yLabels: labels)
        if let custom = plot.options["script"]?.description {
            let path = (custom as NSString).expandingTildeInPath
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : (directory ?? folder).appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure(description: "Can't read \(custom)") }
            script = TablePlot.script(plot, dataFile: dataFile.path, output: output.path, yLabels: labels, preface: true)
                + "\n" + text.replacingOccurrences(of: "$datafile", with: dataFile.path)
        }
        let scriptFile = folder.appendingPathComponent("plot.gp")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = gnuplot
        process.arguments = [scriptFile.path]
        process.currentDirectoryURL = directory
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard process.terminationStatus == 0 else {
            throw Failure(description: "gnuplot: " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
    #endif
}
