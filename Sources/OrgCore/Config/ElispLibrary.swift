import Foundation

// Math, string, list, seq and cl-lib functions of the evaluator.

extension Elisp {
    static func library(_ lisp: Elisp) {
        lisp.set("float-pi", .float(Double.pi))
        lisp.set("pi", .float(Double.pi))
        lisp.set("float-e", .float(M_E))
        mathFunctions(lisp)
        stringFunctions(lisp)
        sequenceFunctions(lisp)
    }

    static func mathFunctions(_ lisp: Elisp) {
        let unary: [(String, (Double) -> Double)] = [("sqrt", { $0.squareRoot() }), ("exp", exp), ("sin", sin), ("cos", cos), ("tan", tan), ("asin", asin), ("acos", acos)]
        for (name, f) in unary {
            lisp.define(name) { _, args in
                try arity(args, 1...1, name)
                return .float(f(try number(args[0]).double))
            }
        }
        lisp.define("log") { _, args in
            try arity(args, 1...2, "log")
            let x = try number(args[0]).double
            guard args.count == 2, !isNil(args[1]) else { return .float(Foundation.log(x)) }
            let base = try number(args[1]).double
            return .float(base == 10 ? log10(x) : base == 2 ? log2(x) : Foundation.log(x) / Foundation.log(base))
        }
        lisp.define("atan") { _, args in
            try arity(args, 1...2, "atan")
            let y = try number(args[0]).double
            return .float(args.count == 2 && !isNil(args[1]) ? atan2(y, try number(args[1]).double) : atan(y))
        }
        lisp.define("expt") { _, args in
            try arity(args, 2...2, "expt")
            switch (try number(args[0]), try number(args[1])) {
            case (.int(var base), .int(var exponent)) where exponent >= 0:
                var result = 1
                while true {
                    if exponent & 1 == 1 {
                        let (product, overflow) = result.multipliedReportingOverflow(by: base)
                        if overflow { throw Unsupported(what: "integer size") }
                        result = product
                    }
                    exponent >>= 1
                    if exponent == 0 { return .integer(result) }
                    let (square, overflow) = base.multipliedReportingOverflow(by: base)
                    if overflow { throw Unsupported(what: "integer size") }
                    base = square
                }
            case (let a, let b):
                return .float(pow(a.double, b.double))
            }
        }
        lisp.define("isnan") { _, args in
            try arity(args, 1...1, "isnan")
            guard case .float(let d) = args[0] else { throw Signal(message: "Wrong type argument: floatp, \(args[0].description)") }
            return bool(d.isNaN)
        }
        lisp.define("random") { _, args in
            try arity(args, 0...1, "random")
            switch args.first ?? .nil {
            case .integer(let n):
                guard n > 0 else { throw Signal(message: "Args out of range: \(n)") }
                return .integer(Int.random(in: 0..<n))
            case let v where isNil(v) || v == t:
                return .integer(Int.random(in: -(1 << 61)...((1 << 61) - 1)))
            default:
                throw Unsupported(what: "random with a seed")
            }
        }
        for (name, identity, op) in [("logand", -1, { (a: Int, b: Int) in a & b }), ("logior", 0, { $0 | $1 }), ("logxor", 0, { $0 ^ $1 })] {
            lisp.define(name) { _, args in .integer(try args.map(int).reduce(identity, op)) }
        }
        lisp.define("ash") { _, args in
            try arity(args, 2...2, "ash")
            let value = try int(args[0])
            let count = try int(args[1])
            if count < 0 { return .integer(value >> min(-count, 63)) }
            guard count < 63, (value << count) >> count == value else { throw Unsupported(what: "integer size") }
            return .integer(value << count)
        }
    }

    static func stringFunctions(_ lisp: Elisp) {
        lisp.define("string-join") { _, args in
            try arity(args, 1...2, "string-join")
            let separator = args.count > 1 && !isNil(args[1]) ? try string(args[1]) : ""
            return .string(try elements(args[0]).map(printedString).joined(separator: separator))
        }
        lisp.define("string-to-char") { _, args in
            try arity(args, 1...1, "string-to-char")
            return .integer(Int(try string(args[0]).unicodeScalars.first?.value ?? 0))
        }
        lisp.define("char-to-string") { _, args in
            try arity(args, 1...1, "char-to-string")
            return .string(String(try scalar(try int(args[0]))))
        }
        lisp.define("string-pad") { _, args in
            try arity(args, 2...4, "string-pad")
            let s = try string(args[0])
            let pad = try int(args[1]) - s.unicodeScalars.count
            guard pad > 0 else { return .string(s) }
            let padding = String(repeating: String(try scalar(args.count > 2 && !isNil(args[2]) ? try int(args[2]) : 32)), count: pad)
            return .string(args.count > 3 && !isNil(args[3]) ? padding + s : s + padding)
        }
        lisp.define("string-width") { _, args in
            try arity(args, 1...3, "string-width")
            let scalars = Array(try string(args[0]).unicodeScalars)
            let from = args.count > 1 && !isNil(args[1]) ? try int(args[1]) : 0
            let to = args.count > 2 && !isNil(args[2]) ? try int(args[2]) : scalars.count
            guard 0 <= from, from <= to, to <= scalars.count else { throw Signal(message: "Args out of range") }
            return .integer(try scalars[from..<to].reduce(0) { width, c in
                switch c.value {
                case 9: return width + 8
                case 10: return width
                case 0x20...0x7E, 0xC0...0x27F: return width + 1
                default: throw Unsupported(what: "string-width of \(String(c))")
                }
            })
        }
        lisp.define("string-search") { _, args in
            try arity(args, 2...3, "string-search")
            let needle = Array(try string(args[0]).unicodeScalars)
            let haystack = Array(try string(args[1]).unicodeScalars)
            let start = args.count > 2 && !isNil(args[2]) ? try int(args[2]) : 0
            guard (0...haystack.count).contains(start) else { throw Signal(message: "Args out of range: \(start)") }
            guard needle.count <= haystack.count else { return .nil }
            for i in start...(haystack.count - needle.count) where haystack[i..<(i + needle.count)].elementsEqual(needle) { return .integer(i) }
            return .nil
        }
        lisp.define("string-replace") { _, args in
            try arity(args, 3...3, "string-replace")
            let from = try string(args[0])
            guard !from.isEmpty else { throw Signal(message: "Wrong length argument: 0") }
            return .string(try string(args[2]).replacingOccurrences(of: from, with: try string(args[1]), options: .literal))
        }
    }

