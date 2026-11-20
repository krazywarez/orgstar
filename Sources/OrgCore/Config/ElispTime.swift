import Foundation

// Lisp timestamps, `format-time-string`, the Org and `time-*` functions, and the calendar
// functions, for table formulas, Emacs Lisp blocks and capture templates.

extension Elisp {
    /// A Lisp timestamp: whole seconds, picoseconds past them, and the resolution it came
    /// with (1 for an integer or `(HIGH LOW)`, else a list with microseconds).
    struct Time {
        var seconds: Int
        var picoseconds = 0
        var hz = 1

        static let pico = 1_000_000_000_000

        init(seconds: Int, picoseconds: Int = 0, hz: Int = 1) {
            self.seconds = seconds
            self.picoseconds = picoseconds
            self.hz = hz
        }

        init(_ date: Date) {
            let whole = date.timeIntervalSince1970.rounded(.down)
            seconds = Int(whole)
            picoseconds = Int((date.timeIntervalSince1970 - whole) * 1_000_000) * 1_000_000
            hz = Self.pico
        }

        /// `(HIGH LOW USEC PSEC)`, or an integer when the resolution is seconds.
        var sexp: Sexp {
            hz == 1 ? .integer(seconds) : .list([.integer(seconds >> 16), .integer(seconds & 0xFFFF), .integer(picoseconds / 1_000_000), .integer(picoseconds % 1_000_000)])
        }

        /// `(HIGH LOW)`, as `encode-time` gives.
        var pair: Sexp { .list([.integer(seconds >> 16), .integer(seconds & 0xFFFF)]) }
    }

    static func time(_ v: Sexp, now: Date) throws -> Time {
        switch v {
        case _ where isNil(v): return Time(now)
        case .integer(let i): return Time(seconds: i)
        case .float: throw Unsupported(what: "float times")
        case .list(let parts) where (2...4).contains(parts.count):
            let ints = try parts.map(int)
            guard (-(1 << 40)...(1 << 40)).contains(ints[0]), (0..<65536).contains(ints[1]),
                  ints.dropFirst(2).allSatisfy({ (0..<1_000_000).contains($0) }) else { throw Unsupported(what: "time value \(v.description)") }
            let micro = ints.count > 2 ? ints[2] : 0
            let pico = ints.count > 3 ? ints[3] : 0
            return Time(seconds: ints[0] << 16 + ints[1], picoseconds: micro * 1_000_000 + pico, hz: [1, 1, 1_000_000, Time.pico][ints.count - 1])
        default: throw Unsupported(what: "time value \(v.description)")
        }
    }

    /// The seconds of a time, floats included, for the functions that read only the date.
    static func wholeSeconds(_ v: Sexp, now: Date) throws -> Int {
        if case .float(let d) = v {
            guard d.isFinite, abs(d) < 1e15 else { throw Unsupported(what: "time value \(v.description)") }
            return Int(d.rounded(.down))
        }
        return try time(v, now: now).seconds
    }

    /// `org-ts-regexp0`.
    static let orgTimeString = try! NSRegularExpression(pattern: "(([0-9]{4})-([0-9]{2})-([0-9]{2})( +[^\\]+0-9>\\r\\n \\-]+)?( +([0-9]{1,2}):([0-9]{2}))?)")

