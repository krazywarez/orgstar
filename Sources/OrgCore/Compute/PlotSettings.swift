import Foundation

/// The gnuplot `set` commands a plot drawn without gnuplot follows, and the options it leaves out.
extension TablePlot {
    public struct Settings: Sendable, Equatable {
        public enum Key: Sendable, Equatable {
            case off
            /// `top`/`bottom` and `left`/`right`, either left to the chart.
            case at(vertical: String?, horizontal: String?)
        }

        public struct Range: Sendable, Equatable {
            public var low: Double?
            public var high: Double?
        }

        public var title: String?
        public var xlabel: String?
        public var ylabel: String?
        public var xrange: Range?
        public var yrange: Range?
        public var logX = false
        public var logY = false
        public var grid = false
        public var key: Key?
        public var xtics: Double?
        public var ytics: Double?
        /// The options not followed, as written in `#+PLOT`: `set:"…"`, `line:"…"`, `script:"…"`.
        public var unfollowed: [String] = []
    }

    /// The `set` commands each kind of chart can follow.
    static func followed(_ plot: Plot) -> Set<String> {
        switch plot.options.type {
        case "2d":
            let numericX = plot.options.ind <= 0 || !(plot.timeInd || plot.textInd || plot.options.with == "histograms")
            return numericX ? ["title", "xlabel", "ylabel", "xrange", "yrange", "logscale", "grid", "key", "xtics", "ytics"]
                : ["title", "xlabel", "ylabel", "yrange", "logscale y", "grid", "key", "ytics"]
        case "grid": return ["title", "xlabel", "ylabel", "key"]
        case "3d" where plot.options["map"]?.truthy == true: return ["title", "xlabel", "ylabel", "key"]
        // The radar script sets its own key, after these.
        default: return ["title"]
        }
    }

    /// The script's `title:`, `line:` and `set:` in the order gnuplot reads them, so a later
    /// one wins.
    public static func settings(_ plot: Plot) -> Settings {
        var s = Settings()
        let o = plot.options
        let follows = followed(plot)
        s.title = o.title
        var lines: [String] = [], sets: [String] = []
        for line in o.lines {
            if !(line.hasPrefix("set ") && apply(String(line.dropFirst(4)), to: &s, follows: follows)) { lines.append("line:\"\(line)\"") }
        }
        for set in o.sets where !apply(set, to: &s, follows: follows) { sets.append("set:\"\(set)\"") }
        // Each comes twice, as Org reads the options twice; list them once, as written.
        for u in lines.reversed() + sets.reversed() where !s.unfollowed.contains(u) { s.unfollowed.append(u) }
        if let script = o["script"] { s.unfollowed.append("script:\"\(script)\"") }
        return s
    }

    static func apply(_ command: String, to s: inout Settings, follows: Set<String>) -> Bool {
        let words = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = words.first else { return false }
        let rest = words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""
        func quoted() -> String? {
            guard let m = rest.firstMatch(of: /^(["'])(.*)\1$/) else { return nil }
            return String(m.2)
        }
        func range() -> Settings.Range? {
            guard let m = rest.firstMatch(of: /^\[\s*([^:\]]*?)\s*:\s*([^:\]]*?)\s*\]$/) else { return nil }
            func bound(_ t: Substring) -> Double?? { t.isEmpty || t == "*" ? .some(nil) : Double(t).map { .some($0) } }
            guard let low = bound(m.1), let high = bound(m.2) else { return nil }
            return Settings.Range(low: low, high: high)
        }
        func step() -> Double? { Double(rest).flatMap { $0 > 0 ? $0 : nil } }
        switch name {
        case "title", "xlabel", "ylabel":
            guard follows.contains(name), let text = quoted() else { return false }
            if name == "title" { s.title = text } else if name == "xlabel" { s.xlabel = text } else { s.ylabel = text }
        case "xrange", "yrange":
            guard follows.contains(name), let r = range() else { return false }
            if name == "xrange" { s.xrange = r } else { s.yrange = r }
        case "logscale":
            let axes = rest.isEmpty ? "xy" : rest
            guard ["x", "y", "xy", "yx"].contains(axes), follows.contains("logscale") || (axes == "y" && follows.contains("logscale y")) else { return false }
            if axes.contains("x") { s.logX = true }
            if axes.contains("y") { s.logY = true }
        case "grid":
            guard follows.contains(name), rest.isEmpty else { return false }
            s.grid = true
        case "key":
            let words = rest.split(separator: " ").map(String.init)
            guard follows.contains(name), words.allSatisfy(["off", "top", "bottom", "left", "right"].contains) else { return false }
            if words == ["off"] {
                s.key = .off
            } else {
                let vertical = words.filter { $0 == "top" || $0 == "bottom" }, horizontal = words.filter { $0 == "left" || $0 == "right" }
                guard !words.contains("off"), vertical.count <= 1, horizontal.count <= 1 else { return false }
                s.key = .at(vertical: vertical.first, horizontal: horizontal.first)
            }
        case "xtics", "ytics":
            guard follows.contains(name), let step = step() else { return false }
            if name == "xtics" { s.xtics = step } else { s.ytics = step }
        default:
            return false
        }
        return true
    }
}