    /// The functions that change a list or vector in place, and what a variable holding the
    /// argument holds after the call: the sorted list for an in-place `sort`, its first cell
    /// for `nreverse`.
    static func afterInPlace(_ name: String, _ args: [Sexp], _ result: Sexp) -> Sexp? {
        switch name {
        case "sort":
            let inPlace = args.count == 2 || args.indices.contains { $0 % 2 == 1 && args[$0] == .symbol(":in-place") && $0 + 1 < args.count && !isNil(args[$0 + 1]) }
            return inPlace ? result : nil
        case "nreverse":
            if case .list(let items) = args[0], let first = items.first { return .list([first]) }
            return isNil(args[0]) ? nil : result
        case "delete-dups":
            return result
        default:
            return nil
        }
    }

    /// Keyword arguments `args` after the first `count`, of which only `allowed` are known.
    static func keywords(_ args: [Sexp], after count: Int, allowed: Set<String>, _ name: String) throws -> [String: Sexp] {
        let rest = Array(args.dropFirst(count))
        guard rest.count % 2 == 0 else { throw Signal(message: "Odd number of keyword arguments for \(name)") }
        var result: [String: Sexp] = [:]
        for i in stride(from: 0, to: rest.count, by: 2) {
            guard let key = rest[i].symbol, allowed.contains(key) else { throw Unsupported(what: "\(name) with \(rest[i].description)") }
            if result[key] == nil { result[key] = rest[i + 1] }
        }
        return result
    }

    /// `value<` on numbers, strings and symbols.
    static func valueLess(_ a: Sexp, _ b: Sexp) throws -> Bool {
        if let x = try? number(a), let y = try? number(b) {
            if case .int(let i) = x, case .int(let j) = y { return i < j }
            return x.double < y.double
        }
        switch (a, b) {
        case (.string(let x), .string(let y)): return x.unicodeScalars.map(\.value).lexicographicallyPrecedes(y.unicodeScalars.map(\.value))
        case (.symbol(let x), .symbol(let y)) where !isNil(a) && !isNil(b): return x.unicodeScalars.map(\.value).lexicographicallyPrecedes(y.unicodeScalars.map(\.value))
        default: throw Unsupported(what: "value< on \(a.description) and \(b.description)")
        }
    }

    /// A stable merge sort with a predicate that may throw.
    static func stableSort(_ items: [Sexp], _ less: (Sexp, Sexp) throws -> Bool) throws -> [Sexp] {
        guard items.count > 1 else { return items }
        let left = try stableSort(Array(items[..<(items.count / 2)]), less)
        let right = try stableSort(Array(items[(items.count / 2)...]), less)
        var merged: [Sexp] = []
        merged.reserveCapacity(items.count)
        var (i, j) = (0, 0)
        while i < left.count, j < right.count {
            if try less(right[j], left[i]) {
                merged.append(right[j])
                j += 1
            } else {
                merged.append(left[i])
                i += 1
            }
        }
        return merged + left[i...] + right[j...]
    }

    /// `items` as the kind of sequence `like` is.
    static func sameKind(_ items: [Sexp], as like: Sexp) throws -> Sexp {
        switch like {
        case .vector: return .vector(items)
        case .string: return .string(try printedString(.list(items)))
        default: return list(items)
        }
    }

