import Foundation

/// Diary sexps, `%%(…)` lines and `<%%(…)>` timestamps: `org-diary-sexp-entry` with the
/// calendar, diary-lib and org functions agenda files use. A sexp that uses anything else, or
/// signals an error, doesn't apply, as Emacs reports a bad sexp and moves on.
public enum DiarySexp {
    /// The entries `sexp` gives on `day` for a diary line whose text is `entry`, or nil where
    /// it doesn't apply.
    public static func entries(_ sexp: Sexp, entry: String, day: Int) -> [String]? {
        let lisp = interpreter(day: day, entry: entry)
        guard let result = try? lisp.eval(sexp), !Elisp.isNil(result) else { return nil }
        switch result {
        case .string(let s): return s.components(separatedBy: "; ")
        case .dotted(let items, .string(let s)) where items.count == 1: return [s]
        case .list(let items) where items.first?.string != nil: return items.map { Elisp.printed($0) }
        default: return [entry]
        }
    }

    /// Whether `sexp` applies on `day`, for diary timestamps.
    public static func matches(_ sexp: Sexp, day: Int) -> Bool {
        entries(sexp, entry: "", day: day) != nil
    }

    static func interpreter(day: Int, entry: String) -> Elisp {
        let lisp = Elisp()
        lisp.set("date", gregorian(day))
        lisp.set("entry", .string(entry))
        lisp.set("calendar-date-style", .symbol("american"))
        define(lisp)
        return lisp
    }

    /// `(MONTH DAY YEAR)`.
    static func gregorian(_ day: Int) -> Sexp {
        let date = Days.date(day)
        return .list([.integer(date.month), .integer(date.day), .integer(date.year)])
    }

    /// A number from Lisp used in date arithmetic, within what that arithmetic handles.
    static func bounded(_ v: Sexp) throws -> Int {
        let i = try Elisp.int(v)
        guard (-100_000_000...100_000_000).contains(i) else { throw Elisp.Unsupported(what: "date number \(i)") }
        return i
    }

    static func parts(_ date: Sexp) throws -> (month: Int, day: Int, year: Int) {
        let items = try Elisp.elements(date)
        guard items.count == 3 else { throw Elisp.Signal(message: "Bad date \(date.description)") }
        return (try bounded(items[0]), try bounded(items[1]), try bounded(items[2]))
    }

    static func absolute(_ date: Sexp) throws -> Int {
        let d = try parts(date)
        return Days.absolute(year: d.year, month: d.month, day: d.day)
    }

