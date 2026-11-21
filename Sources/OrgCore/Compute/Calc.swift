import Foundation

/// The part of Emacs Calc that table formulas use, with Calc's number semantics: exact
/// integers, decimal floats rounded to `calc-internal-prec` digits after every operation, and
/// Calc's display formats. Anything outside this domain throws `Calc.Unsupported`, and the
/// caller hands the work to Emacs.
public enum Calc {
    public struct Unsupported: Error, Equatable, CustomStringConvertible {
        public let reason: String
        /// The left-hand side of the table formula that threw, once recalculation knows it.
        public var formula: String?
        public var description: String { reason }
        init(_ reason: String) { self.reason = reason }
    }

    /// An error Calc reports, which a table shows as `#ERROR`.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let reason: String
        /// Where in the expression Calc reports the error.
        public let position: Int
        public var description: String { reason }
        init(_ reason: String, position: Int = 0) { (self.reason, self.position) = (reason, position) }
    }

    public indirect enum Value: Equatable, Sendable {
        case int(Int)
        /// Mantissa and exponent, normalized: at most `precision` digits, no trailing zeros.
        case float(Int, Int)
        case vector([Value])
        /// A date form: the day number, with the time of day as a fraction.
        case date(Value)
        case nan
        /// An exact fraction, reduced, the denominator above 1 (`calc-prefer-frac`).
        case frac(Int, Int)
        /// A formula Calc leaves unevaluated, with variables or a quotient by zero.
        case symbolic(Term)
    }

    public enum FloatFormat: Equatable, Sendable {
        case float(Int), fix(Int), sci(Int), eng(Int)
    }

    public struct Modes: Equatable, Sendable {
        public var precision = 12
        public var format = FloatFormat.float(8)
        public var degrees = true
        /// `calc-prefer-frac`: dividing integers gives a fraction.
        public var preferFractions = false
        /// `calc-symbolic-mode`: functions whose result isn't exact stay unevaluated.
        public var symbolic = false
        /// The clock `now()` reads; nil is the system clock.
        public var now: Date?
        /// The local time zone, for `now()`, `julian` and `unixtime`.
        public var timeZone = TimeZone.current
        public init() {}
    }

    /// `calc-eval` of `expression`, as the string Calc would return; with `numeric`, as
    /// `calc-eval` with `num`, a result that isn't a number is an error.
    public static func evaluate(_ expression: String, modes: Modes = Modes(), numeric: Bool = false) throws -> String {
        // Mantissas live in an Int, so 18 digits at most.
        guard (3...18).contains(modes.precision) else { throw Unsupported("calc precision") }
        return try $precision.withValue(modes.precision) {
            try $fractions.withValue(modes.preferFractions) {
                try $symbolicMode.withValue(modes.symbolic) {
                    var parser = Parser(expression)
                    let tree = try parser.parse()
                    let value = try Evaluator(modes: modes).eval(tree)
                    if numeric {
                        switch value {
                        case .int, .float, .frac: break
                        default:
                            // Calc explains the first argument a quotient, power or function
                            // rejected along the way, which isn't tracked here.
                            if tree.mayExplain { throw Unsupported("symbolic arithmetic") }
                            throw Failure("Number expected")
                        }
                    }
                    return try format(value, modes.format)
                }
            }
        }
    }

    // MARK: - Numbers

    /// `calc-internal-prec`.
    @TaskLocal static var precision = 12

    /// `math-with-extra-prec`: `body` with `n` more digits, the result rounded back.
    static func extra(_ n: Int, _ body: () throws -> Value) throws -> Value {
        let v = try $precision.withValue(precision + n, operation: body)
        if case .float(let m, let e) = v { return try makeFloat(Int128(m), e) }
        if case .date(.float(let m, let e)) = v { return .date(try makeFloat(Int128(m), e)) }
        if case .symbolic(let t) = v { return value(try Symbolic.normalize(t)) }
        return v
    }

    /// `math-use-emacs-fn`: `f` on a double, as Calc does at up to 16 digits. Above that
    /// Calc uses its own series, which isn't reproduced.
    static func emacs(_ f: (Double) -> Double, _ x: Value) throws -> Value {
        guard precision <= 16 else { throw Unsupported("calc precision") }
        guard case .float(let m, let e) = x, (-300...300).contains(e + digits(Int128(m)) - 1),
              let d = Double("\(m)e\(e)") else { throw Unsupported("number size") }
        let r = f(d)
        guard r.isFinite else { throw Unsupported("infinite result") }
        // `number-to-string`: the shortest text that reads back as the same double.
        let pieces = r.description.split(separator: "e")
        let text = String(pieces[0])
        let point = text.firstIndex(of: ".").map { text.distance(from: $0, to: text.endIndex) - 1 } ?? 0
        guard let mantissa = Int128(text.replacingOccurrences(of: ".", with: "")),
              let exponent = Int(pieces.count > 1 ? String(pieces[1]) : "0") else { throw Unsupported("number") }
        return try makeFloat(mantissa, exponent - point)
    }

    // Constants to 36 digits, rounded to the precision, as `math-defcache` gives them.
    static func pi() throws -> Value { try makeFloat(314159265358979323846264338327950288, -35) }
    static func piOver2() throws -> Value { try makeFloat(157079632679489661923132169163975144, -35) }
    static func piOver180() throws -> Value { try makeFloat(174532925199432957692369076848861271, -37) }

    /// `math-float`.
    static func float(_ v: Value) throws -> Value {
        switch v {
        case .int(let i): return try makeFloat(Int128(i), 0)
        case .frac(let n, let d): return try divide(try makeFloat(Int128(n), 0), .int(d))
        case .float: return v
        default: throw Unsupported("arguments")
        }
    }

    static func isZero(_ v: Value) -> Bool { v == .int(0) || v == .float(0, 0) }

    /// The sign of a real number.
    static func sign(_ v: Value) throws -> Int {
        switch v {
        case .int(let i): return i.signum()
        case .float(let m, _): return m.signum()
        case .frac(let n, _): return n.signum()
        default: throw Unsupported("arguments")
        }
    }

    /// `math-trunc` of a real number, as an integer.
    static func trunc(_ v: Value) throws -> Int {
        switch v {
        case .int(let i): return i
        case .frac(let n, let d): return n / d
        case .float(let m, let e):
            let t = e >= 0 ? try scaleRounding(Int128(m), e) : -e > 37 ? 0 : Int128(m) / (try power10(-e))
            guard let i = Int(exactly: t) else { throw Unsupported("integer size") }
            return i
        default: throw Unsupported("arguments")
        }
    }

    /// `Math-num-integerp`: an integer, or a float with an integer value.
    static func isWhole(_ v: Value) -> Bool {
        switch v {
        case .int: true
        case .float(_, let e): e >= 0
        default: false
        }
    }

    /// `math-nearly-equal-float`: equal but for the last digit of precision.
    static func nearlyEqual(_ a: Value, _ b: Value) -> Bool {
        guard case .float(let ma, let ea) = a, case .float(let mb, let eb) = b else { return false }
        let (x, y) = (Int128(ma), Int128(mb))
        switch ea - eb {
        case 0: return x == y || (abs(y - x) < 10 && digits(x) == precision)
        case 1: return abs(x * 10 - y) < 10 && digits(y) == precision
        case -1: return abs(y * 10 - x) < 10 && digits(x) == precision
        default: return false
        }
    }

    static func digits(_ x: Int128) -> Int {
        var n = x.magnitude
        var count = 1
        while n >= 10 {
            n /= 10
            count += 1
        }
        return count
    }

    static func power10(_ n: Int) throws -> Int128 {
        guard n >= 0, n <= 37 else { throw Unsupported("number size") }
        var result: Int128 = 1
        for _ in 0..<n { result *= 10 }
        return result
    }

    /// `math-scale-rounding`: `x` times 10^n, rounding half away from zero when n < 0.
    static func scaleRounding(_ x: Int128, _ n: Int) throws -> Int128 {
        if n >= 0 {
            let (result, overflow) = x.multipliedReportingOverflow(by: try power10(n))
            if overflow { throw Unsupported("number size") }
            return result
        }
        if x < 0 { return -(try scaleRounding(-x, n)) }
        if -n > 38 { return 0 }
        let truncated = -n - 1 > 37 ? 0 : x / (try power10(-n - 1))
        return (truncated + 5) / 10
    }

    /// `math-make-float`.
    static func makeFloat(_ mantissa: Int128, _ exponent: Int) throws -> Value {
        var m = mantissa
        var e = exponent
        if m == 0 { return .float(0, 0) }
        let excess = digits(m) - precision
        if excess > 0 {
            m = try scaleRounding(m, -excess)
            e += excess
        }
        if m == 0 { return .float(0, 0) }
        while m % 10 == 0 {
            m /= 10
            e += 1
        }
        guard let i = Int(exactly: m) else { throw Unsupported("calc precision") }
        return .float(i, e)
    }

    static func parts(_ v: Value) throws -> (Int128, Int) {
        switch v {
        // `math-float`: normalized and rounded, as Calc converts an integer to combine it with a float.
        case .int(let i): return try parts(try makeFloat(Int128(i), 0))
        case .float(let m, let e): return (Int128(m), e)
        case .frac(let n, let d): return try parts(try divide(.int(n), .int(d)))
        case .vector: throw Unsupported("vector arithmetic")
        case .date, .nan: throw Unsupported("date arithmetic")
        case .symbolic: throw Unsupported("symbolic arithmetic")
        }
    }

    /// An integer or a fraction as numerator and denominator.
    static func rational(_ v: Value) -> (Int, Int)? {
        switch v {
        case .int(let i): (i, 1)
        case .frac(let n, let d): (n, d)
        default: nil
        }
    }

    /// `math-make-frac`: reduced, as an integer when it is one.
    static func fraction(_ n: Int, _ d: Int) throws -> Value {
        guard d != 0 else { throw Unsupported("division by zero") }
        guard n != .min, d != .min else { throw Unsupported("integer size") }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }
        let g = gcd(n, d)
        var (num, den) = (n / g, d / g)
        if den < 0 { (num, den) = (-num, -den) }
        return den == 1 ? .int(num) : .frac(num, den)
    }

    /// Two rationals, one of them a fraction, combined exactly; nil otherwise.
    static func exact(_ a: Value, _ b: Value, _ op: (Int, Int, Int, Int) -> (Int, Int, Bool)) throws -> Value? {
        var fraction = false
        if case .frac = a { fraction = true }
        if case .frac = b { fraction = true }
        guard fraction, let (n1, d1) = rational(a), let (n2, d2) = rational(b) else { return nil }
        let (n, d, overflow) = op(n1, d1, n2, d2)
        if overflow { throw Unsupported("integer size") }
        return try self.fraction(n, d)
    }

    static func double(_ v: Value) throws -> Double {
        switch v {
        case .int(let i): return Double(i)
        case .float(let m, let e): return Double(m) * pow(10, Double(e))
        case .frac(let n, let d): return Double(n) / Double(d)
        case .vector: throw Unsupported("vector arithmetic")
        case .date, .nan: throw Unsupported("date arithmetic")
        case .symbolic: throw Unsupported("symbolic arithmetic")
        }
    }

    static func fromDouble(_ d: Double) throws -> Value {
        // Calc works these out at two digits more; past 16 it uses its own series.
        guard precision <= 14 else { throw Unsupported("calc precision") }
        guard d.isFinite else { throw Unsupported("infinite result") }
        if d == 0 { return .float(0, 0) }
        // Seventeen significant digits are exact for a Double; rounding to 12 follows.
        let text = String(format: "%.16e", d)
        let pieces = text.split(separator: "e")
        let digitsText = pieces[0].replacingOccurrences(of: ".", with: "")
        guard let mantissa = Int128(digitsText), let exponent = Int(pieces[1]) else { throw Unsupported("number") }
        return try makeFloat(mantissa, exponent - 16)
    }

    static func isSymbolic(_ vs: Value...) -> Bool {
        vs.contains { if case .symbolic = $0 { true } else { false } }
    }

    static func add(_ a: Value, _ b: Value) throws -> Value {
        if isSymbolic(a, b) { return value(try Symbolic.add(try term(a), try term(b))) }
        switch (a, b) {
        case (.nan, .vector), (.vector, .nan): throw Unsupported("vector arithmetic")
        case (.nan, _), (_, .nan): return .nan
        // Two dates add as their day numbers.
        case (.date(let x), .date(let y)): return try add(x, y)
        case (.date(let d), _): return .date(try add(d, b))
        case (_, .date(let d)): return .date(try add(a, d))
        default: break
        }
        if case .int(let x) = a, case .int(let y) = b {
            let (sum, overflow) = x.addingReportingOverflow(y)
            if overflow { throw Unsupported("integer size") }
            return .int(sum)
        }
        if let sum = try exact(a, b, { n1, d1, n2, d2 in
            let (p, o1) = n1.multipliedReportingOverflow(by: d2)
            let (q, o2) = n2.multipliedReportingOverflow(by: d1)
            let (n, o3) = p.addingReportingOverflow(q)
            let (d, o4) = d1.multipliedReportingOverflow(by: d2)
            return (n, d, o1 || o2 || o3 || o4)
        }) { return sum }
        let (m1, e1) = try parts(a)
        let (m2, e2) = try parts(b)
        if m1 == 0 { return try makeFloat(m2, e2) }
        if m2 == 0 { return try makeFloat(m1, e1) }
        let ediff = e1 - e2
        if ediff >= 0 {
            if ediff >= 2 * precision { return try makeFloat(m1, e1) }
            return try makeFloat(try scaleRounding(m1, ediff) + m2, e2)
        }
        if -ediff >= 2 * precision { return try makeFloat(m2, e2) }
        return try makeFloat(m1 + (try scaleRounding(m2, -ediff)), e1)
    }

    static func negate(_ a: Value) throws -> Value {
        switch a {
        case .symbolic(let t): return value(try Symbolic.neg(t))
        case .int(let i):
            guard i != .min else { throw Unsupported("integer size") }
            return .int(-i)
        case .float(let m, let e): return .float(-m, e)
        case .frac(let n, let d): return .frac(-n, d)
        case .vector: throw Unsupported("vector arithmetic")
        case .date(let d): return .date(try negate(d))
        case .nan: return .nan
        }
    }

    /// `a - b`: a date less a date is the days between them.
    static func subtract(_ a: Value, _ b: Value) throws -> Value {
        try add(a, try negate(b))
    }

    static func isNaN(_ a: Value, _ b: Value) -> Bool {
        if case .vector = a { return false }
        if case .vector = b { return false }
        return a == .nan || b == .nan
    }

    static func multiply(_ a: Value, _ b: Value) throws -> Value {
        if isSymbolic(a, b) { return value(try Symbolic.mul(try term(a), try term(b))) }
        if isNaN(a, b) { return .nan }
        if case .int(let x) = a, case .int(let y) = b {
            let (product, overflow) = x.multipliedReportingOverflow(by: y)
            if overflow { throw Unsupported("integer size") }
            return .int(product)
        }
        if let product = try exact(a, b, { n1, d1, n2, d2 in
            let (n, o1) = n1.multipliedReportingOverflow(by: n2)
            let (d, o2) = d1.multipliedReportingOverflow(by: d2)
            return (n, d, o1 || o2)
        }) { return product }
        let (m1, e1) = try parts(a)
        let (m2, e2) = try parts(b)
        let (product, overflow) = m1.multipliedReportingOverflow(by: m2)
        if overflow { throw Unsupported("number size") }
        return try makeFloat(product, e1 + e2)
    }

    static func divide(_ a: Value, _ b: Value, fractions: Bool = false) throws -> Value {
        // `math-div-by-zero` leaves the quotient alone.
        if isSymbolic(a, b) || (isZero(b) && (try? sign(a)) != nil) {
            return try $fractions.withValue(fractions) { value(try Symbolic.div(try term(a), try term(b))) }
        }
        if isNaN(a, b) { return .nan }
        if fractions || { if case .frac = a { return true }; if case .frac = b { return true }; return false }(),
           let (n1, d1) = rational(a), let (n2, d2) = rational(b) {
            guard n2 != 0 else { throw Unsupported("division by zero") }
            let (n, o1) = n1.multipliedReportingOverflow(by: d2)
            let (d, o2) = d1.multipliedReportingOverflow(by: n2)
            if o1 || o2 { throw Unsupported("integer size") }
            return try fraction(n, d)
        }
        if case .int(let x) = a, case .int(let y) = b {
            guard y != 0 else { throw Unsupported("division by zero") }
            if x % y == 0 { return .int(x / y) }
        }
        let (m1, e1) = try parts(a)
        let (m2, e2) = try parts(b)
        guard m2 != 0 else { throw Unsupported("division by zero") }
        // `math-div-float`: scale so the truncated quotient has one digit more than needed.
        let ldiff = max(precision + 1 - (digits(m1) - digits(m2)), 0)
        let quotient = (try scaleRounding(m1, ldiff)) / m2
        return try makeFloat(quotient, e1 - ldiff - e2)
    }

    static func isInteger(_ v: Value) -> Bool {
        if case .int = v { return true }
        return false
    }

    /// `math-ipow`.
    static func integerPower(_ a: Value, _ n: Int, fractions: Bool = false) throws -> Value {
        if n < 0 { return try integerPower(try divide(.int(1), a, fractions: fractions), -n) }
        if n == 0 { return .int(1) }
        if n == 1 { return a }
        let square = try multiply(a, a)
        if n % 2 == 0 { return try integerPower(square, n / 2) }
        return try multiply(a, try integerPower(square, n / 2))
    }

    /// `math-pow` of real numbers.
    static func power(_ a: Value, _ b: Value, fractions: Bool = false) throws -> Value {
        // In symbolic mode Calc keeps a power that isn't exact, which isn't reproduced.
        if symbolicMode, !isInteger(b) { throw Unsupported("symbolic mode") }
        if isSymbolic(a, b) { return try $fractions.withValue(fractions) { value(try Symbolic.pow(try term(a), try term(b))) } }
        if isNaN(a, b) { return .nan }
        _ = (try sign(a), try sign(b))
        var floatB = false
        if case .float = b { floatB = true }
        if isZero(a) {
            // `math-pow-of-zero`: an indeterminate form, or a division by zero, stays alone.
            if b == .int(0) { return .int(1) }
            guard try sign(b) > 0 else { throw Rejected() }
            return floatB ? try float(a) : a
        }
        if a == .int(1) || b == .int(1) || a == .float(1, 0) || b == .float(1, 0) { return a }
        if isZero(b) {
            if case .float = a { return .float(1, 0) }
            return floatB ? .float(1, 0) : .int(1)
        }
        if case .int(let n) = b {
            if a == .float(1, 1) { return try makeFloat(1, n) }
            return try extra(2) { try integerPower(a, n, fractions: fractions) }
        }
        // `math-pow-fancy`.
        if let q = quarter(b), (1...3).contains(q) {
            let root = try squareRoot(floatB ? try float(a) : a)
            return try power(root, try multiply(.int(2), b), fractions: fractions)
        }
        if case .frac(let num, let den) = b, den <= 10, try sign(a) > 0 {
            return try integerPower(try nthRoot(a, den), num, fractions: fractions)
        }
        if a == .int(10) || a == .float(1, 1), isWhole(b) { return try makeFloat(1, try trunc(b)) }
        guard try sign(a) > 0 else { throw Unsupported("complex result") }
        return try extra(2) { try expRaw(try float(try multiply(b, try lnRaw(try float(a))))) }
    }

    /// `math-quarter-integer`: 0 for an integer, 1 to 3 for a number of quarters, else nil.
    static func quarter(_ x: Value) -> Int? {
        switch x {
        case .int: return 0
        case .frac(let n, let d):
            if n < 0 { return quarter(.frac(-n, d)).map { 4 - $0 } }
            return d == 2 ? 2 : d == 4 ? n % 4 : nil
        case .float(let m, let e):
            if m < 0 { return quarter(.float(-m, e)).map { 4 - $0 } }
            if e >= 0 { return 0 }
            if e == -1 { return m % 10 == 5 ? 2 : nil }
            if e == -2 { return m % 100 == 25 ? 1 : m % 100 == 75 ? 3 : nil }
            return nil
        default: return nil
        }
    }

    static func compare(_ a: Value, _ b: Value) throws -> Int {
        if case .date(let x) = a, case .date(let y) = b { return try compare(x, y) }
        if a == .nan || b == .nan { throw Unsupported("comparison with nan") }
        let difference = try add(a, try negate(b))
        let (m, _) = try parts(difference)
        return m == 0 ? 0 : (m < 0 ? -1 : 1)
    }

    static func absolute(_ v: Value) throws -> Value { try sign(v) < 0 ? try negate(v) : v }

    /// `math-floor` of a real number, as an integer.
    static func floorInt(_ v: Value) throws -> Int {
        let t = try trunc(v)
        return try sign(v) < 0 && compare(v, .int(t)) != 0 ? t - 1 : t
    }

    // MARK: - Roots, logarithms and rounding

    /// `math-sqrt` of a real number.
    static func squareRoot(_ a: Value) throws -> Value {
        if isZero(a) { return a }
        guard try sign(a) > 0 else { throw Unsupported("complex result") }
        func exact(_ i: Int) -> Int? {
            let guess = Int(Double(i).squareRoot())
            return [guess - 1, guess, guess + 1].first { $0 >= 0 && $0.multipliedReportingOverflow(by: $0) == (i, false) }
        }
        if case .int(let i) = a, let root = exact(i) { return .int(root) }
        if case .frac(let n, let d) = a, let rn = exact(n), let rd = exact(d) { return .frac(rn, rd) }
        let x = try float(a)
        return try extra(1) { try squareRootRaw(x) }
    }

    /// `math-sqrt-raw` of a float.
    static func squareRootRaw(_ a: Value) throws -> Value {
        if isZero(a) { return a }
        guard try sign(a) > 0 else { throw Unsupported("complex result") }
        return try emacs({ $0.squareRoot() }, a)
    }

    /// `math-exp-raw` of a float.
    static func expRaw(_ x: Value) throws -> Value {
        isZero(x) ? .float(1, 0) : try emacs({ Foundation.exp($0) }, x)
    }

    /// `math-ln-raw` of a float.
    static func lnRaw(_ x: Value) throws -> Value {
        if x == .float(1, 0) { return .float(0, 0) }
        guard try sign(x) > 0 else { throw Unsupported("logarithm domain") }
        return try emacs({ Foundation.log($0) }, x)
    }

    /// `math-arctan-raw` of a float.
    static func arctanRaw(_ x: Value) throws -> Value {
        if try sign(x) < 0 { return try negate(try arctanRaw(try negate(x))) }
        return isZero(x) ? x : try emacs({ Foundation.atan($0) }, x)
    }

    static func ln2() throws -> Value { try makeFloat(693147180559945309417232121458176568, -36) }
    static func ln10() throws -> Value { try makeFloat(230258509299404568401799145468436421, -35) }

    /// `math-ln-raw-2`: the logarithm of a positive float by Calc's series.
    static func lnRaw2(_ x: Value) throws -> Value {
        if try compare(.float(14, -1), x) < 0 { return try add(try lnRaw2(try multiply(x, .float(5, -1))), try ln2()) }
        let y = try divide(try subtract(x, .float(1, 0)), try add(x, .float(1, 0)))
        let square = try multiply(y, y)
        var (sum, power, n) = (y, y, 3)
        for _ in 0..<10000 {
            power = try multiply(power, square)
            let next = try add(sum, try divide(power, try float(.int(n))))
            if nearlyEqual(sum, next) { return try multiply(sum, .float(2, 0)) }
            (sum, n) = (next, n + 2)
        }
        throw Unsupported("number")
    }

    /// `math-nth-root-integer`: the integer root rounded down, and whether it is exact.
    static func integerRoot(_ a: Int, _ n: Int) throws -> (Bool, Int) {
        let a = Int128(a)
        var guess = try power10((digits(a) + n - 1) / n)
        while true {
            var p: Int128 = 1
            for _ in 0..<(n - 1) {
                let (r, overflow) = p.multipliedReportingOverflow(by: guess)
                if overflow { throw Unsupported("integer size") }
                p = r
            }
            let (q, r) = a.quotientAndRemainder(dividingBy: p)
            let (g2, r2) = (q + Int128(n - 1) * guess).quotientAndRemainder(dividingBy: Int128(n))
            if g2 < guess {
                guess = g2
                continue
            }
            return (g2 == guess && r == 0 && r2 == 0, Int(guess))
        }
    }

    /// `math-nth-root-float`: Newton's method at one digit more.
    static func floatRoot(_ a: Value, _ n: Int, guess: Value? = nil) throws -> Value {
        try extra(1) {
            guard case .float(let m, let e) = a else { throw Unsupported("arguments") }
            let nf = try makeFloat(Int128(n), 0)
            let nfm1 = try makeFloat(Int128(n - 1), 0)
            var g = try guess ?? makeFloat(1, (digits(Int128(m)) + e + n / 2) / n)
            for _ in 0..<1000 {
                let g2 = try divide(try add(try multiply(nfm1, g), try divide(a, try integerPower(g, n - 1))), nf)
                if nearlyEqual(g2, g) { return g2 }
                g = g2
            }
            throw Unsupported("number")
        }
    }

    /// `math-nth-root` of a positive real number.
    static func nthRoot(_ a: Value, _ n: Int) throws -> Value {
        switch a {
        case .int(let i):
            let (exact, root) = try integerRoot(i, n)
            return exact ? .int(root) : try floatRoot(try float(a), n, guess: try float(.int(root)))
        case .frac(let num, let den):
            let (e1, r1) = try integerRoot(num, n)
            let (e2, r2) = try integerRoot(den, n)
            if e1 && e2 { return .frac(r1, r2) }
            return try floatRoot(try float(a), n, guess: try divide(try float(.int(r1)), try float(.int(r2))))
        default:
            return try floatRoot(a, n)
        }
    }

    /// `math-pow` of a real number to the power `1:n`.
    static func rootPower(_ a: Value, _ n: Int) throws -> Value {
        if isZero(a) || a == .int(1) || a == .float(1, 0) { return a }
        guard try sign(a) > 0 else { throw Unsupported("complex result") }
        switch n {
        case 1: return a
        case 2: return try squareRoot(a)
        case 4: return try squareRoot(try squareRoot(a))
        case 3...10: return try nthRoot(a, n)
        default: return try extra(2) { try expRaw(try float(try multiply(.frac(1, n), try lnRaw(try float(a))))) }
        }
    }

    /// `math-integer-log`: the largest n with b^n at most x, and whether b^n is x.
    static func integerLog(_ x: Value, _ b: Value) throws -> (Bool, Int) {
        var pows = [b]
        var pow = try multiply(b, b)
        while try compare(x, pow) >= 0 {
            pows.insert(pow, at: 0)
            pow = try multiply(pow, pow)
        }
        var n = 1 << (pows.count - 1)
        var sum = n
        pow = pows[0]
        var rest = pows.dropFirst()
        while let next = rest.first, try compare(pow, x) < 0 {
            rest = rest.dropFirst()
            n /= 2
            let candidate = try multiply(pow, next)
            if try compare(x, candidate) >= 0 {
                pow = candidate
                sum += n
            }
        }
        return (pow == x, sum)
    }

    /// `math-round` in `math-rounding-mode` `even` or `up`.
    static func round(_ a: Value, even: Bool) throws -> Value {
        if isWhole(a) { return .int(try trunc(a)) }
        if try sign(a) < 0, even { return try negate(try round(try negate(a), even: even)) }
        let b = try add(a, rational(a) != nil ? .frac(1, 2) : .float(5, -1))
        var f = try floorInt(b)
        if even, isWhole(b), f % 2 != 0 { f -= 1 }
        return .int(f)
    }

    /// `calcFunc-scf`: `x` times 10^n.
    static func scale(_ x: Value, _ n: Int, fractions: Bool) throws -> Value {
        if n == 0 { return x }
        guard abs(n) <= 18 else { throw Unsupported("number size") }
        let p = Int(try power10(abs(n)))
        switch x {
        case .int: return n > 0 ? try multiply(x, .int(p)) : try divide(x, .int(p), fractions: fractions)
        case .frac(let a, let b):
            let (num, o1) = a.multipliedReportingOverflow(by: n > 0 ? p : 1)
            let (den, o2) = b.multipliedReportingOverflow(by: n > 0 ? 1 : p)
            if o1 || o2 { throw Unsupported("integer size") }
            return try fraction(num, den)
        case .float(let m, let e): return try makeFloat(Int128(m), e + n)
        default: throw Unsupported("arguments")
        }
    }

    /// `calcFunc-frac`: the fraction closest to a float within its precision.
    static func toFraction(_ a: Value) throws -> Value {
        if rational(a) != nil { return a }
        if isWhole(a) { return .int(try trunc(a)) }
        if try sign(a) < 0 { return try negate(try toFraction(try negate(a))) }
        guard case .float(let m, let e) = a else { throw Unsupported("arguments") }
        let tolerance = Value.float(5, digits(Int128(m)) + e - (1 + precision))
        /// `math-eval-continued-fraction`.
        func evaluate(_ terms: [Int], fractions: Bool) throws -> Value {
            var n = Value.int(terms.last!)
            var d = Value.int(1)
            for c in terms.reversed().dropFirst() { (n, d) = (try add(try multiply(.int(c), n), d), n) }
            return try divide(n, d, fractions: fractions)
        }
        let terms = try $precision.withValue(precision + 2) {
            var terms: [Int] = []
            var aa = a
            while try terms.isEmpty || (!isZero(aa) && compare(try absolute(try subtract(a, try evaluate(terms, fractions: false))), tolerance) >= 0) {
                guard terms.count < 100 else { throw Unsupported("number") }
                let whole = try trunc(aa)
                aa = try subtract(aa, .int(whole))
                terms.append(whole)
                if !isZero(aa) { aa = try divide(.int(1), aa) }
            }
            return terms
        }
        return try evaluate(terms, fractions: true)
    }

    /// `calcFunc-gcd`.
    static func gcd(_ a: Value, _ b: Value) throws -> Value {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }
        let a = isWhole(a) ? .int(try trunc(a)) : a
        let b = isWhole(b) ? .int(try trunc(b)) : b
        if case .int(let x) = a, case .int(let y) = b {
            guard x != .min, y != .min else { throw Unsupported("integer size") }
            return .int(gcd(x, y))
        }
        if try sign(a) < 0 { return try Calc.gcd(try negate(a), b) }
        if try sign(b) < 0 { return try Calc.gcd(a, try negate(b)) }
        guard let (n1, d1) = rational(a), let (n2, d2) = rational(b) else { throw Unsupported("arguments") }
        guard case .int(let g) = try Calc.gcd(.int(d1), .int(d2)) else { throw Unsupported("arguments") }
        let (product, overflow) = d1.multipliedReportingOverflow(by: d2 / g)
        if overflow { throw Unsupported("integer size") }
        return try fraction(gcd(n1, n2), product)
    }

    /// `calcFunc-choose` of integers.
    static func choose(_ n: Int, _ m: Int) throws -> Int {
        if m >= 0, m <= n {
            var c = 1
            var top = n
            for i in stride(from: 1, through: m > n / 2 ? n - m : m, by: 1) {
                let (product, overflow) = c.multipliedReportingOverflow(by: top)
                if overflow { throw Unsupported("integer size") }
                c = product / i
                top -= 1
            }
            return c
        }
        if n < 0, m >= 0 {
            let v = try choose(m - n - 1, m)
            return m % 2 == 0 ? v : -v
        }
        if n < 0 {
            if n < m { return 0 }
            let v = try choose(-m - 1, n - m)
            return (n - m) % 2 == 0 ? v : -v
        }
        return 0
    }

    // MARK: - Display

    /// `math-format-number`.
    static func format(_ value: Value, _ floatFormat: FloatFormat) throws -> String {
        switch value {
        case .int(let i): return String(i)
        case .frac(let n, let d): return "\(n):\(d)"
        case .vector: throw Unsupported("vector result")
        case .symbolic(let t): return try Symbolic.format(t, floatFormat)
        case .nan: return "nan"
        case .date(let d): return "<" + (try formatDate(d)) + ">"
        case .float(let m, _) where m < 0:
            guard case .float(let m, let e) = value else { fatalError() }
            return "-" + (try format(.float(-m, e), floatFormat))
        case .float(let m, var exp):
            var mant = Int128(m)
            var figs: Int
            let kind: String
            switch floatFormat {
            case .float(let n): (figs, kind) = (n, "float")
            case .fix(let n): (figs, kind) = (n, "fix")
            case .sci(let n): (figs, kind) = (n, "sci")
            case .eng(let n): (figs, kind) = (n, "eng")
            }
            if kind == "fix", figs < 0 || exp + digits(mant) > -figs {
                if figs < 0 { figs = -figs }
                mant = try scaleRounding(mant, exp + figs)
                var str = String(mant)
                if str.count <= figs { str = String(repeating: "0", count: figs + 1 - str.count) + str }
                if figs > 0 {
                    return String(str.dropLast(figs)) + "." + String(str.suffix(figs))
                }
                return str + "."
            }
            if figs < 0 { figs += precision }
            if figs > 0 {
                let adj = figs - digits(mant)
                if adj < 0 {
                    mant = try scaleRounding(mant, adj)
                    exp -= adj
                }
            }
            var str = String(mant)
            let len = str.count
            let dpos = exp + len
            // `calc-display-sci-high` 0, `calc-display-sci-low` -3.
            if kind == "float", dpos <= precision, dpos >= -1 {
                if dpos == 0 {
                    str = "0." + str
                } else if exp <= 0, dpos > 0 {
                    str = String(str.prefix(dpos)) + "." + String(str.dropFirst(dpos))
                } else if exp > 0 {
                    str += String(repeating: "0", count: exp) + "."
                } else {
                    str = "0." + String(repeating: "0", count: -dpos) + str
                }
                return str
            }
            let eadj = exp + len
            let scale = kind == "eng" ? 1 + ((eadj + 300002) % 3) : 1
            if scale > str.count { str += String(repeating: "0", count: scale - str.count) }
            if scale < str.count { str = String(str.prefix(scale)) + "." + String(str.dropFirst(scale)) }
            return str + "e" + String(eadj - scale)
        }
    }

    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// `calc-date-format` as Org sets it: `YYYY-MM-DD Www`, then ` hh:mm` for a day number
    /// that isn't an integer.
    static func formatDate(_ value: Value) throws -> String {
        let dt = try dateParts(value)
        let year = dt.year > 0 && dt.year < 100 ? "+\(dt.year)" : String(dt.year)
        var text = year + String(format: "-%02d-%02d ", dt.month, dt.day) + weekdays[Days.weekday(try floorInt(value))]
        if let time = dt.time { text += String(format: " %02d:%02d", time.hour, time.minute) }
        return text
    }

    /// A date form `<YYYY-MM-DD Www>` or `<YYYY-MM-DD Www hh:mm>`, from the text between
    /// the brackets.
    static func parseDate(_ text: String) throws -> Value {
        guard let m = text.firstMatch(of: /^([0-9]{4})-([0-9]{2})-([0-9]{2})(?: +[A-Za-z]+)?(?: +([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?)?$/) else {
            throw Unsupported("date syntax")
        }
        // `math-parse-date-validate`: a year under 100 is 19xx or 20xx.
        var year = Int(m.1)!
        if year < 100 { year += year < 40 ? 2000 : 1900 }
        let day = Days.absolute(year: year, month: Int(m.2)!, day: Int(m.3)!)
        guard let hour = m.4.flatMap({ Int($0) }), let minute = m.5.flatMap({ Int($0) }) else { return .date(.int(day)) }
        return try dateTime(day, hour * 3600 + minute * 60 + (m.6.flatMap { Int($0) } ?? 0))
    }

    // MARK: - Dates

    /// Calc numbers years without a year 0: -1 comes before 1.
    static func astronomical(_ year: Int) -> Int { year > 0 ? year : year == 0 ? 0 : year + 1 }

    /// `math-absolute-from-gregorian-dt`.
    static func absolute(_ year: Int, _ month: Int, _ day: Int) throws -> Int {
        guard abs(year) < 1_000_000_000 else { throw Unsupported("number size") }
        return Days.absolute(year: astronomical(year), month: month, day: day)
    }

    /// `math-days-in-month`.
    static func daysInMonth(_ year: Int, _ month: Int) throws -> Int {
        try absolute(year, month + 1, 1) - absolute(year, month, 1)
    }

    /// `math-dt-to-date` with a time of day: a float day number.
    static func dateTime(_ day: Int, _ seconds: Int) throws -> Value {
        .date(try add(try float(.int(day)), try divide(.int(seconds), .float(864, 2))))
    }

    /// `math-dt-to-date`.
    static func dateValue(_ year: Int, _ month: Int, _ day: Int, _ time: (hour: Int, minute: Int, second: Int)? = nil) throws -> Value {
        guard (1...12).contains(month), (1...31).contains(day) else { throw Unsupported("arguments") }
        let n = try absolute(year, month, day)
        guard let time else { return .date(.int(n)) }
        guard [time.hour, time.minute, time.second].allSatisfy({ abs($0) < 1_000_000 }) else { throw Unsupported("arguments") }
        return try dateTime(n, time.hour * 3600 + time.minute * 60 + time.second)
    }

    /// The day number of a date form, or a real number, which Calc's date functions also take.
    static func dayNumber(_ v: Value) throws -> Value {
        let x: Value = if case .date(let d) = v { d } else { v }
        _ = try sign(x)
        return x
    }

    /// `math-date-to-dt`: the day, with the time of day when the day number isn't an integer.
    static func dateParts(_ v: Value) throws -> (year: Int, month: Int, day: Int, time: (hour: Int, minute: Int, second: Int)?) {
        let x = try dayNumber(v)
        let day = try floorInt(x)
        guard abs(day) < 100_000_000_000 else { throw Unsupported("number size") }
        let date = Days.date(day)
        let year = date.year > 0 ? date.year : date.year - 1
        if case .int = x { return (year, date.month, date.day, nil) }
        // Above 12 digits Calc keeps fractions of a second.
        guard precision <= 12 else { throw Unsupported("calc precision") }
        let seconds = try trunc(try round(try multiply(try subtract(x, .int(day)), .int(86400)), even: false))
        return (year, date.month, date.day, (seconds / 3600, seconds / 60 % 60, seconds % 60))
    }

    /// `math-to-business-day`, with Calc's default holidays: Saturdays and Sundays.
    static func toBusinessDay(_ v: Value) throws -> (Value, holiday: Bool) {
        let x = try dayNumber(v)
        let day = try floorInt(x)
        try checkHolidayRange(day)
        let weekday = Days.weekday(day)
        let delta = day / 7 * 2 + (weekday > 0 ? 1 : 0)
        return (try add(.int(day - delta), try subtract(x, .int(day))), weekday == 0 || weekday == 6)
    }

    /// `math-setup-holidays` with a date: Calc's holidays cover the years 1 to 2737.
    static func checkHolidayRange(_ day: Int) throws {
        guard (try absolute(1, 1, 1)...absolute(2737, 12, 31)).contains(day) else { throw Unsupported("arguments") }
    }

    /// `math-from-business-day`.
    static func fromBusinessDay(_ n: Value) throws -> Value {
        var day = try floorInt(n)
        let time = try subtract(n, .int(day))
        var left = ((day % 5) + 5) % 5
        day += day / 5 * 2
        var weekday = 0
        while true {
            if weekday == 0 || weekday == 6 {
                day += 1
            } else {
                left -= 1
                if left < 0 { break }
            }
            weekday += 1
        }
        try checkHolidayRange(day)
        return .date(try add(.int(day), time))
    }

    /// `calcFunc-tzone` for the local zone, in seconds. Calc applies the current year's
    /// daylight saving rules to every date, which isn't reproduced, so only zones without
    /// daylight saving time are supported.
    static func zoneOffset(_ zone: TimeZone) throws -> Int {
        guard !zone.isDaylightSavingTime(), zone.nextDaylightSavingTimeTransition == nil else {
            throw Unsupported("daylight saving time")
        }
        return -zone.secondsFromGMT()
    }

    // MARK: - Parsing

    indirect enum Node {
        case number(Value)
        case vector([Node])
        case unary(Character, Node)
        case binary(Character, Node, Node)
        case call(String, [Node])
        case variable(String)

        /// Whether the formula has a quotient, a power, a function call, or a product
        /// whose factors share a variable, which Calc simplifies to a power.
        var mayExplain: Bool {
            switch self {
            case .number, .variable: false
            case .call: true
            case .vector(let items): items.contains { $0.mayExplain }
            case .unary(_, let a): a.mayExplain
            case .binary("*", let a, let b) where !a.variables.isDisjoint(with: b.variables): true
            case .binary(let op, let a, let b): "/%\\^".contains(op) || a.mayExplain || b.mayExplain
            }
        }

        var variables: Set<String> {
            switch self {
            case .number: []
            case .variable(let name): [name]
            case .call(_, let items), .vector(let items): items.reduce(into: []) { $0.formUnion($1.variables) }
            case .unary(_, let a): a.variables
            case .binary(_, let a, let b): a.variables.union(b.variables)
            }
        }
    }

    struct Parser {
        let chars: [Character]
        var i = 0
        /// Inside `[...]`, where Calc reads `x -1` as two elements.
        var inVector = false
        /// Inside `[...]` with no comma, where Calc reads `1 2` as two elements.
        var spaceSeparated = false

        init(_ s: String) { chars = Array(s) }

        mutating func skip() {
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        }

        mutating func peek() -> Character? {
            skip()
            return i < chars.count ? chars[i] : nil
        }

        mutating func parse() throws -> Node {
            let node = try or()
            guard peek() == nil else { throw Unsupported("formula syntax") }
            return node
        }

        mutating func take(_ token: String) -> Bool {
            guard peek() != nil else { return false }
            let t = Array(token)
            guard i + t.count <= chars.count, Array(chars[i..<(i + t.count)]) == t else { return false }
            i += t.count
            return true
        }

        // `||` < `&&` < `!` < comparisons < sums.
        mutating func or() throws -> Node {
            var left = try and()
            while take("||") { left = .binary("|", left, try and()) }
            return left
        }

        mutating func and() throws -> Node {
            var left = try not()
            while take("&&") { left = .binary("&", left, try not()) }
            return left
        }

        mutating func not() throws -> Node {
            if peek() == "!", i + 1 >= chars.count || chars[i + 1] != "=" {
                i += 1
                return .unary("!", try not())
            }
            return try comparison()
        }

        mutating func comparison() throws -> Node {
            let left = try sum()
            // Calc reads `<<` and `>>` as one token, so `1<<2026-10-05 Mon>` is a syntax error.
            if take("<<") || take(">>") { throw Unsupported("formula syntax") }
            for (token, op) in [("==", "="), ("!=", "≠"), ("<=", "≤"), (">=", "≥"), ("<", "<"), (">", ">")] where take(token) {
                let right = try sum()
                if let next = peek(), "=!<>".contains(next) { throw Unsupported("chained comparison") }
                return .binary(Character(op), left, right)
            }
            return left
        }

        // `+ -` < `/` < `*` < unary minus < `^`, as Calc's operator table orders them.
        mutating func sum() throws -> Node {
            var left = try quotient()
            while let c = peek(), c == "+" || c == "-" {
                if inVector, i > 0, chars[i - 1] == " " || chars[i - 1] == "\t", i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != "\t" {
                    throw Unsupported("formula syntax")
                }
                i += 1
                left = .binary(c, left, try quotient())
            }
            return left
        }

        mutating func quotient() throws -> Node {
            var left = try product()
            while let c = peek(), c == "/" || c == "%" || c == "\\" {
                i += 1
                left = .binary(c, left, try product())
            }
            return left
        }

        /// `*`, and juxtaposition `2 3` or `2 (x)`, which Calc reads as `*`.
        mutating func product() throws -> Node {
            var left = try unary()
            while let c = peek() {
                if c == "*" {
                    i += 1
                } else if !(c.isASCII && c.isNumber) && !c.isLetter && c != "(" && c != "["
                            && !(c == "." && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber) {
                    break
                } else if spaceSeparated, chars[i - 1] == " " || chars[i - 1] == "\t" {
                    // Calc reads `[1 2]` as two elements and `[1 2 * 3]` as one; not reproduced.
                    throw Unsupported("formula syntax")
                }
                left = .binary("*", left, try unary())
            }
            return left
        }

        /// `math-factor-after`: whether what follows can start an operand, which makes `%`
        /// the modulo operator rather than percent.
        func factorAfter(_ j: Int) -> Bool {
            var j = j
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            guard j < chars.count else { return false }
            let c = chars[j]
            if c == ".", j + 1 < chars.count { return chars[j + 1].isASCII && chars[j + 1].isNumber }
            return (c.isASCII && c.isNumber) || c.isLetter || "$#\"-+!([{".contains(c)
        }

        mutating func unary() throws -> Node {
            if let c = peek(), c == "-" || c == "+" {
                i += 1
                let operand = try unary()
                return c == "-" ? .unary("-", operand) : operand
            }
            return try powerNode()
        }

        mutating func powerNode() throws -> Node {
            var base = try primary()
            // Postfix `%` (percent), `!` and `!!`, which bind tighter than `^`.
            while let c = peek() {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if c == "%", !factorAfter(i + 1) {
                    // `%%` starts a comment.
                    if next == "%" { throw Unsupported("formula syntax") }
                    i += 1
                    base = .call("percent", [base])
                } else if c == "!", next != "=" {
                    if next == "!" {
                        if i + 2 < chars.count, chars[i + 2] == "!" { throw Unsupported("formula syntax") }
                        i += 2
                        base = .call("dfact", [base])
                    } else {
                        i += 1
                        base = .call("fact", [base])
                    }
                } else {
                    break
                }
            }
            if peek() == "^" {
                i += 1
                return .binary("^", base, try unary())
            }
            return base
        }

        mutating func primary() throws -> Node {
            guard let c = peek() else { throw Unsupported("formula syntax") }
            if c == "(" {
                i += 1
                let outer = (inVector, spaceSeparated)
                (inVector, spaceSeparated) = (false, false)
                let inner = try or()
                (inVector, spaceSeparated) = outer
                guard peek() == ")" else { throw Unsupported("formula syntax") }
                i += 1
                return inner
            }
            if c == "[" {
                i += 1
                let outer = (inVector, spaceSeparated)
                (inVector, spaceSeparated) = (true, !hasComma())
                defer { (inVector, spaceSeparated) = outer }
                var items: [Node] = []
                if peek() != "]" {
                    items.append(try or())
                    while peek() == "," {
                        i += 1
                        items.append(try or())
                    }
                }
                guard peek() == "]" else { throw Unsupported("formula syntax") }
                i += 1
                return .vector(items)
            }
            if c.isASCII, c.isNumber || c == "." { return .number(try number()) }
            if c == "<" {
                guard let close = chars[i...].firstIndex(of: ">") else { throw Unsupported("formula syntax") }
                let text = String(chars[(i + 1)..<close])
                i = close + 1
                return .number(try parseDate(text))
            }
            if c.isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    name.append(chars[i])
                    i += 1
                }
                // `[f (x)]` is two elements.
                if spaceSeparated, i < chars.count, chars[i] != "(", peek() == "(" { throw Unsupported("formula syntax") }
                guard peek() == "(" else {
                    if name == "nan" { return .number(.nan) }
                    // Calc's names are letters and digits; `_` is a subscript, and `'` and `#`
                    // belong to the name.
                    guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), !reserved.contains(name),
                          i >= chars.count || !"'#".contains(chars[i]) else { throw Unsupported("variable \(name)") }
                    return .variable(name)
                }
                i += 1
                let outer = (inVector, spaceSeparated)
                (inVector, spaceSeparated) = (false, false)
                defer { (inVector, spaceSeparated) = outer }
                var args: [Node] = []
                if peek() != ")" {
                    args.append(try or())
                    while peek() == "," {
                        i += 1
                        args.append(try or())
                    }
                }
                guard peek() == ")" else { throw Unsupported("formula syntax") }
                i += 1
                return .call(name, args)
            }
            throw Unsupported("formula syntax")
        }

        /// `math-check-for-commas`: whether a comma follows before the bracket that closes.
        func hasComma() -> Bool {
            var depth = 0
            for c in chars[i...] {
                if "[{(".contains(c) { depth += 1 }
                if "]})".contains(c) { depth -= 1 }
                if depth < 0 { return false }
                if c == ",", depth == 0 { return true }
            }
            return false
        }

        /// Calc's number syntax: `7`, `007`, `1.5`, `.5`, `5.`, `1e3`, `1.5e-3`, fractions `1:3`
        /// and `1:2:3`, and integers in a radix, `16#FF`.
        mutating func number() throws -> Value {
            var whole = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                whole.append(chars[i])
                i += 1
            }
            if !whole.isEmpty, i + 1 < chars.count, chars[i] == ":", chars[i + 1].isASCII, chars[i + 1].isNumber {
                var text = whole
                while i < chars.count, chars[i] == ":" || (chars[i].isASCII && chars[i].isNumber) {
                    text.append(chars[i])
                    i += 1
                }
                let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
                guard parts.count <= 3, !parts.contains(nil) else { throw Unsupported("formula syntax") }
                let n = parts.map { $0! }
                guard n.last != 0 else { throw Unsupported("formula syntax") }
                if n.count == 2 { return try fraction(n[0], n[1]) }
                let (product, o1) = n[0].multipliedReportingOverflow(by: n[2])
                let (sum, o2) = product.addingReportingOverflow(n[1])
                if o1 || o2 { throw Unsupported("integer size") }
                return try fraction(sum, n[2])
            }
            if !whole.isEmpty, i < chars.count, chars[i] == "#" {
                i += 1
                var text = ""
                while i < chars.count, chars[i].isASCII, chars[i].isLetter || chars[i].isNumber || chars[i] == "." || chars[i] == ":" || chars[i] == "#" {
                    text.append(chars[i])
                    i += 1
                }
                guard let radix = Int(whole), (2...36).contains(radix), !text.isEmpty,
                      let value = Int(text, radix: radix) else { throw Unsupported("formula syntax") }
                return .int(value)
            }
            var fraction: String?
            // `2..5` is an interval, not `2.` then `.5`.
            if i < chars.count, chars[i] == ".", i + 1 >= chars.count || chars[i + 1] != "." {
                i += 1
                var f = ""
                while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                    f.append(chars[i])
                    i += 1
                }
                fraction = f
                // Calc reads digits and points as one number: `21.11.2026` is a bad format.
                if i < chars.count, chars[i] == ".", i + 1 >= chars.count || chars[i + 1] != "." {
                    while i < chars.count, (chars[i].isASCII && chars[i].isNumber)
                            || (chars[i] == "." && (i + 1 >= chars.count || chars[i + 1] != ".")) { i += 1 }
                    // The position is in the string Calc reads, after it rewrites `..` and
                    // characters such as `²`; an exponent belongs to the number.
                    let before = String(chars[..<i])
                    guard before.allSatisfy(\.isASCII), !before.contains(".."),
                          i >= chars.count || !"eE".contains(chars[i]) else { throw Unsupported("formula syntax") }
                    throw Failure("Bad format", position: i)
                }
            }
            var exponent: Int?
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                var j = i + 1
                var e = ""
                if j < chars.count, chars[j] == "-" || chars[j] == "+" {
                    e.append(chars[j])
                    j += 1
                }
                var digitsSeen = false
                while j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    e.append(chars[j])
                    j += 1
                    digitsSeen = true
                }
                if digitsSeen {
                    exponent = Int(e)
                    i = j
                }
            }
            guard !whole.isEmpty || !(fraction ?? "").isEmpty else { throw Unsupported("formula syntax") }
            if fraction == nil, exponent == nil {
                guard let value = Int(whole) else { throw Unsupported("integer size") }
                return .int(value)
            }
            let digitsText = whole + (fraction ?? "")
            guard let mantissa = Int128(digitsText.isEmpty ? "0" : digitsText) else { throw Unsupported("number size") }
            return try makeFloat(mantissa, (exponent ?? 0) - (fraction?.count ?? 0))
        }
    }

    // MARK: - Evaluation

    struct Evaluator {
        let modes: Modes

        func eval(_ node: Node) throws -> Value {
            switch node {
            case .number(let v): return v
            case .vector(let items): return .vector(try items.map(eval))
            case .unary("!", let operand): return .int(try truth(try eval(operand)) ? 0 : 1)
            case .unary(_, let operand):
                let a = try eval(operand)
                do { return try negate(a) } catch is Rejected { return .symbolic(.op("neg", [try term(a)])) }
            case .binary(let op, let l, let r):
                let (a, b) = (try eval(l), try eval(r))
                do {
                    return try binary(op, a, b)
                } catch is Rejected {
                    // `math-normalize` keeps the operation, its arguments evaluated.
                    guard let name = ["+": "+", "-": "-", "*": "*", "/": "/", "^": "^"][op] else { throw Unsupported("division by zero") }
                    return .symbolic(.op(name, [try term(a), try term(b)]))
                }
            case .call(let name, let args):
                let values = try args.map(eval)
                // In symbolic mode Calc keeps these unevaluated when the result isn't exact,
                // which isn't reproduced.
                if modes.symbolic, Self.inexact.contains(name) || (!modes.degrees && ["sin", "cos", "tan"].contains(name)) {
                    throw Unsupported("function \(name) in symbolic mode")
                }
                if values.contains(where: Self.hasSymbol) {
                    // Calc leaves most functions of a formula alone, and simplifies some.
                    guard ["vsum", "vprod", "vmean", "vcount"].contains(name),
                          values.allSatisfy({ if case .vector = $0 { true } else { !Self.hasSymbol($0) } }) else {
                        throw Unsupported("function \(name) of a formula")
                    }
                }
                do {
                    return try call(name, values)
                } catch is Rejected {
                    throw Unsupported("division by zero")
                }
            case .variable(let name):
                return .symbolic(.variable(name))
            }
        }

        static let inexact: Set<String> = ["sqrt", "exp", "ln", "log10", "log", "vsdev", "vpsdev", "vgmean", "vhmean", "vcorr",
                                           "vcov", "vpcov", "agmean", "pow", "nroot", "hypot", "sinh", "cosh", "tanh", "arcsinh",
                                           "arccosh", "arctanh", "arcsin", "arccos", "arctan", "arctan2", "fact", "dfact"]

        static func hasSymbol(_ v: Value) -> Bool {
            switch v {
            case .symbolic: true
            case .vector(let items): items.contains(where: hasSymbol)
            default: false
            }
        }

        func binary(_ op: Character, _ a: Value, _ b: Value) throws -> Value {
            switch op {
            case "+": return try add(a, b)
            case "-": return try subtract(a, b)
            case "*": return try multiply(a, b)
            case "/": return try divide(a, b, fractions: modes.preferFractions)
            case "%": return try mod(a, b)
            case "\\": return try idiv(a, b)
            case "^": return try power(a, b, fractions: modes.preferFractions)
            // `calcFunc-lor` and `calcFunc-land` give one of their arguments.
            case "|": return try truth(a) ? a : b
            case "&": return try truth(a) ? b : a
            default:
                let order = try compare(a, b)
                let holds = switch op {
                case "=": order == 0
                case "≠": order != 0
                case "<": order < 0
                case ">": order > 0
                case "≤": order <= 0
                default: order >= 0
                }
                return .int(holds ? 1 : 0)
            }
        }

        /// A condition's value: a number, nonzero for true.
        func truth(_ v: Value) throws -> Bool {
            switch v {
            case .int(let i): return i != 0
            case .float(let m, _): return m != 0
            case .frac: return true
            default: throw Unsupported("condition")
            }
        }

        /// `math-mod`: the remainder with the divisor's sign.
        func mod(_ a: Value, _ b: Value) throws -> Value {
            if case .int(let x) = a, case .int(let y) = b {
                guard y != 0 else { throw Unsupported("division by zero") }
                let r = x % y
                return .int(r != 0 && (r < 0) != (y < 0) ? r + y : r)
            }
            let q = try floorOf(try divide(a, b))
            return try subtract(a, try multiply(b, q))
        }

        /// `calcFunc-idiv`: the quotient rounded down.
        func idiv(_ a: Value, _ b: Value) throws -> Value {
            if case .int(let x) = a, case .int(let y) = b {
                guard y != 0 else { throw Unsupported("division by zero") }
                let q = x / y
                return .int(q * y != x && (x < 0) != (y < 0) ? q - 1 : q)
            }
            return try floorOf(try divide(a, b))
        }

        func floorOf(_ v: Value) throws -> Value {
            if case .int = v { return v }
            guard let i = Int(exactly: try double(v).rounded(.down)) else { throw Unsupported("integer size") }
            return .int(i)
        }

        /// `math-covariance` of numbers without error forms: the variance of `xs` without `ys`,
        /// with `correlation` the correlation coefficient.
        func covariance(_ xs: [Value], _ ys: [Value]? = nil, population: Bool, correlation: Bool = false) throws -> Value {
            let n = xs.count
            guard n > 0 else { throw Unsupported("empty vector") }
            guard population || n > 1 else { throw Unsupported(ys == nil ? "variance of one value" : "arguments") }
            guard (ys ?? xs).count == n else { throw Unsupported("arguments") }
            return try extra(2) {
                func sum(_ v: [Value]) throws -> Value { try v.dropFirst().reduce(v[0], add) }
                func deviations(_ v: [Value]) throws -> [Value] {
                    let shift = try divide(try sum(v), .int(-n), fractions: modes.preferFractions)
                    return try v.map { try add($0, shift) }
                }
                let dx = try deviations(xs)
                let dy = try ys.map(deviations) ?? dx
                let products = try sum(try zip(dx, dy).map(multiply))
                let divisor = correlation
                    ? try squareRoot(try multiply(try sum(try dx.map { try multiply($0, $0) }), try sum(try dy.map { try multiply($0, $0) })))
                    : .int(population ? n : n - 1)
                return try divide(products, divisor, fractions: modes.preferFractions)
            }
        }

        /// `math-flatten-many-vecs`: the arguments, vectors flattened into their elements.
        func elements(_ args: [Value]) throws -> [Value] {
            var items: [Value] = []
            for arg in args {
                if case .vector(let inner) = arg { items += try elements(inner) } else { items.append(arg) }
            }
            return items
        }

        func one(_ args: [Value]) throws -> Value {
            guard args.count == 1 else { throw Unsupported("arguments") }
            if case .vector = args[0] { throw Unsupported("vector argument") }
            return args[0]
        }

        /// An integer argument, from an integer or a float with an integer value
        /// (`math-messy-integerp`).
        func integer(_ v: Value) throws -> Int {
            guard isWhole(v) else { throw Unsupported("arguments") }
            return try trunc(v)
        }

        /// The local date and time `now()` reads.
        func clock() -> DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = modes.timeZone
            return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modes.now ?? Date())
        }

        func radians(_ x: Double) -> Double { modes.degrees ? x * .pi / 180 : x }
        func angle(_ x: Double) -> Double { modes.degrees ? x * 180 / .pi : x }

        func call(_ name: String, _ args: [Value]) throws -> Value {
            switch name {
            case "vsum":
                return try extra(2) { try elements(args).reduce(Value.int(0)) { try add($0, $1) } }
            case "vprod":
                return try extra(2) { try elements(args).reduce(Value.int(1)) { try multiply($0, $1) } }
            case "vcount":
                return .int(try elements(args).count)
            case "vmean":
                let items = try elements(args)
                guard !items.isEmpty else { throw Unsupported("empty vector") }
                return try extra(2) { try divide(try items.reduce(Value.int(0)) { try add($0, $1) }, .int(items.count), fractions: modes.preferFractions) }
            case "vmax", "vmin":
                // `math-reduce-many-vecs` compares at two digits more.
                let items = try elements(args)
                guard let first = items.first else { throw Unsupported("empty vector") }
                return try extra(2) {
                    var best = first
                    for item in items.dropFirst() {
                        let order = try compare(item, best)
                        if name == "vmax" ? order > 0 : order < 0 { best = item }
                    }
                    return best
                }
            case "vmedian":
                var items = try elements(args)
                guard !items.isEmpty else { throw Unsupported("empty vector") }
                // Calc leaves the median of dates unevaluated.
                if items.contains(where: { if case .date = $0 { true } else { false } }) { throw Unsupported("arguments") }
                try items.sort { try compare($0, $1) < 0 }
                if items.count % 2 == 1 { return items[items.count / 2] }
                return try divide(try add(items[items.count / 2 - 1], items[items.count / 2]), .int(2))
            case "if":
                guard args.count == 3 else { throw Unsupported("arguments") }
                return try truth(args[0]) ? args[1] : args[2]
            case "vvar", "vpvar", "vsdev", "vpsdev":
                let variance = try covariance(try elements(args), population: name == "vpvar" || name == "vpsdev")
                return name.hasSuffix("sdev") ? try squareRoot(variance) : variance
            case "mod":
                guard args.count == 2 else { throw Unsupported("arguments") }
                return try mod(args[0], args[1])
            case "idiv":
                guard args.count == 2 else { throw Unsupported("arguments") }
                return try idiv(args[0], args[1])
            case "fact", "dfact":
                // A float with an integer value gives a float, up to 20.
                let x = try one(args)
                guard isWhole(x), case let n = try trunc(x), n >= 0, x == .int(n) || (name == "fact" && n <= 20) else { throw Unsupported("arguments") }
                var result = Value.int(1)
                for k in stride(from: name == "fact" ? 2 : 2 + n % 2, through: n, by: name == "fact" ? 1 : 2) { result = try multiply(result, .int(k)) }
                return x == .int(n) ? result : try float(result)
            case "max", "min":
                guard !args.isEmpty else { throw Unsupported("arguments") }
                var best = args[0]
                for item in args.dropFirst() {
                    let order = try compare(item, best)
                    if name == "max" ? order > 0 : order < 0 { best = item }
                }
                return best
            case "abs":
                let x = try one(args)
                if case .date(let d) = x {
                    // Calc leaves abs of day number 0 unevaluated.
                    if d == .int(0) { throw Unsupported("date arithmetic") }
                    return .date(try compare(d, .int(0)) < 0 ? try negate(d) : d)
                }
                return try compare(x, .int(0)) < 0 ? try negate(x) : x
            case "floor", "ceil", "trunc":
                if args.count == 1, case .date(let d) = args[0] { return .date(try call(name, [d])) }
                var x = try one(args)
                if case .frac(let n, let d) = x { x = try divide(.int(n), .int(d)) }
                if case .int = x { return x }
                let d = try double(x)
                let r = name == "floor" ? d.rounded(.down) : name == "ceil" ? d.rounded(.up) : d.rounded(.towardZero)
                guard let i = Int(exactly: r) else { throw Unsupported("integer size") }
                return .int(i)
            case "round":
                guard args.count == 1 || args.count == 2 else { throw Unsupported("arguments") }
                if case .date(let d) = args[0] {
                    guard args.count == 1 else { throw Unsupported("arguments") }
                    return .date(try call(name, [d]))
                }
                var x = args[0]
                if case .frac(let n, let d) = x { x = try divide(.int(n), .int(d)) }
                if args.count == 2 {
                    guard case .int(let places) = args[1] else { throw Unsupported("arguments") }
                    guard case .float(let m, let e) = x else { return x }
                    return try makeFloat(try scaleRounding(Int128(m), e + places), -places)
                }
                guard case .float(let m, let e) = x else { return x }
                guard let i = Int(exactly: try scaleRounding(Int128(m), e)) else { throw Unsupported("integer size") }
                return .int(i)
            case "sqrt":
                return try squareRoot(try one(args))
            case "exp":
                let x = try one(args)
                if x == .int(0) { return .int(1) }
                return try extra(2) { try expRaw(try float(x)) }
            case "ln":
                let x = try one(args)
                if x == .int(1) { return .int(0) }
                guard try sign(x) > 0 else { throw Unsupported("logarithm domain") }
                return try extra(2) { try lnRaw(try float(x)) }
            case "log10":
                let x = try one(args)
                if case .int(let i) = x, i > 0 {
                    var n = i
                    var k = 0
                    while n % 10 == 0 {
                        n /= 10
                        k += 1
                    }
                    if n == 1 { return .int(k) }
                }
                if case .frac(1, let d) = x, case (true, let k) = try integerLog(.int(d), .int(10)) { return .int(-k) }
                if isZero(x) { throw Unsupported("logarithm domain") }
                return try extra(2) {
                    guard case .float(let m, let e) = try float(x), m > 0 else { throw Unsupported("logarithm domain") }
                    if m == 1 { return try float(.int(e)) }
                    let digits = digits(Int128(m)) - 1
                    return try add(try divide(try lnRaw2(.float(m, -digits)), try ln10()), try float(.int(e + digits)))
                }
            case "sin", "cos", "tan":
                let x = try one(args)
                if modes.degrees, case .int(let i) = x, i % 90 == 0 {
                    let quarter = ((i / 90) % 4 + 4) % 4
                    switch name {
                    case "sin": return .int([0, 1, 0, -1][quarter])
                    case "cos": return .int([1, 0, -1, 0][quarter])
                    default:
                        guard quarter % 2 == 0 else { throw Unsupported("infinite result") }
                        return .int(0)
                    }
                }
                if !modes.degrees, x == .int(0) { return .int(name == "cos" ? 1 : 0) }
                let r = radians(try double(x))
                return try fromDouble(name == "sin" ? Foundation.sin(r) : name == "cos" ? Foundation.cos(r) : Foundation.tan(r))
            case "arcsin", "arccos", "arctan":
                let x = try one(args)
                if modes.degrees, case .int(let i) = x {
                    switch (name, i) {
                    case ("arcsin", -1), ("arcsin", 0), ("arcsin", 1): return .int(90 * i)
                    case ("arccos", -1), ("arccos", 0), ("arccos", 1): return .int(90 - 90 * i)
                    case ("arctan", -1), ("arctan", 0), ("arctan", 1): return .int(45 * i)
                    default: break
                    }
                }
                let d = try double(x)
                if name != "arctan", abs(d) > 1 { throw Unsupported("complex result") }
                let r = name == "arcsin" ? Foundation.asin(d) : name == "arccos" ? Foundation.acos(d) : Foundation.atan(d)
                return try fromDouble(angle(r))
            case "eq", "neq", "lt", "gt", "leq", "geq", "land", "lor":
                guard args.count == 2 else { throw Unsupported("arguments") }
                let ops: [String: Character] = ["eq": "=", "neq": "≠", "lt": "<", "gt": ">", "leq": "≤", "geq": "≥", "land": "&", "lor": "|"]
                return try binary(ops[name]!, args[0], args[1])
            case "lnot":
                return .int(try truth(try one(args)) ? 0 : 1)
            case "percent":
                let x = try one(args)
                _ = try sign(x)
                return try divide(x, .int(100))
            case "float", "pfloat":
                return try float(try one(args))
            case "sign":
                return .int(try sign(try one(args)))
            case "rounde", "roundu":
                guard args.count == 1 || args.count == 2 else { throw Unsupported("arguments") }
                let x = args[0]
                _ = try sign(x)
                guard args.count == 2 else { return try round(x, even: name == "rounde") }
                guard isWhole(args[1]), case let places = try trunc(args[1]) else { throw Unsupported("arguments") }
                if places <= 0, case .int = x { return x }
                let rounded = try round(try scale(x, places, fractions: true), even: name == "rounde")
                return try scale(rounded, -places, fractions: modes.preferFractions)
            case "frac":
                return try toFraction(try one(args))
            case "fdiv":
                guard args.count == 2 else { throw Unsupported("arguments") }
                func parts(_ v: Value) throws -> (Int, Int) {
                    if isWhole(v) { return (try trunc(v), 1) }
                    guard case .frac(let n, let d) = v else { throw Unsupported("arguments") }
                    return (n, d)
                }
                let (n1, d1) = try parts(args[0])
                let (n2, d2) = try parts(args[1])
                guard n2 != 0 else { throw Unsupported("division by zero") }
                let (n, o1) = n1.multipliedReportingOverflow(by: d2)
                let (d, o2) = d1.multipliedReportingOverflow(by: n2)
                if o1 || o2 { throw Unsupported("integer size") }
                return try fraction(n, d)
            case "gcd":
                guard args.count == 2 else { throw Unsupported("arguments") }
                return try gcd(args[0], args[1])
            case "lcm":
                guard args.count == 2 else { throw Unsupported("arguments") }
                return try divide(try absolute(try multiply(args[0], args[1])), try gcd(args[0], args[1]), fractions: modes.preferFractions)
            case "choose", "perm":
                guard args.count == 2, case .int(let n) = args[0], case .int(let m) = args[1] else { throw Unsupported("arguments") }
                if name == "choose" { return .int(try choose(n, m)) }
                guard m >= 0, m <= n else { throw Unsupported("arguments") }
                var result = Value.int(1)
                for k in stride(from: n - m + 1, through: n, by: 1) { result = try multiply(result, .int(k)) }
                return result
            case "pow":
                guard args.count == 2 else { throw Unsupported("arguments") }
                return try power(args[0], args[1], fractions: modes.preferFractions)
            case "exp10":
                let x = try one(args)
                guard case .int(let n) = x else { throw Unsupported("arguments") }
                return n == 0 ? .int(1) : try makeFloat(1, n)
            case "nroot":
                guard args.count == 2, case .int(let n) = args[1], n >= 1 else { throw Unsupported("arguments") }
                _ = try sign(args[0])
                return n == 1 ? args[0] : try rootPower(args[0], n)
            case "hypot":
                guard args.count == 2 else { throw Unsupported("arguments") }
                let (a, b) = (args[0], args[1])
                _ = (try sign(a), try sign(b))
                if isZero(a) { return try absolute(b) }
                if isZero(b) { return try absolute(a) }
                return try extra(1) { try squareRoot(try add(try multiply(a, a), try multiply(b, b))) }
            case "log":
                guard args.count == 2 else {
                    guard args.count == 1 else { throw Unsupported("arguments") }
                    return try call("ln", args)
                }
                let (x, b) = (args[0], args[1])
                _ = (try sign(x), try sign(b))
                if b == .int(10) || b == .float(1, 1) { return try call("log10", [x]) }
                if isZero(x) || isZero(b) || b == .int(1) || b == .float(1, 0) { throw Unsupported("logarithm domain") }
                if x == .int(1) || x == .float(1, 0) {
                    if case .float = b { return .float(0, 0) }
                    return .int(0)
                }
                if rational(x) != nil, rational(b) != nil, try sign(x) > 0, try sign(b) > 0 {
                    var sign = 1
                    var (xx, bb) = (x, b)
                    if try compare(.int(1), x) >= 0 {
                        sign = -1
                        xx = try divide(.int(1), x)
                    }
                    if try compare(.int(1), b) >= 0 {
                        sign = -sign
                        bb = try divide(.int(1), b)
                    }
                    let inverse = try compare(xx, bb) < 0
                    let (exact, n) = inverse ? try integerLog(bb, xx) : try integerLog(xx, bb)
                    if exact { return inverse ? try divide(.int(1), .int(sign * n), fractions: modes.preferFractions) : .int(sign * n) }
                }
                return try extra(2) { try divide(try lnRaw(try float(x)), try lnRaw(try float(b))) }
            case "sinh", "cosh":
                let x = try one(args)
                if x == .int(0) { return .int(name == "sinh" ? 0 : 1) }
                _ = try sign(x)
                return try extra(2) {
                    let e = try expRaw(try float(x))
                    return try multiply(try add(e, try divide(.int(name == "sinh" ? -1 : 1), e)), .float(5, -1))
                }
            case "tanh":
                let x = try one(args)
                if x == .int(0) { return x }
                _ = try sign(x)
                return try extra(2) {
                    let e = try extra(2) { try expRaw(try float(x)) }
                    let inverse = try divide(.int(1), e)
                    return try divide(try subtract(e, inverse), try add(e, inverse))
                }
            case "arcsinh":
                let x = try one(args)
                if x == .int(0) { return x }
                _ = try sign(x)
                return try extra(2) { try lnRaw(try add(x, try squareRootRaw(try add(try multiply(x, x), .float(1, 0))))) }
            case "arccosh":
                let x = try one(args)
                if x == .int(1) { return .int(0) }
                guard try compare(x, .int(-1)) != 0 else { throw Unsupported("complex result") }
                return try extra(2) {
                    let xp1 = try add(.int(1), x)
                    return try lnRaw(try add(x, try multiply(xp1, try squareRootRaw(try divide(try subtract(x, .float(1, 0)), xp1)))))
                }
            case "arctanh":
                let x = try one(args)
                if x == .int(0) { return x }
                guard try compare(x, .int(1)) <= 0 else { throw Unsupported("complex result") }
                return try extra(2) {
                    try multiply(try lnRaw(try divide(try add(.float(1, 0), x), try subtract(.int(1), x))), .float(5, -1))
                }
            case "arctan2":
                guard args.count == 2 else { throw Unsupported("arguments") }
                _ = (try sign(args[0]), try sign(args[1]))
                return try extra(2) {
                    let (y, x) = (try float(args[0]), try float(args[1]))
                    let r: Value
                    if isZero(y) {
                        r = try sign(x) < 0 ? try pi() : .float(0, 0)
                    } else if isZero(x) {
                        r = try sign(y) > 0 ? try piOver2() : try negate(try piOver2())
                    } else if try sign(x) > 0 {
                        r = try arctanRaw(try divide(y, x))
                    } else if try sign(y) > 0 {
                        r = try add(try arctanRaw(try divide(y, x)), try pi())
                    } else {
                        r = try subtract(try arctanRaw(try divide(y, x)), try pi())
                    }
                    return modes.degrees ? try divide(r, try piOver180()) : r
                }
            case "deg", "rad":
                let x = try one(args)
                _ = try sign(x)
                return try extra(2) { name == "deg" ? try divide(x, try piOver180()) : try multiply(x, try piOver180()) }
            case "vflat":
                return .vector(try elements(args))
            case "vgmean", "vhmean":
                let items = try elements(args)
                guard !items.isEmpty else { throw Unsupported("empty vector") }
                return try extra(2) {
                    if name == "vhmean" {
                        let inverses = try items.map { try divide(.int(1), $0, fractions: modes.preferFractions) }
                        return try divide(.int(items.count), try inverses.dropFirst().reduce(inverses[0], add), fractions: modes.preferFractions)
                    }
                    let product = try items.dropFirst().reduce(items[0], multiply)
                    return items.count == 2 ? try squareRoot(product) : try rootPower(product, items.count)
                }
            case "vcov", "vpcov", "vcorr":
                // Two vectors; one matrix argument isn't supported.
                guard args.count == 2 else { throw Unsupported("arguments") }
                return try covariance(try elements([args[0]]), try elements([args[1]]), population: name == "vpcov", correlation: name == "vcorr")
            case "agmean":
                guard args.count == 2 else { throw Unsupported("arguments") }
                let (a, b) = (args[0], args[1])
                _ = (try sign(a), try sign(b))
                if try compare(a, b) == 0 || isZero(a) { return a }
                if isZero(b) { return b }
                return try extra(2) {
                    var (x, y) = (try float(try absolute(a)), try float(try absolute(b)))
                    for _ in 0..<1000 {
                        if nearlyEqual(x, y) { return x }
                        let mean = try multiply(try add(x, y), .float(5, -1))
                        y = try extra(1) { try squareRootRaw(try multiply(x, y)) }
                        x = mean
                    }
                    throw Unsupported("number")
                }
            case "now":
                guard args.isEmpty else { throw Unsupported("arguments") }
                let c = clock()
                return try dateValue(c.year!, c.month!, c.day!, (c.hour!, c.minute!, c.second!))
            case "date":
                // `date(d)` converts between a date and its day number; otherwise the
                // arguments are [year,] month, day[, hour[, minute[, second]]].
                if args.count == 1 {
                    if case .date(let d) = args[0] { return d }
                    return .date(try dayNumber(args[0]))
                }
                guard (2...6).contains(args.count) else { throw Unsupported("arguments") }
                let n = try args.map(integer)
                if n.count == 2 { return try dateValue(clock().year!, n[0], n[1]) }
                return try dateValue(n[0], n[1], n[2], n.count > 3 ? (n[3], n.count > 4 ? n[4] : 0, n.count > 5 ? n[5] : 0) : nil)
            case "year", "month", "day", "hour", "minute", "second", "yearday":
                let dt = try dateParts(try one(args))
                switch name {
                case "year": return .int(dt.year)
                case "month": return .int(dt.month)
                case "day": return .int(dt.day)
                case "hour": return .int(dt.time?.hour ?? 0)
                case "minute": return .int(dt.time?.minute ?? 0)
                case "second": return .int(dt.time?.second ?? 0)
                default: return .int(try absolute(dt.year, dt.month, dt.day) - absolute(dt.year, 1, 1) + 1)
                }
            case "weekday":
                return .int(Days.weekday(try floorInt(try dayNumber(try one(args)))))
            case "newweek":
                guard (1...2).contains(args.count) else { throw Unsupported("arguments") }
                let day = try floorInt(try dayNumber(args[0]))
                let weekday = args.count > 1 ? try integer(args[1]) : 0
                guard (0...6).contains(weekday) else { throw Unsupported("arguments") }
                return .date(.int(day - Days.weekday(day - weekday)))
            case "newmonth":
                guard (1...2).contains(args.count) else { throw Unsupported("arguments") }
                var day = args.count > 1 ? try integer(args[1]) : 1
                guard (0...31).contains(day) else { throw Unsupported("arguments") }
                let dt = try dateParts(args[0])
                let days = try daysInMonth(dt.year, dt.month)
                day = day == 0 || day > days ? days - 1 : day - 1
                return .date(.int(try absolute(dt.year, dt.month, 1) + day))
            case "newyear":
                guard (1...2).contains(args.count) else { throw Unsupported("arguments") }
                var day = args.count > 1 ? try integer(args[1]) : 1
                let dt = try dateParts(args[0])
                if (-12 ... -1).contains(day) { return .date(.int(try absolute(dt.year, -day, 1))) }
                guard (0...366).contains(day) else { throw Unsupported("arguments") }
                let days = try daysInMonth(dt.year, 2) == 29 ? 366 : 365
                if day == 0 || day > days { day = days }
                return .date(.int(try absolute(dt.year, 1, 1) + day - 1))
            case "incmonth", "incyear":
                guard (1...2).contains(args.count) else { throw Unsupported("arguments") }
                let step = args.count > 1 ? args[1] : .int(1)
                let months = try integer(name == "incyear" ? try multiply(step, .int(12)) : step)
                guard abs(months) < 1_000_000_000 else { throw Unsupported("arguments") }
                let dt = try dateParts(args[0])
                let m = dt.month - 1 + months
                let extra = m >= 0 ? m / 12 : (m - 11) / 12
                let month = m - extra * 12 + 1
                var year = dt.year + extra
                let day = min(dt.day, try daysInMonth(year, month))
                // Past the year zero, which Calc doesn't have.
                if dt.year > 0, year <= 0 { year -= 1 }
                if dt.year < 0, year >= 0 { year += 1 }
                return try dateValue(year, month, day, dt.time)
            case "badd", "bsub":
                guard args.count == 2 else { throw Unsupported("arguments") }
                var (a, b) = (args[0], args[1])
                if name == "bsub" {
                    guard case .date = a else { throw Unsupported("arguments") }
                    if case .date = b {
                        if try compare(a, b) < 0 { return try negate(try call(name, [b, a])) }
                        let (x, xHoliday) = try toBusinessDay(a)
                        let (y, yHoliday) = try toBusinessDay(b)
                        return try add(try subtract(x, y), .int(yHoliday && !xHoliday ? 1 : 0))
                    }
                    b = try negate(b)
                }
                if case .date = b {
                    if case .date = a { throw Unsupported("arguments") }
                    (a, b) = (b, a)
                }
                guard case .date = a else { throw Unsupported("arguments") }
                if try sign(b) == 0 { return a }
                let (day, holiday) = try toBusinessDay(a)
                return try fromBusinessDay(try add(day, holiday && sign(b) > 0 ? try subtract(b, .int(1)) : b))
            case "julian":
                // `math-julian-date-beginning`: 1721424.5 days before day 0.
                let x = try one(args)
                if case .date(let d) = x {
                    if case .int = d { return try add(d, .int(1721425)) }
                    return try add(d, try add(.float(17214245, -1), try divide(.int(try zoneOffset(modes.timeZone)), .float(864, 2))))
                }
                if case .int(let d) = x { return .date(try add(.int(d), .int(-1721425))) }
                let shifted = try subtract(try dayNumber(x), .float(17214245, -1))
                return .date(try subtract(shifted, try divide(.int(try zoneOffset(modes.timeZone)), .float(864, 2))))
            case "unixtime":
                // `math-unix-epoch`: day 719163.
                let x = try one(args)
                if case .date(let d) = x {
                    guard precision <= 12 else { throw Unsupported("calc precision") }
                    let seconds = try round(try multiply(try subtract(d, .int(719163)), .int(86400)), even: false)
                    return try add(seconds, .int(try zoneOffset(modes.timeZone)))
                }
                let day = try add(.int(719163), try divide(try dayNumber(x), .float(864, 2)))
                return .date(try subtract(day, try divide(.int(try zoneOffset(modes.timeZone)), .float(864, 2))))
            default:
                throw Unsupported("function \(name)")
            }
        }
    }
}
