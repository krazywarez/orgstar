import Charts
import Foundation
import OrgCore
import SwiftUI

/// A `#+PLOT` table drawn by Swift Charts, as gnuplot would draw it for org-plot: 2d as lines,
/// points, bars or impulses per `with:`, grid as a heat map, 3d as a surface (seen from above
/// with `map:t`), radar as a web. `still` draws 3d as a wireframe, which an image can hold.
/// The `set` commands in `TablePlot.settings` are followed; the rest are left out.
public struct PlotChart: View {
    let plot: TablePlot.Plot
    let still: Bool

    public init(_ plot: TablePlot.Plot, still: Bool = false) {
        self.plot = plot
        self.still = still
    }

    public var body: some View {
        let settings = TablePlot.settings(plot)
        VStack(spacing: 8) {
            if let title = settings.title { Text(title).font(.headline) }
            switch plot.options.type {
            case "grid": HeatMap(plot: plot, settings: settings)
            case "3d" where plot.options["map"]?.truthy == true: HeatMap(plot: plot, settings: settings)
            case "3d" where still: Wireframe(values: TablePlot.matrix(plot).values)
            case "3d": Surface(plot: plot)
            case "radar": if let radar = try? TablePlot.radar(plot) { Radar(radar: radar) }
            default: Lines(plot: plot, settings: settings)
            }
        }
        .padding()
    }

    /// The range given by `set` or the options, filling in from `values` what isn't given.
    static func domain(_ low: Double?, _ high: Double?, values: [Double]) -> ClosedRange<Double>? {
        guard low != nil || high != nil else { return nil }
        let lower = low ?? values.min() ?? 0
        let upper = high ?? values.max() ?? lower + 1
        return lower < upper ? lower...upper : nil
    }

    static func number(_ v: TablePlot.Value?) -> Double? { if case .number(let n)? = v { n } else { nil } }

    struct Lines: View {
        let plot: TablePlot.Plot
        let settings: TablePlot.Settings