    static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    static func lastDay(month: Int, year: Int) throws -> Int {
        guard (1...12).contains(month) else { throw Elisp.Signal(message: "Args out of range: \(month)") }
        return month == 2 ? (isLeap(year) ? 29 : 28) : [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    /// `calendar-nth-named-absday`.
    static func nthNamedAbsday(_ n: Int, _ dayname: Int, _ month: Int, _ year: Int, _ day: Int?) throws -> Int {
        func onOrBefore(_ date: Int) -> Int { date - (date - dayname) % 7 }
        if n > 0 {
            return 7 * (n - 1) + onOrBefore(6 + Days.absolute(year: year, month: month, day: day ?? 1))
        }
        return 7 * (n + 1) + onOrBefore(Days.absolute(year: year, month: month, day: try day ?? lastDay(month: month, year: year)))
    }

    /// `diary-ordinal-suffix`.
    static func ordinalSuffix(_ n: Int) throws -> String {
        if [11, 12, 13].contains(n % 100) || 3 < n % 10 { return "th" }
        guard n % 10 >= 0 else { throw Elisp.Signal(message: "Args out of range") }
        return ["th", "st", "nd", "rd"][n % 10]
    }

    /// `diary-make-date`: arguments in `calendar-date-style` order, as `(MONTH DAY YEAR)`.
    static func makeDate(_ lisp: Elisp, _ a: Sexp, _ b: Sexp, _ c: Sexp) throws -> [Sexp] {
        switch try lisp.value("calendar-date-style") {
        case .symbol("iso"): [b, c, a]
        case .symbol("european"): [b, a, c]
        default: [a, b, c]
        }
    }

    /// Runs `body` with `calendar-date-style` bound to `iso`, as the `org-` wrappers do.
    static func iso(_ lisp: Elisp, _ body: () throws -> Sexp) rethrows -> Sexp {
        try lisp.binding(["calendar-date-style": .symbol("iso")], body)
    }

    static func optional(_ args: [Sexp], _ i: Int) -> Sexp { i < args.count ? args[i] : .nil }

    static func define(_ lisp: Elisp) {
        func date() throws -> Sexp { try lisp.value("date") }
        func entry() throws -> Sexp { try lisp.value("entry") }
        func arity(_ args: [Sexp], _ range: ClosedRange<Int>, _ name: String) throws {
            try Elisp.arity(args, range, name)
        }

        lisp.define("calendar-extract-month") { _, args in try arity(args, 1...1, "calendar-extract-month"); return .integer(try parts(args[0]).month) }
        lisp.define("calendar-extract-day") { _, args in try arity(args, 1...1, "calendar-extract-day"); return .integer(try parts(args[0]).day) }
        lisp.define("calendar-extract-year") { _, args in try arity(args, 1...1, "calendar-extract-year"); return .integer(try parts(args[0]).year) }
        lisp.define("calendar-absolute-from-gregorian") { _, args in
            try arity(args, 1...1, "calendar-absolute-from-gregorian")
            return .integer(try absolute(args[0]))
        }
        lisp.define("calendar-gregorian-from-absolute") { _, args in
            try arity(args, 1...1, "calendar-gregorian-from-absolute")
            return gregorian(try bounded(args[0]))
        }
        lisp.define("calendar-day-of-week") { _, args in
            try arity(args, 1...1, "calendar-day-of-week")
            return .integer(Days.weekday(try absolute(args[0])))
        }
        lisp.define("calendar-leap-year-p") { _, args in
            try arity(args, 1...1, "calendar-leap-year-p")
            return Elisp.bool(isLeap(try Elisp.int(args[0])))
        }
        lisp.define("calendar-last-day-of-month") { _, args in
            try arity(args, 2...2, "calendar-last-day-of-month")
            return .integer(try lastDay(month: try bounded(args[0]), year: try bounded(args[1])))
        }
        lisp.define("calendar-date-equal") { _, args in
            try arity(args, 2...2, "calendar-date-equal")
            let a = try parts(args[0])
            let b = try parts(args[1])
            return Elisp.bool(a == b)
        }
        lisp.define("calendar-day-number") { _, args in
            try arity(args, 1...1, "calendar-day-number")
            let d = try parts(args[0])
            return .integer(Days.absolute(year: d.year, month: d.month, day: d.day) - Days.absolute(year: d.year, month: 1, day: 0))
        }
        lisp.define("calendar-nth-named-absday") { _, args in
            try arity(args, 4...5, "calendar-nth-named-absday")
            let day = Elisp.isNil(optional(args, 4)) ? nil : try bounded(args[4])
            return .integer(try nthNamedAbsday(try bounded(args[0]), try bounded(args[1]), try bounded(args[2]), try bounded(args[3]), day))
        }
        lisp.define("calendar-nth-named-day") { lisp, args in
            gregorian(try bounded(try lisp.callNamed("calendar-nth-named-absday", args)))
        }
        lisp.define("calendar-iso-from-absolute") { _, args in
            try arity(args, 1...1, "calendar-iso-from-absolute")
            let day = try bounded(args[0])
            let thursday = day - (Days.weekday(day) + 6) % 7 + 3
            return .list([.integer(Days.isoWeek(day)), .integer(Days.weekday(day)), .integer(Days.date(thursday).year)])
        }

        lisp.define("diary-ordinal-suffix") { _, args in
            try arity(args, 1...1, "diary-ordinal-suffix")
            return .string(try ordinalSuffix(try Elisp.int(args[0])))
        }
        lisp.define("diary-make-date") { lisp, args in
            try arity(args, 3...3, "diary-make-date")
            return .list(try makeDate(lisp, args[0], args[1], args[2]))
        }
        lisp.define("diary-date") { lisp, args in
            try arity(args, 3...4, "diary-date")
            let wanted = try makeDate(lisp, args[0], args[1], args[2])
            let d = try parts(try date())
            for (spec, actual) in zip(wanted, [d.month, d.day, d.year]) {
                let holds = switch spec {
                case .symbol("t"): true
                case .list(let items): items.contains(.integer(actual))
                case .integer(let i): i == actual
                default: false
                }
                if !holds { return .nil }
            }
            return Elisp.cons(optional(args, 3), try entry())
        }
        lisp.define("diary-block") { lisp, args in
            try arity(args, 6...7, "diary-block")
            let first = try absolute(.list(try makeDate(lisp, args[0], args[1], args[2])))
            let last = try absolute(.list(try makeDate(lisp, args[3], args[4], args[5])))
            let d = try absolute(try date())
            return first <= d && d <= last ? Elisp.cons(optional(args, 6), try entry()) : .nil
        }
        lisp.define("diary-float") { _, args in
            try arity(args, 3...5, "diary-float")
            let month = args[0]
            let dayname = try bounded(args[1])
            let n = try bounded(args[2])
            let day = Elisp.isNil(optional(args, 3)) ? nil : try bounded(args[3])
            let current = try absolute(try date())
            guard dayname == Days.weekday(current) else { return .nil }
            let d = Days.date(current)
            let limit = try nthNamedAbsday(-n, dayname, d.month, d.year, d.day)
            let lastAbs = n > 0 ? limit : limit + 6
            let firstAbs = n > 0 ? limit - 6 : limit
            let first = Days.date(firstAbs)
            let last = Days.date(lastAbs)
            func monthMatches(_ m: Int) -> Bool {
                switch month {
                case .symbol("t"): true
                case .list(let items): items.contains(.integer(m))
                case .integer(let i): i == m
                default: false
                }
            }
            func base(_ m: Int, _ y: Int) throws -> Int { try day ?? (n > 0 ? 1 : lastDay(month: m, year: y)) }
            let applies: Bool
            if first.month == last.month {
                let b = try base(first.month, first.year)
                applies = monthMatches(first.month) && first.day <= b && b <= last.day
            } else {
                let firstBase = try base(first.month, first.year)
                let lastBase = try base(last.month, last.year)
                applies = (first.year < last.year || (first.year == last.year && first.month < last.month))
                    && ((monthMatches(first.month) && first.day <= firstBase) || (monthMatches(last.month) && lastBase <= last.day))
            }
            return applies ? Elisp.cons(optional(args, 4), try entry()) : .nil
        }
        lisp.define("diary-anniversary") { lisp, args in
            try arity(args, 2...4, "diary-anniversary")
            let made = try makeDate(lisp, args[0], args[1], optional(args, 2))
            var dd = try bounded(made[1])
            var mm = try bounded(made[0])
            let y = try parts(try date()).year
            let diff = Elisp.isNil(made[2]) ? 100 : y - (try bounded(made[2]))
            if mm == 2, dd == 29, !isLeap(y) {
                mm = 3
                dd = 1
            }
            let d = try parts(try date())
            guard diff > 0, (mm, dd, y) == (d.month, d.day, d.year) else { return .nil }
            return Elisp.cons(optional(args, 3), .string(try Elisp.format([try entry(), .integer(diff), .string(try ordinalSuffix(diff))])))
        }
        lisp.define("diary-cyclic") { lisp, args in
            try arity(args, 4...5, "diary-cyclic")
            let n = try Elisp.int(args[0])
            guard n > 0 else { throw Elisp.Signal(message: "Day count must be positive") }
            let diff = try absolute(try date()) - (try absolute(.list(try makeDate(lisp, args[1], args[2], args[3]))))
            let cycle = diff / n
            guard diff >= 0, diff % n == 0 else { return .nil }
            return Elisp.cons(optional(args, 4), .string(try Elisp.format([try entry(), .integer(cycle), .string(try ordinalSuffix(cycle))])))
        }
        lisp.define("diary-remind") { lisp, args in
            try arity(args, 2...3, "diary-remind")
            var days = args[1]
            if case .integer(let n) = days, n < 0 {
                guard n >= -Elisp.lengthLimit else { throw Elisp.Signal(message: "Too many days for diary-remind") }
                days = Elisp.list((1...(-n)).map { .integer($0) })
            }
            func remind(_ days: Sexp) throws -> Sexp {
                let applies = try lisp.eval(args[0])
                if !Elisp.isNil(applies) { return applies }
                if case .integer(let n) = days {
                    let shifted = gregorian(try absolute(try date()) + (try bounded(.integer(n))))
                    var found = try lisp.binding(["date": shifted]) { try lisp.eval(args[0]) }
                    guard !Elisp.isNil(found) else { return .nil }
                    if case .dotted = found { found = try Elisp.cdr(found) } else if case .list = found { found = try Elisp.cdr(found) }
                    let span = n % 7 == 0 ? String(format: "%d week%@", n / 7, n == 7 ? "" : "s") : String(format: "%d day%@", n, n == 1 ? "" : "s")
                    return .string("Reminder: Only " + span + " until " + Elisp.printed(found))
                }
                guard case .list(let items) = days, let first = items.first else { return .nil }
                let head = try remind(first)
                return Elisp.isNil(head) ? try remind(Elisp.list(Array(items.dropFirst()))) : head
            }
            return try remind(days)
        }

        lisp.define("org-anniversary") { lisp, args in try iso(lisp) { try lisp.callNamed("diary-anniversary", args) } }
        lisp.define("org-cyclic") { lisp, args in try iso(lisp) { try lisp.callNamed("diary-cyclic", args) } }
        lisp.define("org-block") { lisp, args in try iso(lisp) { try lisp.callNamed("diary-block", args) } }
        lisp.define("org-date") { lisp, args in try iso(lisp) { try lisp.callNamed("diary-date", args) } }
        lisp.define("org-class") { _, args in
            try arity(args, 7...Int.max, "org-class")
            let ints = try args.prefix(7).map(bounded)
            let first = Days.absolute(year: ints[0], month: ints[1], day: ints[2])
            let last = Days.absolute(year: ints[3], month: ints[4], day: ints[5])
            let d = try absolute(try date())
            let skip = Array(args.dropFirst(7))
            // Holiday names and `holidays' need the calendar's holiday lists.
            guard skip.allSatisfy({ $0.integer != nil }) else { throw Elisp.Unsupported(what: "org-class holidays") }
            let week = Days.isoWeek(d)
            guard first <= d, d <= last, Days.weekday(d) == ints[6], !skip.contains(.integer(week)) else { return .nil }
            return try entry()
        }
    }
}
