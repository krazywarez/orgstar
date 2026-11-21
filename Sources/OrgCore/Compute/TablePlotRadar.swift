import Foundation

/// `type:radar` (`org--plot/radar`, Org 9.8.7): each row is an axis with its own scale, each
/// column after the first a series.
extension TablePlot {
    public struct Radar: Sendable, Equatable {
        public struct Axis: Sendable, Equatable {
            public var label: String
            public var fields: [String]
            public var values: [Double]
            public var low: Double
            public var high: Double
            /// `low` and `high` as `format "%s"` prints them.
            var lowText: String
            var highText: String
        }
        public var axes: [Axis]
        /// The header's names after the first, one per series.
        public var series: [String]
        /// The web's rings; 0 draws none.
        public var ticks: Int
        /// With both `ymin` and `ymax`, every axis is labelled with the first axis's values.
        public var sharedTicks: Bool
    }

    /// A number as `string-to-number` reads it, and whether it's an integer.
    static func lispNumber(_ s: String) -> (value: Double, integer: Bool) {
        let trimmed = s.drop { $0 == " " || $0 == "\t" }
        guard let m = trimmed.firstMatch(of: /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?/) else { return (0, true) }
        let text = String(m.0)
        return (Double(text) ?? 0, text.firstMatch(of: /\.[0-9]|[eE]/) == nil)
    }

    static func printed(_ n: (value: Double, integer: Bool)) -> String {
        n.integer && abs(n.value) < 0x1p63 ? String(Int(n.value)) : Elisp.floatText(n.value)
    }

    /// An integer field as Emacs prints what `string-to-number` reads from it, bignums included.
    static func integerText(_ field: String) -> String {
        let trimmed = field.drop { $0 == " " || $0 == "\t" }
        guard let m = trimmed.firstMatch(of: /^([-+]?)0*([0-9]+)/) else { return "0" }
        let digits = String(m.2)
        return (m.1 == "-" && digits != "0" ? "-" : "") + digits
    }

    /// `org--plot/values-stats`.
    static func stats(_ nums: [(value: Double, integer: Bool)], hardMin: Double? = nil, hardMax: Double? = nil)
        -> (factor: Double, niceMin: (value: Double, integer: Bool), niceMax: (value: Double, integer: Bool)) {
        let low = hardMin ?? nums.map(\.value).min()!, high = hardMax ?? nums.map(\.value).max()!
        let range = high - low
        guard range != 0 else { return (1, nums[0], nums[0]) }
        let order = (1 - log10(range)).rounded(.up)
        let factor = pow(10, order)
        return (factor, ((low * factor).rounded(.down) / factor, false), ((high * factor).rounded(.up) / factor, false))
    }