        var body: some View {
            let s = settings
            // Log axes leave out what they can't place.
            let series = TablePlot.series(plot).map { series in
                var series = series
                series.points.removeAll { point in
                    if s.logY, !TablePlot.logRange.contains(point.y) { return true }
                    if s.logX, case .number(let n) = point.x, !TablePlot.logRange.contains(n) { return true }
                    return false
                }
                return series
            }
            let o = plot.options
            let ys = series.flatMap { $0.points.map(\.y) }
            let xs = series.flatMap { $0.points.compactMap { if case .number(let n) = $0.x { n } else { nil } } }
            let ticks = o["ticks"].flatMap { if case .number(let n) = $0 { Int(n) } else { nil } }
            let numericX = series.allSatisfy { $0.points.allSatisfy { if case .number = $0.x { true } else { false } } }
            let bars = ["boxes", "histograms", "hist", "impulses"].contains(o.with)
            let yGiven = (low: s.yrange?.low ?? PlotChart.number(o["ymin"]), high: s.yrange?.high ?? PlotChart.number(o["ymax"]))
            // A log axis has no 0, so bars stand on its foot, the range the SVG gives it.
            let logBars = bars && s.logY ? try? TablePlot.Axis(values: ys, given: yGiven.low == nil && yGiven.high == nil ? nil : .init(low: yGiven.low, high: yGiven.high), log: true, step: nil, zero: false) : nil
            let chart = Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    ForEach(Array(s.points.enumerated()), id: \.offset) { _, point in
                        mark(point.x, point.y, base: logBars?.low, series: s.label)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: s.xtics.map { AxisMarkValues.stride(by: $0) } ?? .automatic) { _ in
                    if s.grid { AxisGridLine() }
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(values: s.ytics.map { AxisMarkValues.stride(by: $0) } ?? .automatic(desiredCount: ticks ?? 5)) { _ in
                    if s.grid { AxisGridLine() }
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .chartXAxisLabel { if let label = s.xlabel { Text(label) } }
            .chartYAxisLabel { if let label = s.ylabel { Text(label) } }
            .key(s.key, shown: series.count > 1)
            // As gnuplot autoscales: to the data, from zero for bars.
            let yType: ScaleType? = s.logY ? .log : nil, xType: ScaleType? = s.logX ? .log : nil
            let y = Group {
                if let logBars {
                    chart.chartYScale(domain: logBars.low...logBars.high, type: yType)
                } else if let domain = PlotChart.domain(yGiven.low, yGiven.high, values: ys) {
                    chart.chartYScale(domain: domain, type: yType)
                } else {
                    chart.chartYScale(domain: .automatic(includesZero: bars && !s.logY), type: yType)
                }
            }
            if numericX, let domain = PlotChart.domain(s.xrange?.low ?? PlotChart.number(o["xmin"]), s.xrange?.high ?? PlotChart.number(o["xmax"]), values: xs) {
                y.chartXScale(domain: domain, type: xType)
            } else if numericX {
                y.chartXScale(domain: .automatic(includesZero: false), type: xType)
            } else {
                y
            }
        }

        @ChartContentBuilder
        func mark(_ x: TablePlot.Series.X, _ y: Double, base: Double?, series: String) -> some ChartContent {
            switch x {
            case .number(let n): marks(.value("x", n), y, base, series)
            case .date(let d): marks(.value("x", d), y, base, series)
            case .label(let l): marks(.value("x", l), y, base, series)
            }
        }

        @ChartContentBuilder
        func marks<X: Plottable>(_ x: PlottableValue<X>, _ y: Double, _ base: Double?, _ series: String) -> some ChartContent {
            switch plot.options.with {
            case "points", "dots":
                PointMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series))
            case "linespoints":
                LineMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series)).symbol(by: .value("Series", series))
            case "impulses":
                if let base {
                    BarMark(x: x, yStart: .value("y", base), yEnd: .value("y", y), width: 2).foregroundStyle(by: .value("Series", series))
                } else {
                    BarMark(x: x, y: .value("y", y), width: 2).foregroundStyle(by: .value("Series", series))
                }
            case "boxes", "histograms", "hist":
                if let base {
                    BarMark(x: x, yStart: .value("y", base), yEnd: .value("y", y)).foregroundStyle(by: .value("Series", series)).position(by: .value("Series", series))
                } else {
                    BarMark(x: x, y: .value("y", y)).foregroundStyle(by: .value("Series", series)).position(by: .value("Series", series))
                }
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
        let settings: TablePlot.Settings

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
            .chartXAxisLabel { if let label = settings.xlabel { Text(label) } }
            .chartYAxisLabel { if let label = settings.ylabel { Text(label) } }
            .key(settings.key, shown: true)
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

extension View {
    /// The legend as `set key` places it, else shown or not.
    func key(_ key: TablePlot.Settings.Key?, shown: Bool) -> some View {
        var position = AnnotationPosition.automatic
        if case .at(let vertical, let horizontal) = key {
            switch (vertical, horizontal) {
            case ("top", "left"): position = .topLeading
            case ("top", "right"): position = .topTrailing
            case ("bottom", "left"): position = .bottomLeading
            case ("bottom", "right"): position = .bottomTrailing
            case ("top", _): position = .top
            case ("bottom", _): position = .bottom
            case (_, "left"): position = .leading
            case (_, "right"): position = .trailing
            default: break
            }
        }
        let visible = key.map { $0 != .off } ?? shown
        return chartLegend(visible ? .visible : .hidden).chartLegend(position: position)
    }
}

/// A radar plot as org-plot's gnuplot script draws it: an axis per row, clockwise from the
/// top, each scaled from its low to its high value; a web at each tick; each series filled.
struct Radar: View {
    let radar: TablePlot.Radar

    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let n = radar.axes.count
                guard n > 0 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // gnuplot's range is 1.4 times the axes' length each way.
                let unit = min(size.width, size.height) / 2 / 1.4
                func point(_ axis: Int, _ r: Double, offset: Double = 0) -> CGPoint {
                    let angle = (90 - Double(axis) * 360 / Double(n)) * .pi / 180
                    return CGPoint(x: center.x + (r * cos(angle) + offset * sin(angle)) * unit,
                                   y: center.y - (r * sin(angle) - offset * cos(angle)) * unit)
                }
                let count = radar.ticks == 0 ? 2 : radar.ticks
                if radar.ticks != 0 {
                    for i in 1...count {
                        let r = Double(i) / Double(count)
                        var web = Path()
                        web.move(to: point(0, r))
                        for axis in 1...n { web.addLine(to: point(axis % n, r)) }
                        context.stroke(web, with: .color(.secondary), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        for axis in 0..<n {
                            let scale = radar.axes[radar.sharedTicks ? 0 : axis]
                            let value = Double(i) * (scale.high - scale.low) / Double(count) + scale.low
                            context.draw(Text(String(format: "%g", value)).font(.system(size: 8)).foregroundStyle(.secondary), at: point(axis, r, offset: 0.1))
                        }
                    }
                }
                for axis in 0..<n {
                    var line = Path()
                    line.move(to: center)
                    line.addLine(to: point(axis, 1.1))
                    context.stroke(line, with: .color(.primary), lineWidth: 1)
                    context.draw(Text(radar.axes[axis].label), at: point(axis, 1.2))
                }
                for s in radar.series.indices {
                    var shape = Path()
                    for (axis, a) in radar.axes.enumerated() where s < a.values.count && a.high != a.low {
                        let p = point(axis, (a.values[s] - a.low) / (a.high - a.low))
                        if shape.isEmpty { shape.move(to: p) } else { shape.addLine(to: p) }
                    }
                    shape.closeSubpath()
                    context.fill(shape, with: .color(Radar.color(s).opacity(0.2)))
                    context.stroke(shape, with: .color(Radar.color(s)), lineWidth: 1.5)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            HStack(spacing: 16) {
                ForEach(Array(radar.series.enumerated()), id: \.offset) { s, name in
                    HStack(spacing: 4) {
                        Rectangle().fill(Radar.color(s).opacity(0.4)).frame(width: 16, height: 10)
                        Text(name).font(.caption)
                    }
                }
            }
        }
    }

