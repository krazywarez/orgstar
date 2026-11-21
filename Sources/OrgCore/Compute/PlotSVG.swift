import Foundation

/// A 2d plot as an SVG file, 640×480 as gnuplot's default: lines, points or bars by `with:`,
/// with the `set` commands `settings` follows.
extension TablePlot {
    /// gnuplot's default line colours.
    public static let colors = ["#9400d3", "#009e73", "#56b4e9", "#e69f00", "#f0e442", "#0072b2", "#e51e10", "#000000"]

    /// 1, 2 or 5 times a power of ten, near a fifth of `span`.
    static func niceStep(_ span: Double) -> Double {
        let raw = span / 5, power = pow(10, (log10(raw)).rounded(.down)), f = raw / power
        return power * (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10)
    }

    /// An axis: its ends, widened to whole steps where they're not given, and its ticks.
    struct Axis {
        var low: Double
        var high: Double
        var log: Bool
        var ticks: [Double] = []

        init(values: [Double], given: Settings.Range?, log: Bool, step: Double?, zero: Bool) {
            var data = values.filter { !log || $0 > 0 }
            if zero, !log { data.append(0) }
            var low = given?.low ?? data.min() ?? 0, high = given?.high ?? data.max() ?? 1
            if low == high { (low, high) = log ? (low / 10, high * 10) : (low - 1, high + 1) }
            if low > high { swap(&low, &high) }
            self.log = log
            if log {
                if given?.low == nil { low = pow(10, log10(low).rounded(.down)) }
                if given?.high == nil { high = pow(10, log10(high).rounded(.up)) }
                ticks = Array(Int(log10(low).rounded(.up))...Int(log10(high).rounded(.down))).map { pow(10, Double($0)) }
            } else {
                let step = step ?? TablePlot.niceStep(high - low)
                if given?.low == nil { low = (low / step).rounded(.down) * step }
                if given?.high == nil { high = (high / step).rounded(.up) * step }
                var t = (low / step).rounded(.up) * step
                while t <= high + step * 1e-9, ticks.count < 200 { ticks.append(abs(t) < step * 1e-9 ? 0 : t); t += step }
            }
            self.low = low
            self.high = high
        }

        func fraction(_ v: Double) -> Double {
            log ? (log10(v) - log10(low)) / (log10(high) - log10(low)) : (v - low) / (high - low)
        }
    }

    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func number(_ v: Double) -> String { String(format: "%.2f", v) }

