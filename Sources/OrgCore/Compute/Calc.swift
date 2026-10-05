import Foundation

/// The part of Emacs Calc that table formulas use, with Calc's number semantics: exact
/// integers, decimal floats rounded to `calc-internal-prec` digits after every operation, and
/// Calc's display formats. Anything outside this domain throws `Calc.Unsupported`, and the
/// caller hands the work to Emacs.
public enum Calc {
    public struct Unsupported: Error, Equatable, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
        init(_ reason: String) { self.reason = reason }
    }

    public enum Value: Equatable, Sendable {
        case int(Int)
        /// Mantissa and exponent, normalized: at most `precision` digits, no trailing zeros.
        case float(Int, Int)
        case vector([Value])
    }

    public enum FloatFormat: Equatable, Sendable {
        case float(Int), fix(Int), sci(Int), eng(Int)
    }

    public struct Modes: Equatable, Sendable {
        public var precision = 12
        public var format = FloatFormat.float(8)
        public var degrees = true
        public init() {}
    }

    /// `calc-eval` of `expression`, as the string Calc would return.
    public static func evaluate(_ expression: String, modes: Modes = Modes()) throws -> String {
        guard modes.precision == 12 else { throw Unsupported("calc precision") }
        var parser = Parser(expression)
        let tree = try parser.parse()
        let value = try Evaluator(modes: modes).eval(tree)
        return try format(value, modes.format)
    }

    // MARK: - Numbers

    static let precision = 12

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
        return .float(Int(m), e)
    }

    static func parts(_ v: Value) throws -> (Int128, Int) {
        switch v {
        case .int(let i): return (Int128(i), 0)
        case .float(let m, let e): return (Int128(m), e)
        case .vector: throw Unsupported("vector arithmetic")
        }
    }

    static func double(_ v: Value) throws -> Double {
        switch v {
        case .int(let i): return Double(i)
        case .float(let m, let e): return Double(m) * pow(10, Double(e))
        case .vector: throw Unsupported("vector arithmetic")
        }
    }

    static func fromDouble(_ d: Double) throws -> Value {
        guard d.isFinite else { throw Unsupported("infinite result") }
        if d == 0 { return .float(0, 0) }
        // Seventeen significant digits are exact for a Double; rounding to 12 follows.
        let text = String(format: "%.16e", d)
        let pieces = text.split(separator: "e")
        let digitsText = pieces[0].replacingOccurrences(of: ".", with: "")
        guard let mantissa = Int128(digitsText), let exponent = Int(pieces[1]) else { throw Unsupported("number") }
        return try makeFloat(mantissa, exponent - 16)
    }

    static func add(_ a: Value, _ b: Value) throws -> Value {
        if case .int(let x) = a, case .int(let y) = b {
            let (sum, overflow) = x.addingReportingOverflow(y)
            if overflow { throw Unsupported("integer size") }
            return .int(sum)
        }
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
        case .int(let i):
            guard i != .min else { throw Unsupported("integer size") }
            return .int(-i)
        case .float(let m, let e): return .float(-m, e)
        case .vector: throw Unsupported("vector arithmetic")
        }
    }

    static func multiply(_ a: Value, _ b: Value) throws -> Value {
        if case .int(let x) = a, case .int(let y) = b {
            let (product, overflow) = x.multipliedReportingOverflow(by: y)
            if overflow { throw Unsupported("integer size") }
            return .int(product)
        }
        let (m1, e1) = try parts(a)
        let (m2, e2) = try parts(b)
        let (product, overflow) = m1.multipliedReportingOverflow(by: m2)
        if overflow { throw Unsupported("number size") }
        return try makeFloat(product, e1 + e2)
    }

    static func divide(_ a: Value, _ b: Value) throws -> Value {
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
    static func integerPower(_ a: Value, _ n: Int) throws -> Value {
        if n < 0 { return try integerPower(try divide(.int(1), a), -n) }
        if n == 0 { return .int(1) }
        if n == 1 { return a }
        let square = try multiply(a, a)
        if n % 2 == 0 { return try integerPower(square, n / 2) }
        return try multiply(a, try integerPower(square, n / 2))
    }

    static func power(_ a: Value, _ b: Value) throws -> Value {
        if case .int(let n) = b { return try integerPower(a, n) }
        let base = try double(a)
        guard base >= 0 else { throw Unsupported("complex result") }
        return try fromDouble(pow(base, try double(b)))
    }

    static func compare(_ a: Value, _ b: Value) throws -> Int {
        let difference = try add(a, try negate(b))
        let (m, _) = try parts(difference)
        return m == 0 ? 0 : (m < 0 ? -1 : 1)
    }

    // MARK: - Display

    /// `math-format-number`.
    static func format(_ value: Value, _ floatFormat: FloatFormat) throws -> String {
        switch value {
        case .int(let i): return String(i)
        case .vector: throw Unsupported("vector result")
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

    // MARK: - Parsing

    indirect enum Node {
        case number(Value)
        case vector([Node])
        case unary(Character, Node)
        case binary(Character, Node, Node)
        case call(String, [Node])
    }

    struct Parser {
        let chars: [Character]
        var i = 0

        init(_ s: String) { chars = Array(s) }

        mutating func skip() {
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        }

        mutating func peek() -> Character? {
            skip()
            return i < chars.count ? chars[i] : nil
        }

        mutating func parse() throws -> Node {
            let node = try sum()
            guard peek() == nil else { throw Unsupported("formula syntax") }
            return node
        }

        // `+ -` < `/` < `*` < unary minus < `^`, as Calc's operator table orders them.
        mutating func sum() throws -> Node {
            var left = try quotient()
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                left = .binary(c, left, try quotient())
            }
            return left
        }

        mutating func quotient() throws -> Node {
            var left = try product()
            while peek() == "/" {
                i += 1
                left = .binary("/", left, try product())
            }
            return left
        }

        mutating func product() throws -> Node {
            var left = try unary()
            while peek() == "*" {
                i += 1
                left = .binary("*", left, try unary())
            }
            return left
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
            let base = try primary()
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
                let inner = try sum()
                guard peek() == ")" else { throw Unsupported("formula syntax") }
                i += 1
                return inner
            }
            if c == "[" {
                i += 1
                var items: [Node] = []
                if peek() != "]" {
                    items.append(try sum())
                    while peek() == "," {
                        i += 1
                        items.append(try sum())
                    }
                }
                guard peek() == "]" else { throw Unsupported("formula syntax") }
                i += 1
                return .vector(items)
            }
            if c.isASCII, c.isNumber || c == "." { return .number(try number()) }
            if c.isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    name.append(chars[i])
                    i += 1
                }
                guard peek() == "(" else { throw Unsupported("variable \(name)") }
                i += 1
                var args: [Node] = []
                if peek() != ")" {
                    args.append(try sum())
                    while peek() == "," {
                        i += 1
                        args.append(try sum())
                    }
                }
                guard peek() == ")" else { throw Unsupported("formula syntax") }
                i += 1
                return .call(name, args)
            }
            throw Unsupported("formula syntax")
        }

        /// Calc's number syntax: `7`, `007`, `1.5`, `.5`, `5.`, `1e3`, `1.5e-3`.
        mutating func number() throws -> Value {
            var whole = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                whole.append(chars[i])
                i += 1
            }
            var fraction: String?
            if i < chars.count, chars[i] == "." {
                i += 1
                var f = ""
                while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                    f.append(chars[i])
                    i += 1
                }
                fraction = f
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
            case .unary(_, let operand): return try negate(try eval(operand))
            case .binary(let op, let l, let r):
                let a = try eval(l)
                let b = try eval(r)
                switch op {
                case "+": return try add(a, b)
                case "-": return try add(a, try negate(b))
                case "*": return try multiply(a, b)
                case "/": return try divide(a, b)
                default: return try power(a, b)
                }
            case .call(let name, let args):
                return try call(name, try args.map(eval))
            }
        }

        func elements(_ args: [Value]) throws -> [Value] {
            guard args.count == 1 else { throw Unsupported("arguments") }
            if case .vector(let items) = args[0] { return items }
            return [args[0]]
        }

        func one(_ args: [Value]) throws -> Value {
            guard args.count == 1 else { throw Unsupported("arguments") }
            if case .vector = args[0] { throw Unsupported("vector argument") }
            return args[0]
        }

        func radians(_ x: Double) -> Double { modes.degrees ? x * .pi / 180 : x }
        func angle(_ x: Double) -> Double { modes.degrees ? x * 180 / .pi : x }

        func call(_ name: String, _ args: [Value]) throws -> Value {
            switch name {
            case "vsum":
                return try elements(args).reduce(Value.int(0)) { try add($0, $1) }
            case "vprod":
                return try elements(args).reduce(Value.int(1)) { try multiply($0, $1) }
            case "vcount":
                return .int(try elements(args).count)
            case "vmean":
                let items = try elements(args)
                guard !items.isEmpty else { throw Unsupported("empty vector") }
                return try divide(try items.reduce(Value.int(0)) { try add($0, $1) }, .int(items.count))
            case "vmax", "vmin":
                let items = try elements(args)
                guard var best = items.first else { throw Unsupported("empty vector") }
                for item in items.dropFirst() {
                    let order = try compare(item, best)
                    if name == "vmax" ? order > 0 : order < 0 { best = item }
                }
                return best
            case "vmedian":
                var items = try elements(args)
                guard !items.isEmpty else { throw Unsupported("empty vector") }
                try items.sort { try compare($0, $1) < 0 }
                if items.count % 2 == 1 { return items[items.count / 2] }
                return try divide(try add(items[items.count / 2 - 1], items[items.count / 2]), .int(2))
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
                return try compare(x, .int(0)) < 0 ? try negate(x) : x
            case "floor", "ceil", "trunc":
                let x = try one(args)
                if case .int = x { return x }
                let d = try double(x)
                let r = name == "floor" ? d.rounded(.down) : name == "ceil" ? d.rounded(.up) : d.rounded(.towardZero)
                guard let i = Int(exactly: r) else { throw Unsupported("integer size") }
                return .int(i)
            case "round":
                guard args.count == 1 || args.count == 2 else { throw Unsupported("arguments") }
                let x = args[0]
                if args.count == 2 {
                    guard case .int(let places) = args[1] else { throw Unsupported("arguments") }
                    guard case .float(let m, let e) = x else { return x }
                    return try makeFloat(try scaleRounding(Int128(m), e + places), -places)
                }
                guard case .float(let m, let e) = x else { return x }
                guard let i = Int(exactly: try scaleRounding(Int128(m), e)) else { throw Unsupported("integer size") }
                return .int(i)
            case "sqrt":
                let x = try one(args)
                if case .int(let i) = x {
                    guard i >= 0 else { throw Unsupported("complex result") }
                    let root = Int(Double(i).squareRoot().rounded())
                    if root * root == i { return .int(root) }
                }
                let d = try double(x)
                guard d >= 0 else { throw Unsupported("complex result") }
                return try fromDouble(d.squareRoot())
            case "exp":
                let x = try one(args)
                if x == .int(0) { return .int(1) }
                return try fromDouble(Foundation.exp(try double(x)))
            case "ln":
                let x = try one(args)
                if x == .int(1) { return .int(0) }
                let d = try double(x)
                guard d > 0 else { throw Unsupported("logarithm domain") }
                return try fromDouble(Foundation.log(d))
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
                let d = try double(x)
                guard d > 0 else { throw Unsupported("logarithm domain") }
                return try fromDouble(Foundation.log10(d))
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
            default:
                throw Unsupported("function \(name)")
            }
        }
    }
}