    static func sequenceFunctions(_ lisp: Elisp) {
        lisp.define("last") { _, args in
            try arity(args, 1...2, "last")
            let n = args.count > 1 && !isNil(args[1]) ? try int(args[1]) : 1
            switch args[0] {
            case .list(let items): return list(Array(items.suffix(max(0, n))))
            case .dotted(let items, let tail): return n <= 0 ? tail : .dotted(Array(items.suffix(n)), tail)
            case let v where isNil(v): return .nil
            default: throw Signal(message: "Wrong type argument: listp, \(args[0].description)")
            }
        }
        lisp.define("butlast") { _, args in
            try arity(args, 1...2, "butlast")
            let n = args.count > 1 && !isNil(args[1]) ? try int(args[1]) : 1
            guard n > 0 else { return args[0] }
            return list(Array(try elements(args[0]).dropLast(n)))
        }
        lisp.define("delete-dups") { _, args in
            try arity(args, 1...1, "delete-dups")
            var kept: [Sexp] = []
            for item in try elements(args[0]) where !kept.contains(where: { normalized($0) == normalized(item) }) { kept.append(item) }
            return list(kept)
        }
        lisp.define("nreverse") { _, args in
            try arity(args, 1...1, "nreverse")
            switch args[0] {
            case .string(let s): return .string(String(String.UnicodeScalarView(s.unicodeScalars.reversed())))
            case .vector(let items): return .vector(items.reversed())
            default: return list(try elements(args[0]).reversed())
            }
        }
        lisp.define("sort") { lisp, args in
            try arity(args, 1...Int.max, "sort")
            var key = Sexp.nil
            var lessp = Sexp.nil
            var reverse = false
            if args.count == 2 {
                guard args[1].symbol?.hasPrefix(":") != true else { throw Signal(message: "Odd number of keyword arguments for sort") }
                lessp = args[1]
            } else {
                let options = try keywords(args, after: 1, allowed: [":key", ":lessp", ":reverse", ":in-place"], "sort")
                key = options[":key"] ?? .nil
                lessp = options[":lessp"] ?? .nil
                reverse = !isNil(options[":reverse"] ?? .nil)
            }
            let items: [Sexp]
            switch args[0] {
            case .vector(let v): items = v
            case .string: throw Unsupported(what: "sort on a string")
            default: items = try elements(args[0])
            }
            let keyed = try items.map { isNil(key) ? ($0, $0) : ($0, try lisp.call(key, [$0])) }
            func less(_ a: Sexp, _ b: Sexp) throws -> Bool {
                isNil(lessp) ? try valueLess(a, b) : !isNil(try lisp.call(lessp, [a, b]))
            }
            let keys = keyed.map(\.1)
            let order = try stableSort((0..<items.count).map { .integer($0) }) { a, b in
                let (i, j) = (a.integer!, b.integer!)
                return reverse ? try less(keys[j], keys[i]) : try less(keys[i], keys[j])
            }
            let sorted = order.map { items[$0.integer!] }
            if case .vector = args[0] { return .vector(sorted) }
            return list(sorted)
        }
        lisp.define("seq-reduce") { lisp, args in
            try arity(args, 3...3, "seq-reduce")
            return try sequence(args[1]).reduce(args[2]) { try lisp.call(args[0], [$0, $1]) }
        }
        for name in ["seq-filter", "seq-remove"] {
            lisp.define(name) { lisp, args in
                try arity(args, 2...2, name)
                return list(try sequence(args[1]).filter { isNil(try lisp.call(args[0], [$0])) == (name == "seq-remove") })
            }
        }
        lisp.define("seq-map") { lisp, args in
            try arity(args, 2...2, "seq-map")
            return list(try sequence(args[1]).map { try lisp.call(args[0], [$0]) })
        }
        lisp.define("seq-uniq") { _, args in
            try arity(args, 1...2, "seq-uniq")
            guard args.count == 1 || isNil(args[1]) else { throw Unsupported(what: "seq-uniq with a test") }
            var kept: [Sexp] = []
            for item in try sequence(args[0]) where !kept.contains(where: { normalized($0) == normalized(item) }) { kept.append(item) }
            return list(kept)
        }
        lisp.define("cl-reduce") { lisp, args in
            try arity(args, 2...Int.max, "cl-reduce")
            let options = try keywords(args, after: 2, allowed: [":initial-value"], "cl-reduce")
            var items = try sequence(args[1])[...]
            guard let initial = options[":initial-value"] ?? items.popFirst() else { return try lisp.call(args[0], []) }
            return try items.reduce(initial) { try lisp.call(args[0], [$0, $1]) }
        }
        for name in ["cl-remove-if", "cl-remove-if-not"] {
            lisp.define(name) { lisp, args in
                try arity(args, 2...Int.max, name)
                _ = try keywords(args, after: 2, allowed: [], name)
                return try sameKind(try sequence(args[1]).filter { isNil(try lisp.call(args[0], [$0])) == (name == "cl-remove-if") }, as: args[1])
            }
        }
        for name in ["cl-find", "cl-position"] {
            lisp.define(name) { lisp, args in
                try arity(args, 2...Int.max, name)
                let test = try keywords(args, after: 2, allowed: [":test"], name)[":test"] ?? .nil
                for (i, item) in try sequence(args[1]).enumerated() {
                    let found = isNil(test) ? eq(args[0], item) : !isNil(try lisp.call(test, [args[0], item]))
                    if found { return name == "cl-find" ? item : .integer(i) }
                }
                return .nil
            }
        }
    }
}