    /// `org--plot/sensible-tick-num`, or nil where Emacs signals an error or never returns.
    static func sensibleTicks(_ rows: [[String]], hardMin: Double?, hardMax: Double?) -> Int? {
        var decompositions: [[(Int, Double)]] = []
        for row in rows {
            let s = stats(row.dropFirst().map(lispNumber), hardMin: hardMin, hardMax: hardMax)
            let raw = (s.factor * (s.niceMax.value - s.niceMin.value)).rounded(.toNearestOrEven)
            // A ymin above a row's values or a ymax below them: `ceiling` of NaN signals overflow-error.
            guard raw.isFinite, raw >= 0, raw < 0x1p63 else { return nil }
            var value = Int(raw)
            if value % 10 == 0 { value /= 10 }
            // `org--plot/prime-factors` loops forever on 0.
            guard value > 0 else { return nil }
            var factors: [Int] = [], i = 1
            while value != 1 {
                i += 1
                if value % i == 0 { factors.insert(i, at: 0); value /= i; i -= 1 }
            }
            // `org--plot/item-frequencies`, keys in `seq-group-by`'s order.
            var groups: [(Int, Int)] = []
            for f in factors.reversed() {
                if let at = groups.firstIndex(where: { $0.0 == f }) { groups[at].1 += 1 } else { groups.insert((f, 1), at: 0) }
            }
            decompositions.append(groups.map { ($0.0, Double($0.1) / Double(factors.count)) })
        }
        // `org--plot/merge-alists` needs two lists.
        func merge(_ lists: ArraySlice<[(Int, Double)]>) -> [(Int, Double)] {
            let a1 = lists.first!
            let a2 = lists.count > 2 ? merge(lists.dropFirst()) : lists[lists.startIndex + 1]
            // `cl-union` with :test: the longer list, the shorter's new keys pushed on its front.
            var (keys, other) = (a1.map(\.0), a2.map(\.0))
            if !keys.isEmpty, !other.isEmpty {
                if keys.count < other.count { swap(&keys, &other) }
                for k in other where !keys.contains(k) { keys.insert(k, at: 0) }
            } else if keys.isEmpty {
                keys = other
            }
            func lookup(_ k: Int, _ list: [(Int, Double)]) -> Double { list.first { $0.0 == k }?.1 ?? 0 }
            return keys.map { ($0, lookup($0, a1) + lookup($0, a2)) }
        }
        guard decompositions.count >= 2 else { return nil }
        let weighted = merge(decompositions[...]).enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }.map(\.element)
        // `org--plot/nice-frequency-pick`.
        var pick: [Int]
        switch weighted.count {
        case 0: return nil
        case 1: pick = [weighted[0].0]
        case 2: pick = 3 <= weighted[0].1 / weighted[1].1 ? [weighted[0].0, weighted[0].0] : [weighted[0].0, weighted[1].0]
        default:
            let total = weighted.map(\.1).reduce(0, +)
            let n = weighted.map { ($0.0, $0.1 / total) }
            pick = [n[0].0]
            let r12 = n[0].1 / n[1].1, r23 = n[1].1 / n[2].1, r13 = r12 * r23
            if r12 > 4 { pick.insert(n[0].0, at: 0) }
            if r12 < Double(n[1].0), pick.reduce(1, *) * n[1].0 < 30 { pick.insert(n[1].0, at: 0) }
            if r13 < Double(n[2].0), pick.reduce(1, *) * n[2].0 < 30 { pick.insert(n[2].0, at: 0) }
        }
        return pick.reduce(1, *)
    }

    /// The radar plot's axes, series and ticks, as `org--plot/radar` works them out.
    public static func radar(_ plot: Plot) throws -> Radar {
        let rows = plot.rows.compactMap { $0 }
        guard !rows.isEmpty, rows.allSatisfy({ $0.count > 1 }) else {
            throw Failure(description: "A radar plot needs a name and a value in each row")
        }
        func number(_ key: String) throws -> Double? {
            guard let v = plot.options[key] else { return nil }
            guard case .number(let n) = v else { throw Failure(description: "\(key): must be a number") }
            return n
        }
        let ymin = try number("ymin"), ymax = try number("ymax")
        let ticks: Int
        if let given = try number("ticks") {
            // gnuplot can't draw fewer than none.
            guard given >= 0, given < 0x1p63 else { throw Failure(description: "ticks: is out of range") }
            ticks = Int(given)
        } else if let sensible = sensibleTicks(rows, hardMin: ymin, hardMax: ymax) {
            ticks = sensible
        } else {
            throw Failure(description: "Org can't choose this radar plot's ticks; give ticks:")
        }
        let axes = try rows.map { row -> Radar.Axis in
            let nums = row.dropFirst().map(lispNumber)
            let s = stats(nums)
            // Emacs scales every row, given ticks: or not; past a double, `ceiling` signals overflow-error.
            guard s.factor.isFinite, s.niceMin.value.isFinite, s.niceMax.value.isFinite else {
                throw Failure(description: "Org can't scale the radar row \"\(row[0])\"")
            }
            return Radar.Axis(label: row[0], fields: Array(row.dropFirst()), values: nums.map(\.value),
                              low: ymin ?? s.niceMin.value, high: ymax ?? s.niceMax.value,
                              lowText: plot.options["ymin"]?.description ?? (s.niceMin.integer ? integerText(row[1]) : printed(s.niceMin)),
                              highText: plot.options["ymax"]?.description ?? (s.niceMax.integer ? integerText(row[1]) : printed(s.niceMax)))
        }
        return Radar(axes: axes, series: Array((plot.options.labels ?? []).dropFirst()), ticks: ticks, sharedTicks: ymin != nil && ymax != nil)
    }

    /// The setup file `org--plot/radar` writes: the data and each axis's scale.
    public static func radarSetup(_ plot: Plot) throws -> String {
        let radar = try radar(plot)
        let axes = radar.axes + radar.axes.prefix(1)
        let data = "\"" + (plot.options.labels ?? []).joined(separator: "\" \"") + "\"\n"
            + axes.map { "\"\($0.label)\" " + $0.fields.joined(separator: " ") }.joined(separator: "\n")
        let settings = axes.map { "\"\($0.label)\" \($0.lowText) \($0.highText) \(radar.ticks == 0 ? 2 : radar.ticks)" }.joined(separator: "\n")
        return "# Data\n$Data <<HEREHAVESOMEDATA\n\(data)\nHEREHAVESOMEDATA\nHeaderLines = 1\n\n"
            + "# Settings for scale and offset adjustments\n# axis min max tics axisLabelXoff axisLabelYoff\n$Settings <<EOD\n\(settings)\nEOD\n"
    }

    /// `org--plot/radar-template` filled in.
    static func radarScript(_ radar: Radar, setupFile: String) -> String {
        let axis = radar.sharedTicks ? "1" : "$1"
        let ticks = radar.ticks == 0 ? "" : """
                '++' u (PosX($1,$2/TicCount)):(PosY($1,$2/TicCount)): \\
            \t(PosX($1+1,$2/TicCount)-PosX($1,$2/TicCount)):  \\
            \t(PosY($1+1,$2/TicCount)-PosY($1,$2/TicCount)) w vec as 2 not, \\
                '++' u (TicLabelPosX(\(axis),$2)):(TicLabelPosY(\(axis),$2)): \\
            \t(sprintf('%g',TicValue(\(axis),$2))) w labels font ',8' @fgat not
            """
        return """
            ### spider plot/chart with gnuplot
            # also known as: radar chart, web chart, star chart, cobweb chart,
            #                radar plot,  web plot,  star plot,  cobweb plot,  etc. ...
            set datafile separator ' '
            set size square
            unset tics
            set angles degree
            set key bmargin center horizontal
            unset border

            # Load data and setup
            load "\(setupFile)"

            # General settings
            DataColCount = words($Data[1])-1
            AxesCount = |$Data|-HeaderLines-1
            AngleOffset = 90
            Max = 1
            d=0.1*Max
            Direction = -1   # counterclockwise=1, clockwise = -1

            # Tic settings
            TicCount = \(radar.ticks == 0 ? 2 : radar.ticks)
            TicOffset = 0.1
            TicValue(axis,i) = real(i)*(word($Settings[axis],3)-word($Settings[axis],2)) \\
            \t  / word($Settings[axis],4)+word($Settings[axis],2)
            TicLabelPosX(axis,i) = PosX(axis,i/TicCount) + PosY(axis, TicOffset)
            TicLabelPosY(axis,i) = PosY(axis,i/TicCount) - PosX(axis, TicOffset)
            TicLen = 0.03
            TicdX(axis,i) = 0.5*TicLen*cos(alpha(axis)-90)
            TicdY(axis,i) = 0.5*TicLen*sin(alpha(axis)-90)

            # Label
            LabOffset = 0.10
            LabX(axis) = PosX(axis+1,Max+2*d) + PosY(axis, LabOffset)
            LabY(axis) = PosY($0+1,Max+2*d)

            # Functions
            alpha(axis) = (axis-1)*Direction*360.0/AxesCount+AngleOffset
            PosX(axis,R) = R*cos(alpha(axis))
            PosY(axis,R) = R*sin(alpha(axis))
            Scale(axis,value) = real(value-word($Settings[axis],2))/(word($Settings[axis],3)-word($Settings[axis],2))

            # Spider settings
            set style arrow 1 dt 1 lw 1.0 @fgal head filled size 0.06,25     # style for axes
            set style arrow 2 dt 2 lw 0.5 @fgal nohead   # style for weblines
            set style arrow 3 dt 1 lw 1 @fgal nohead     # style for axis tics
            set samples AxesCount
            set isosamples TicCount
            set urange[1:AxesCount]
            set vrange[1:TicCount]
            set style fill transparent solid 0.2

            set xrange[-Max-4*d:Max+4*d]
            set yrange[-Max-4*d:Max+4*d]
            plot \\
                '+' u (0):(0):(PosX($0,Max+d)):(PosY($0,Max+d)) w vec as 1 not, \\
                $Data u (LabX($0)): \\
            \t(LabY($0)):1 every ::HeaderLines w labels center enhanced @fgt not, \\
                for [i=1:DataColCount] $Data u (PosX($0+1,Scale($0+1,column(i+1)))): \\
            \t(PosY($0+1,Scale($0+1,column(i+1)))) every ::HeaderLines w filledcurves lt i title word($Data[1],i+1), \\
            \(ticks)
            #    '++' u (PosX($1,$2/TicCount)-TicdX($1,$2/TicCount)): \\
            #        (PosY($1,$2/TicCount)-TicdY($1,$2/TicCount)): \\
            #        (2*TicdX($1,$2/TicCount)):(2*TicdY($1,$2/TicCount)) \\
            #        w vec as 3 not, \\
            ### end of code

            """
    }
}