    public static func svg(_ plot: Plot, calendar: Calendar = .current) throws -> String {
        guard plot.options.type == "2d" else {
            throw Failure(description: "Without gnuplot, only 2d plots are written as .svg; use .png, .jpg or .pdf")
        }
        let s = settings(plot), with = plot.options.with
        let series = series(plot, calendar: calendar)
        let bars = ["boxes", "histograms", "hist"].contains(with)
        var categories: [String] = []
        for p in series.flatMap(\.points) { if case .label(let l) = p.x, !categories.contains(l) { categories.append(l) } }
        let dates = series.contains { $0.points.contains { if case .date = $0.x { true } else { false } } }
        func xValue(_ x: Series.X) -> Double {
            switch x {
            case .number(let n): n
            case .date(let d): d.timeIntervalSince1970
            case .label(let l): Double(categories.firstIndex(of: l)!)
            }
        }
        func bound(_ key: String) -> Double? { if case .number(let n)? = plot.options[key] { n } else { nil } }
        func given(_ set: Settings.Range?, _ low: String, _ high: String) -> Settings.Range? {
            let r = Settings.Range(low: set?.low ?? bound(low), high: set?.high ?? bound(high))
            return r.low == nil && r.high == nil ? nil : r
        }
        let ys = series.flatMap { $0.points.map(\.y) }
        let y = Axis(values: ys, given: given(s.yrange, "ymin", "ymax"), log: s.logY, step: s.ytics, zero: bars || with == "impulses")
        var x: Axis
        if !categories.isEmpty {
            x = Axis(values: [], given: .init(low: -0.5, high: Double(categories.count) - 0.5), log: false, step: 1, zero: false)
            x.ticks = categories.indices.map(Double.init)
        } else {
            x = Axis(values: series.flatMap { $0.points.map { xValue($0.x) } }, given: given(s.xrange, "xmin", "xmax"), log: s.logX, step: s.xtics, zero: false)
        }

        let width = 640.0, height = 480.0
        let left = 60.0 + (s.ylabel == nil ? 0 : 20), right = 620.0
        let top = 20.0 + (s.title == nil ? 0 : 20), bottom = height - 40 - (s.xlabel == nil ? 0 : 20)
        func px(_ v: Double) -> Double { left + x.fraction(v) * (right - left) }
        func py(_ v: Double) -> Double { bottom - y.fraction(v) * (bottom - top) }
        func xLabel(_ t: Double) -> String {
            if !categories.isEmpty { return categories[Int(t)] }
            if dates {
                let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
                return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
            return String(format: "%g", t)
        }

        var out = """
            <svg xmlns="http://www.w3.org/2000/svg" width="640" height="480" viewBox="0 0 640 480" font-family="Helvetica, Arial, sans-serif" font-size="12">
            <rect width="\(Int(width))" height="\(Int(height))" fill="white"/>
            <clipPath id="plot"><rect x="\(number(left))" y="\(number(top))" width="\(number(right - left))" height="\(number(bottom - top))"/></clipPath>

            """
        func add(_ line: String) { out += line + "\n" }
        for t in x.ticks where t >= x.low && t <= x.high {
            if s.grid { add("<line x1=\"\(number(px(t)))\" y1=\"\(number(top))\" x2=\"\(number(px(t)))\" y2=\"\(number(bottom))\" stroke=\"#a0a0a0\" stroke-dasharray=\"2,3\"/>") }
            add("<line x1=\"\(number(px(t)))\" y1=\"\(number(bottom))\" x2=\"\(number(px(t)))\" y2=\"\(number(bottom - 6))\" stroke=\"black\"/>")
            add("<text x=\"\(number(px(t)))\" y=\"\(number(bottom + 16))\" text-anchor=\"middle\">\(escaped(xLabel(t)))</text>")
        }
        for t in y.ticks where t >= y.low && t <= y.high {
            if s.grid { add("<line x1=\"\(number(left))\" y1=\"\(number(py(t)))\" x2=\"\(number(right))\" y2=\"\(number(py(t)))\" stroke=\"#a0a0a0\" stroke-dasharray=\"2,3\"/>") }
            add("<line x1=\"\(number(left))\" y1=\"\(number(py(t)))\" x2=\"\(number(left + 6))\" y2=\"\(number(py(t)))\" stroke=\"black\"/>")
            add("<text x=\"\(number(left - 6))\" y=\"\(number(py(t) + 4))\" text-anchor=\"end\">\(escaped(String(format: "%g", t)))</text>")
        }
        add("<rect x=\"\(number(left))\" y=\"\(number(top))\" width=\"\(number(right - left))\" height=\"\(number(bottom - top))\" fill=\"none\" stroke=\"black\"/>")
        if let title = s.title { add("<text x=\"320\" y=\"24\" text-anchor=\"middle\" font-size=\"14\">\(escaped(title))</text>") }
        if let label = s.xlabel { add("<text x=\"\(number((left + right) / 2))\" y=\"\(number(height - 12))\" text-anchor=\"middle\">\(escaped(label))</text>") }
        if let label = s.ylabel { add("<text transform=\"translate(16 \(number((top + bottom) / 2))) rotate(-90)\" text-anchor=\"middle\">\(escaped(label))</text>") }

        add("<g clip-path=\"url(#plot)\">")
        let xs = series.flatMap { $0.points.map { xValue($0.x) } }.sorted()
        let spacing = categories.isEmpty ? zip(xs, xs.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.min().map { abs(px(xs[0] + $0) - px(xs[0])) } ?? 40 : (px(1) - px(0))
        let base = py(y.log ? y.low : min(max(0, y.low), y.high))
        for (i, s) in series.enumerated() {
            let color = colors[i % colors.count]
            let points = s.points.filter { (!y.log || $0.y > 0) && (!x.log || xValue($0.x) > 0) }.map { (px(xValue($0.x)), py($0.y)) }
            guard !points.isEmpty else { continue }
            func polyline(_ p: [(Double, Double)]) {
                add("<polyline fill=\"none\" stroke=\"\(color)\" stroke-width=\"1.5\" points=\"" + p.map { "\(number($0.0)),\(number($0.1))" }.joined(separator: " ") + "\"/>")
            }
            switch with {
            case "points", "dots", "linespoints":
                if with == "linespoints" { polyline(points) }
                for (px, py) in points { add("<circle cx=\"\(number(px))\" cy=\"\(number(py))\" r=\"\(with == "dots" ? 1 : 3)\" fill=\"none\" stroke=\"\(color)\"/>") }
            case "impulses":
                for (px, py) in points { add("<line x1=\"\(number(px))\" y1=\"\(number(base))\" x2=\"\(number(px))\" y2=\"\(number(py))\" stroke=\"\(color)\" stroke-width=\"1.5\"/>") }
            case "boxes", "histograms", "hist":
                let group = spacing * 0.8, bar = group / Double(series.count)
                for (px, py) in points {
                    let x0 = px - group / 2 + bar * Double(i)
                    add("<rect x=\"\(number(x0))\" y=\"\(number(min(py, base)))\" width=\"\(number(bar))\" height=\"\(number(abs(base - py)))\" fill=\"\(color)\" fill-opacity=\"0.8\" stroke=\"\(color)\"/>")
                }
            case "steps", "fsteps":
                var stepped = [points[0]]
                for p in points.dropFirst() {
                    stepped.append(with == "steps" ? (p.0, stepped.last!.1) : (stepped.last!.0, p.1))
                    stepped.append(p)
                }
                polyline(stepped)
            default:
                polyline(points)
            }
        }
        add("</g>")

        var showKey = true, vertical = "top", horizontal = "right"
        switch s.key {
        case .off: showKey = false
        case .at(let v, let h): vertical = v ?? vertical; horizontal = h ?? horizontal
        case nil: break
        }
        if showKey {
            for (i, s) in series.enumerated() {
                let color = colors[i % colors.count]
                let row = vertical == "top" ? top + 16 + Double(i) * 16 : bottom - 10 - Double(series.count - 1 - i) * 16
                let sample = horizontal == "right" ? right - 50 : left + 10
                let text = horizontal == "right" ? "<text x=\"\(number(sample - 6))\" y=\"\(number(row + 4))\" text-anchor=\"end\">"
                    : "<text x=\"\(number(sample + 46))\" y=\"\(number(row + 4))\">"
                add(text + escaped(s.label) + "</text>")
                add("<line x1=\"\(number(sample))\" y1=\"\(number(row))\" x2=\"\(number(sample + 40))\" y2=\"\(number(row))\" stroke=\"\(color)\" stroke-width=\"\(bars ? 8 : 1.5)\"/>")
            }
        }
        return out + "</svg>\n"
    }
}