    /// `org-parse-time-string`: year, month, day, hour and minute.
    static func orgTime(_ s: String) throws -> [Int] {
        let ns = s as NSString
        guard let m = orgTimeString.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            throw Signal(message: "Not an Org time string: \(s)")
        }
        func group(_ i: Int) -> Int { m.range(at: i).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: i)))! }
        let parts = [group(2), group(3), group(4), group(7), group(8)]
        guard (1...12).contains(parts[1]), (1...31).contains(parts[2]), parts[3] < 24, parts[4] < 60 else { throw Unsupported(what: "time string \(s)") }
        return parts
    }

    /// Days from 1 January 1970 to absolute day 1, 1 January of year 1.
    static let epochDay = 719163

    /// `encode-time` of a local date and time, in the proleptic Gregorian calendar as Emacs
    /// counts. Foundation's Gregorian calendar is Julian before 15 October 1582, so earlier
    /// dates are counted here, where no daylight saving time applies.
    static func encode(_ parts: [Int], calendar: Calendar) throws -> Time {
        let second = parts.count > 5 ? parts[5] : 0
        if parts[0] >= 1583 {
            guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: second)) else {
                throw Unsupported(what: "date \(parts)")
            }
            return Time(seconds: Int(date.timeIntervalSince1970.rounded(.down)))
        }
        let local = (Days.absolute(year: parts[0], month: parts[1], day: parts[2]) - epochDay) * 86400 + parts[3] * 3600 + parts[4] * 60 + second
        func offset(_ seconds: Int) -> Int { calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds))) }
        return Time(seconds: local - offset(local - offset(local)))
    }

    /// The local date and time of `seconds` in the proleptic Gregorian calendar: the absolute
    /// day, and the seconds into it.
    static func civil(_ seconds: Int, calendar: Calendar) -> (day: Int, second: Int) {
        let local = seconds + calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
        let day = local >= 0 ? local / 86400 : -((-local - 1) / 86400) - 1
        return (day + epochDay, local - day * 86400)
    }

    /// `date-to-time` for ISO 8601 dates, with or without a time.
    static func dateToTime(_ s: String, calendar: Calendar) throws -> Time {
        guard let m = s.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[ T]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?)?/) else {
            throw Unsupported(what: "date-to-time of \(s)")
        }
        let parts = [Int(m.1)!, Int(m.2)!, Int(m.3)!, m.4.map { Int($0)! } ?? 0, m.5.map { Int($0)! } ?? 0, m.6.map { Int($0)! } ?? 0]
        guard (1...12).contains(parts[1]), (1...31).contains(parts[2]), parts[3] < 24, parts[4] < 60, parts[5] < 60 else { throw Unsupported(what: "date-to-time of \(s)") }
        return try encode(parts, calendar: calendar)
    }

    static func days(_ seconds: Int, calendar: Calendar) -> Int {
        civil(seconds, calendar: calendar).day
    }

    /// `format-time-string` with the conversions that don't depend on the locale, without
    /// flags or widths.
    static func formatTime(_ format: String, _ seconds: Int, calendar: Calendar) throws -> String {
        let (absolute, secondOfDay) = civil(seconds, calendar: calendar)
        let (year, month, day) = Days.date(absolute)
        let (hour, minute, second) = (secondOfDay / 3600, secondOfDay % 3600 / 60, secondOfDay % 60)
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let weekday = Days.weekday(absolute)
        // Four digits with the sign, and the last two digits of the year without it.
        let yearText = year < 0 ? String(format: "-%03d", -year) : String(format: "%04d", year)
        let shortYear = abs(year) % 100
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        var out = ""
        var chars = format.makeIterator()
        while let ch = chars.next() {
            guard ch == "%" else {
                out.append(ch)
                continue
            }
            guard let f = chars.next() else { throw Unsupported(what: "format-time-string %") }
            switch f {
            case "Y": out += yearText
            case "y": out += String(format: "%02d", shortYear)
            case "m": out += String(format: "%02d", month)
            case "d": out += String(format: "%02d", day)
            case "e": out += String(format: "%2d", day)
            case "H": out += String(format: "%02d", hour)
            case "k": out += String(format: "%2d", hour)
            case "I": out += String(format: "%02d", hour12)
            case "l": out += String(format: "%2d", hour12)
            case "M": out += String(format: "%02d", minute)
            case "S": out += String(format: "%02d", second)
            case "p": out += hour < 12 ? "AM" : "PM"
            case "a": out += String(days[weekday].prefix(3))
            case "A": out += days[weekday]
            case "b", "h": out += String(months[month - 1].prefix(3))
            case "B": out += months[month - 1]
            case "u": out += String(weekday == 0 ? 7 : weekday)
            case "w": out += String(weekday)
            case "j": out += String(format: "%03d", Days.absolute(year: year, month: month, day: day) - Days.absolute(year: year, month: 1, day: 0))
            case "F": out += (year > 9999 ? "+" : "") + yearText + String(format: "-%02d-%02d", month, day)
            case "D": out += String(format: "%02d/%02d/%02d", month, day, shortYear)
            case "R": out += String(format: "%02d:%02d", hour, minute)
            case "T": out += String(format: "%02d:%02d:%02d", hour, minute, second)
            case "s": out += String(seconds)
            case "z":
                let offset = calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds))) / 60
                out += String(format: "%@%02d%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
            case "n": out += "\n"
            case "t": out += "\t"
            case "%": out += "%"
            default: throw Unsupported(what: "format-time-string %\(f)")
            }
        }
        return out
    }

    /// Defines the time functions and the calendar functions diary sexps use, with times in
    /// `calendar`'s time zone and `now` as the clock.
    public func standardTime(now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        var calendar = calendar
        if calendar.identifier != .gregorian {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            calendar = gregorian
        }
        let local = calendar
        DiarySexp.defineCalendar(self)
        define("current-time") { _, args in
            try Elisp.arity(args, 0...0, "current-time")
            return Time(now()).sexp
        }
        define("format-time-string") { _, args in
            try Elisp.arity(args, 1...3, "format-time-string")
            var zoned = local
            if args.count > 2, !Elisp.isNil(args[2]) {
                guard args[2] == Elisp.t || args[2] == .string("UTC") || args[2] == .integer(0) else { throw Unsupported(what: "format-time-string zone \(args[2].description)") }
                zoned.timeZone = TimeZone(identifier: "UTC")!
            }
            return .string(try Elisp.formatTime(try Elisp.string(args[0]), try Elisp.wholeSeconds(args.count > 1 ? args[1] : .nil, now: now()), calendar: zoned))
        }
        define("org-time-string-to-time") { _, args in
            try Elisp.arity(args, 1...1, "org-time-string-to-time")
            return try Elisp.encode(try Elisp.orgTime(try Elisp.string(args[0])), calendar: local).pair
        }
        define("org-time-string-to-absolute") { _, args in
            try Elisp.arity(args, 1...5, "org-time-string-to-absolute")
            guard args.count == 1 else { throw Unsupported(what: "org-time-string-to-absolute with a day") }
            let parts = try Elisp.orgTime(try Elisp.string(args[0]))
            return .integer(Days.absolute(year: parts[0], month: parts[1], day: parts[2]))
        }
        for name in ["time-add", "time-subtract"] {
            define(name) { _, args in
                try Elisp.arity(args, 2...2, name)
                let a = try Elisp.time(args[0], now: now())
                let b = try Elisp.time(args[1], now: now())
                let sign = name == "time-add" ? 1 : -1
                var picoseconds = a.picoseconds + sign * b.picoseconds
                var seconds = a.seconds + sign * b.seconds
                if picoseconds < 0 {
                    picoseconds += Time.pico
                    seconds -= 1
                } else if picoseconds >= Time.pico {
                    picoseconds -= Time.pico
                    seconds += 1
                }
                return Time(seconds: seconds, picoseconds: picoseconds, hz: max(a.hz, b.hz)).sexp
            }
        }
        define("float-time") { _, args in
            try Elisp.arity(args, 0...1, "float-time")
            if case .float(let d)? = args.first { return .float(d) }
            let time = try Elisp.time(args.first ?? .nil, now: now())
            guard time.picoseconds % 1_000_000 == 0 else { throw Unsupported(what: "float-time of picoseconds") }
            return .float(Double(time.seconds * 1_000_000 + time.picoseconds / 1_000_000) / 1_000_000)
        }
        define("date-to-time") { _, args in
            try Elisp.arity(args, 1...1, "date-to-time")
            return try Elisp.dateToTime(try Elisp.string(args[0]), calendar: local).pair
        }
        define("time-to-days") { _, args in
            try Elisp.arity(args, 1...1, "time-to-days")
            return .integer(Elisp.days(try Elisp.wholeSeconds(args[0], now: now()), calendar: local))
        }
        define("days-between") { _, args in
            try Elisp.arity(args, 2...2, "days-between")
            let a = try Elisp.dateToTime(try Elisp.string(args[0]), calendar: local)
            let b = try Elisp.dateToTime(try Elisp.string(args[1]), calendar: local)
            return .integer(Elisp.days(a.seconds, calendar: local) - Elisp.days(b.seconds, calendar: local))
        }
    }
}