    /// gnuplot's colour for series `i`.
    static func color(_ i: Int) -> Color {
        let v = Int(TablePlot.colors[i % TablePlot.colors.count].dropFirst(), radix: 16) ?? 0
        return Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
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

        public init(description: String) { self.description = description }
    }

    /// `file:` relative to the Org file's folder.
    public static func file(_ plot: TablePlot.Plot, directory: URL?) -> URL? {
        guard let name = plot.options.file, !name.isEmpty else { return nil }
        let expanded = OrgPaths.expandingTilde(name)
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : (directory ?? URL(fileURLWithPath: OrgPaths.home)).appendingPathComponent(expanded)
    }

    /// The options a chart drawn here leaves out, for the result message.
    public static func note(_ plot: TablePlot.Plot) -> String? {
        let unfollowed = TablePlot.settings(plot).unfollowed
        return unfollowed.isEmpty ? nil : "Not followed without gnuplot: " + unfollowed.joined(separator: ", ")
    }

    /// Refuses what the chart can't draw: a radar plot `TablePlot.radar` refuses, which
    /// `TablePlot.plot` leaves to gnuplot when there's a `script:`, or one with more than 1000
    /// rings, and a log axis the SVG refuses, which Swift Charts traps on.
    public static func check(_ plot: TablePlot.Plot) throws {
        switch plot.options.type {
        case "radar":
            let radar: TablePlot.Radar
            do { radar = try TablePlot.radar(plot) } catch { throw Failure(description: "\(error)") }
            guard radar.ticks <= 1000 else { throw Failure(description: "Without gnuplot, ticks: takes 0 to 1000") }
        case "2d":
            let s = TablePlot.settings(plot)
            guard s.logX || s.logY else { return }
            do { _ = try TablePlot.svg(plot) } catch { throw Failure(description: "\(error)") }
        default:
            return
        }
    }

    /// The chart as gnuplot's default 640×480, as PNG, JPEG, PDF or SVG by the file's extension.
    public static func write(_ plot: TablePlot.Plot, to url: URL) throws {
        try check(plot)
        if url.pathExtension.lowercased() == "svg" {
            let svg: String
            do { svg = try TablePlot.svg(plot) } catch { throw Failure(description: "\(error)") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try svg.write(to: url, atomically: true, encoding: .utf8)
        }
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
            throw Failure(description: "Without gnuplot, plots are written as .png, .jpg, .pdf or .svg, not .\(url.pathExtension)")
        }
    }
}
