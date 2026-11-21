import Foundation

/// Calc's arithmetic on formulas it can't reduce to a number: variables, `inf`, `uinf`, and
/// quotients by zero. This ports `math-add`, `math-mul`, `math-div`, `math-pow` and `math-neg`
/// with their `-symb-fancy` helpers from calc.el and calc-arith.el, as `calc-eval` runs them
/// with `calc-simplify-mode` nil, and Calc's flat formula printer from calccomp.el. Anything
/// those functions would decide from declarations, units, matrices or intervals throws
/// `Calc.Unsupported`.
extension Calc {
    /// A formula, as Calc's Lisp form: a number, a variable, or an operator or function with
    /// its arguments (`+ - * / ^ neg`, or a function name).
    public indirect enum Term: Equatable, Sendable {
        case number(Value)
        case variable(String)
        case op(String, [Term])
    }

    /// `math-reject-arg`: the operation stays unevaluated.
    struct Rejected: Error {}

    /// `calc-symbolic-mode`.
    @TaskLocal static var symbolicMode = false

    /// `calc-prefer-frac`, for the division the arithmetic does.
    @TaskLocal static var fractions = false

    /// Variables Calc gives a value or a declaration, which would change the arithmetic.
    static let reserved: Set<String> = ["CommuteRules", "Decls", "DistribRules", "EvalRules", "FactorRules", "FitRules",
                                        "Holidays", "IntegAfterRules", "InvertRules", "JumpRules", "MergeRules", "Modes",
                                        "NegateRules"]

    /// The special constants and infinities, whose sign or type Calc knows.
    static let constants: Set<String> = ["pi", "e", "phi", "gamma", "i", "inf", "uinf", "nan"]

    static func term(_ v: Value) throws -> Term {
        switch v {
        case .symbolic(let t): return t
        case .nan: return .variable("nan")
        case .int, .float, .frac: return .number(v)
        case .vector, .date: throw Unsupported("symbolic arithmetic")
        }
    }

    static func value(_ t: Term) -> Value {
        switch t {
        case .number(let v): return v
        case .variable("nan"): return .nan
        default: return .symbolic(t)
        }
    }

    enum Symbolic {
        static let inf = Term.variable("inf")
        static let uinf = Term.variable("uinf")
        static let nan = Term.variable("nan")

        // MARK: Predicates

        static func number(_ t: Term) -> Value? {
            if case .number(let v) = t { return v }
            return nil
        }

        static func head(_ t: Term) -> String? {
            if case .op(let f, _) = t { return f }
            return nil
        }

        /// `(nth n a)`, from 1.
        static func arg(_ t: Term, _ n: Int) -> Term {
            guard case .op(_, let args) = t, n - 1 < args.count else { return .number(.int(0)) }
            return args[n - 1]
        }

        static func objectp(_ t: Term) -> Bool { number(t) != nil }
        static func zerop(_ t: Term) -> Bool { number(t).map(isZero) ?? false }
        static func floatp(_ t: Term) -> Bool {
            if case .number(.float) = t { return true }
            return false
        }
        static func ratp(_ t: Term) -> Bool { number(t).map { rational($0) != nil } ?? false }
        static func integerp(_ t: Term) -> Bool {
            if case .number(.int) = t { return true }
            return false
        }

        /// `math-negp`.
        static func negp(_ t: Term) -> Bool {
            if let v = number(t) { return (try? sign(v)) == -1 }
            return t == .op("neg", [inf])
        }

        /// `math-posp`.
        static func posp(_ t: Term) -> Bool {
            if let v = number(t) { return (try? sign(v)) == 1 }
            return t == inf
        }

        /// `Math-equal-int`.
        static func equalInt(_ t: Term, _ n: Int) -> Bool {
            t == .number(.int(n)) || t == .number(.float(n, 0))
        }

        /// `math-looks-negp`; `loose` false is the `Math-looks-negp` macro, which doesn't
        /// look inside a difference.
        static func looksNeg(_ t: Term, loose: Bool = true) -> Bool {
            if negp(t) { return true }
            switch head(t) {
            case "neg": return true
            case "*", "/": return looksNeg(arg(t, 1)) || looksNeg(arg(t, 2))
            case "-": return loose && looksNeg(arg(t, 1))
            default: return false
            }
        }

        /// `math-infinitep`: the infinity a product, quotient or negation is made of.
        static func infinitep(_ t: Term) -> Term? {
            var a = t
            while let f = head(a), ["*", "/", "neg"].contains(f) {
                a = f != "*" || infinitep(arg(a, 1)) != nil ? arg(a, 1) : arg(a, 2)
            }
            return [inf, uinf, nan].contains(a) ? a : nil
        }

        static func containsConstant(_ t: Term) -> Bool {
            switch t {
            case .number: false
            case .variable(let name): constants.contains(name)
            case .op(_, let args): args.contains(where: containsConstant)
            }
        }

        /// `math-possible-signs`: the bits 1 negative, 2 zero, 4 positive and 8 not real,
        /// relative to `origin`. Nothing is declared, so a variable may be anything.
        static func signs(_ a: Term, _ origin: Term? = nil) throws -> Int {
            func negSigns(_ s: Int) -> Int {
                s >= 8 ? 8 + negSigns(s - 8) : (s & 1 != 0 ? 4 : 0) | (s & 2) | (s & 4 != 0 ? 1 : 0)
            }
            if objectp(a) {
                let x = try origin.map { try sub(a, $0) } ?? a
                return posp(x) ? 4 : negp(x) ? 1 : 2
            }
            let (a1, a2) = (arg(a, 1), arg(a, 2))
            let f = head(a)
            if f == "+" || f == "-" {
                if objectp(a1) {
                    if f == "-" { return negSigns(try signs(a2, try origin.map { try add($0, a1) } ?? a1)) }
                    return try signs(a2, try origin.map { try sub($0, a1) } ?? (try neg(a1)))
                }
                if objectp(a2) {
                    let org = f == "-" ? a2 : try neg(a2)
                    return try signs(a1, try origin.map { try add($0, org) } ?? org)
                }
                let s1 = try signs(a1, origin)
                var s2 = try signs(a2)
                if f == "-" { s2 = negSigns(s2) }
                if s1 == s2 { return s1 }
                if s1 == 2 { return s2 }
                if s2 == 2 { return s1 }
                if s1 >= 8 || s2 >= 8 { return 15 }
                if (s1, s2) == (4, 6) || (s1, s2) == (6, 4) { return 4 }
                if (s1, s2) == (1, 3) || (s1, s2) == (3, 1) { return 1 }
                return 7
            }
            if f == "neg" { return negSigns(try signs(a1, try origin.map(neg))) }
            let origin = origin.flatMap { zerop($0) ? nil : $0 }
            let zero = Term.number(.int(0))
            if f == "*" || (f == "/" && origin != nil), objectp(a1) {
                let s = f == "*"
                    ? (zerop(a1) ? try signs(zero, origin) : try signs(a2, try div(origin ?? zero, a1)))
                    : negSigns(try signs(a2, try div(a1, origin!)))
                return negp(a1) ? negSigns(s) : s
            }
            if f == "*" || f == "/", objectp(a2) {
                let s = try signs(a1, f == "*" ? try mul(origin ?? zero, a2) : try div(origin ?? zero, a2))
                return negp(a2) ? negSigns(s) : s
            }
            let sign: Int
            switch a {
            case .op("*", _), .op("/", _):
                let (s1, s2) = (try signs(a1), try signs(a2))
                if s1 >= 8 || s2 >= 8 || (f == "/" && [2, 3, 6, 7].contains(s2)) {
                    sign = 15
                } else {
                    sign = (s1 & 4 != 0 ? s2 : 0) | (s1 & 2) | (s1 & 1 != 0 ? negSigns(s2) : 0)
                }
            case .op("^", _):
                let (s1, s2) = (try signs(a1), try signs(a2))
                if s1 >= 8 || s2 >= 8 {
                    sign = 15
                } else if s1 == 4 {
                    sign = 4
                } else if s1 == 2 {
                    sign = s2 == 4 ? 2 : 15
                } else if s2 == 2 {
                    sign = [1, 5].contains(s1) ? 2 : 15
                } else if case .number(.int(let n)) = a2 {
                    sign = n % 2 == 0 ? ([3, 6, 7].contains(s1) ? 6 : 4) : s1
                } else if s1 == 6 {
                    sign = s2 == 4 ? 6 : 15
                } else {
                    sign = 7
                }
            case .variable(let name):
                switch name {
                case "pi", "e":
                    guard origin == nil else { throw Unsupported("symbolic arithmetic") }
                    return 4
                case "inf": return 4
                case "uinf": return 13
                case "i": return 8
                default: return 15
                }
            default: throw Unsupported("function \(f ?? "")")
            }
            guard let origin else { return sign }
            if posp(origin) { return (sign & 8) + ([1, 2, 3, 8, 9, 10, 11].contains(sign) ? 1 : 7) }
            return (sign & 8) + ([2, 4, 6, 8, 10, 12, 14].contains(sign) ? 4 : 7)
        }

        static func knownNonneg(_ t: Term) throws -> Bool { [2, 4, 6].contains(try signs(t)) }

        /// `math-known-num-integerp` and `math-known-integerp`: only numbers are known to be
        /// integers, as nothing is declared.
        static func knownNumInteger(_ t: Term) throws -> Bool {
            if let v = number(t) { return isWhole(v) }
            guard !containsConstant(t) else { throw Unsupported("symbolic arithmetic") }
            return false
        }

        // MARK: Arithmetic

        /// `math-normalize`: the operations applied again from the leaves, floats rounded
        /// to the precision.
        static func normalize(_ t: Term) throws -> Term {
            switch t {
            case .number(.float(let m, let e)): return .number(try makeFloat(Int128(m), e))
            case .number, .variable: return t
            case .op(let f, let args):
                let args = try args.map(normalize)
                do { return try apply(f, args) } catch is Rejected { return .op(f, args) }
            }
        }

        static func apply(_ f: String, _ args: [Term]) throws -> Term {
            switch (f, args.count) {
            case ("+", 2): return try add(args[0], args[1])
            case ("-", 2): return try sub(args[0], args[1])
            case ("*", 2): return try mul(args[0], args[1])
            case ("/", 2): return try div(args[0], args[1])
            case ("^", 2): return try pow(args[0], args[1])
            case ("neg", 1): return try neg(args[0])
            default: throw Unsupported("function \(f)")
            }
        }

        static func numeric(_ a: Term, _ b: Term, _ op: (Value, Value) throws -> Value) throws -> Term? {
            guard let x = number(a), let y = number(b) else { return nil }
            return try term(try op(x, y))
        }

        /// `math-float` of a rational number.
        static func float(_ t: Term) throws -> Term {
            guard let v = number(t) else { return t }
            return .number(try Calc.float(v))
        }

        /// `math-neg`.
        static func neg(_ a: Term) throws -> Term {
            if let v = number(a) { return .number(try negate(v)) }
            func okayNeg(_ t: Term) -> Bool { looksNeg(t) || head(t) == "-" }
            let (a1, a2) = (arg(a, 1), arg(a, 2))
            switch head(a) {
            case "+": return try sub(try neg(a1), a2)
            case "-": return try sub(a2, a1)
            case "*", "/":
                let f = head(a)!
                if okayNeg(a1) { return .op(f, [try neg(a1), a2]) }
                if okayNeg(a2) { return .op(f, [a1, try neg(a2)]) }
                if objectp(a1) || (head(a1) == "*" && objectp(arg(a1, 1))) { return .op(f, [try neg(a1), a2]) }
                if f == "/", objectp(a2) || (head(a2) == "*" && objectp(arg(a2, 1))) { return .op(f, [a1, try neg(a2)]) }
            case "neg": return a1
            default: if a == uinf || a == nan { return a }
            }
            return .op("neg", [a])
        }

        /// `math-add`.
        static func add(_ a: Term, _ b: Term) throws -> Term {
            if let sum = try numeric(a, b, { try Calc.add($0, $1) }) { return sum }
            if zerop(a) { return b }
            if zerop(b) { return a }
            return try addFancy(a, b)
        }

        /// `math-sub`.
        static func sub(_ a: Term, _ b: Term) throws -> Term { try add(a, try neg(b)) }

        /// `math-add-symb-fancy`.
        static func addFancy(_ a: Term, _ b: Term) throws -> Term {
            switch head(b) {
            case "+": return try add(try add(a, arg(b, 1)), arg(b, 2))
            case "-": return try sub(try add(a, arg(b, 1)), arg(b, 2))
            case "neg" where head(arg(b, 1)) == "+":
                return try sub(try sub(a, arg(arg(b, 1), 1)), arg(arg(b, 1), 2))
            default: break
            }
            if let result = try combineSums(a, b) { return result }
            if looksNeg(b, loose: false) { return .op("-", [a, try neg(b)]) }
            if looksNeg(a, loose: false) { return .op("-", [b, try neg(a)]) }
            return .op("+", [a, b])
        }

        /// The `cond` in `math-add-symb-fancy` that handles infinities and like terms.
        static func combineSums(_ a: Term, _ b: Term) throws -> Term? {
            if let infA = infinitep(a) {
                guard let infB = infinitep(b) else { return a }
                if [uinf, nan].contains(infA) || [uinf, nan].contains(infB) { return nan }
                let dirA = try infiniteDirection(a, infA)
                let dirB = try infiniteDirection(b, infB)
                guard let x = number(dirA), let y = number(dirB) else { return nil }
                return try compare(x, y) == 0 ? a : nan
            }
            if infinitep(b) != nil { return b }
            if head(a) == "+" {
                return try combineSum(arg(a, 2), b, negA: false, negB: false, scalarOkay: true).map { try add(arg(a, 1), $0) }
            }
            if head(a) == "-" {
                return try combineSum(arg(a, 2), b, negA: true, negB: false, scalarOkay: true).map { try add(arg(a, 1), $0) }
            }
            if objectp(a), objectp(b) { return nil }
            return try combineSum(a, b, negA: false, negB: false, scalarOkay: false)
        }

        /// `math-infinite-dir`: the formula with its infinity replaced by 1.
        static func infiniteDirection(_ a: Term, _ infinity: Term) throws -> Term {
            func substitute(_ t: Term) -> Term {
                if t == infinity { return .number(.int(1)) }
                if case .op(let f, let args) = t { return .op(f, args.map(substitute)) }
                return t
            }
            return try normalize(substitute(a))
        }

        /// `math-combine-sum`: two terms that are multiples of the same thing, added.
        static func combineSum(_ a: Term, _ b: Term, negA: Bool, negB: Bool, scalarOkay: Bool) throws -> Term? {
            if scalarOkay, objectp(a), objectp(b) {
                return try add(negA ? try neg(a) : a, negB ? try neg(b) : b)
            }
            /// The coefficient and the rest; a nil coefficient is Calc's `(frac 1 0)`.
            func split(_ t: Term) throws -> (Term?, Term) {
                switch head(t) {
                case "*" where objectp(arg(t, 1)): return (arg(t, 1), arg(t, 2))
                case "/" where objectp(arg(t, 2)):
                    let d = arg(t, 2)
                    if case .number(.int(let n)) = d { return (n == 0 ? nil : .number(try fraction(1, n)), arg(t, 1)) }
                    return (try div(.number(.int(1)), d), arg(t, 1))
                case "neg": return (.number(.int(-1)), arg(t, 1))
                default: return (.number(.int(1)), t)
                }
            }
            let (multA, restA) = try split(a)
            let (multB, restB) = try split(b)
            guard restA == restB else { return nil }
            // `math-make-frac` of two such coefficients divides by zero.
            if multA == nil, multB == nil { throw Rejected() }
            guard var ma = multA, var mb = multB else { throw Unsupported("division by zero") }
            if negA { ma = try neg(ma) }
            if negB { mb = try neg(mb) }
            return try mul(try add(ma, mb), restA)
        }

        /// `math-mul`.
        static func mul(_ a: Term, _ b: Term) throws -> Term {
            if let product = try numeric(a, b, { try multiply($0, $1) }) { return product }
            if zerop(a) { return try mulZero(a, b) }
            if zerop(b) { return try mulZero(b, a) }
            return try mulFancy(a, b)
        }

        /// `math-mul-zero`, `a` zero and `b` a formula.
        static func mulZero(_ a: Term, _ b: Term) throws -> Term {
            if infinitep(b) != nil { return nan }
            return floatp(a) || floatp(b) ? .number(.float(0, 0)) : .number(.int(0))
        }

        /// `math-mul-symb-fancy`.
        static func mulFancy(_ a: Term, _ b: Term) throws -> Term {
            if equalInt(a, 1) { return b }
            if equalInt(a, -1) { return try neg(b) }
            if objectp(b), !objectp(a) { return try mul(b, a) }
            if head(a) == "neg" { return try neg(try mul(arg(a, 1), b)) }
            if head(b) == "neg" { return try neg(try mul(a, arg(b, 1))) }
            if head(a) == "*" { return try mul(arg(a, 1), try mul(arg(a, 2), b)) }
            let negativePower = { (t: Term) in head(t) == "^" && looksNeg(arg(t, 2), loose: false) }
            if negativePower(a), !negativePower(b) {
                return try div(b, try normalize(.op("^", [arg(a, 1), try neg(arg(a, 2))])))
            }
            if negativePower(b), !negativePower(a) {
                return try div(a, try normalize(.op("^", [arg(b, 1), try neg(arg(b, 2))])))
            }
            if head(a) == "/" {
                if let c = try combineProd(arg(a, 2), b, invA: true, invB: false, scalarOkay: true) { return try mul(arg(a, 1), c) }
                return try div(try mul(arg(a, 1), b), arg(a, 2))
            }
            if head(b) == "/" { return try div(try mul(a, arg(b, 1)), arg(b, 2)) }
            if let f = head(b), f == "+" || f == "-", objectp(a), objectp(arg(b, 1)) || objectp(arg(b, 2)) {
                let (x, y) = (try mul(a, arg(b, 1)), try mul(a, arg(b, 2)))
                return f == "+" ? try add(x, y) : try sub(x, y)
            }
            if head(b) == "*", objectp(arg(b, 1)), !objectp(a) { return try mul(arg(b, 1), try mul(a, arg(b, 2))) }
            if looksNeg(b) || (head(b) == "-" && looksNeg(a)) { return try mul(try neg(a), try neg(b)) }
            if head(b) == "*" {
                if let c = try combineProd(a, arg(b, 1), invA: false, invB: false, scalarOkay: true) { return try mul(c, arg(b, 2)) }
            } else if let c = try combineProd(a, b, invA: false, invB: false, scalarOkay: false) {
                return c
            }
            for special in [nan, uinf] {
                if a == special { return a }
                if b == special { return b }
            }
            if b == inf {
                switch try signs(a) {
                case 4: return b
                case 1: return try neg(b)
                case 3, 6: throw Unsupported("symbolic arithmetic")
                default: break
                }
            }
            if a == inf { return try mul(b, a) }
            return .op("*", [a, b])
        }

        /// `math-div`.
        static func div(_ a: Term, _ b: Term) throws -> Term {
            if zerop(b) {
                // `math-div-by-zero`.
                guard let infinity = infinitep(a) else { throw Rejected() }
                return infinity == nan ? a : uinf
            }
            if let quotient = try numeric(a, b, { try divide($0, $1, fractions: fractions) }) { return quotient }
            // `math-div-zero`.
            if zerop(a) { return b == nan ? b : a }
            return try divFancy(a, b)
        }

        /// `math-div-symb-fancy`.
        static func divFancy(_ a: Term, _ b: Term) throws -> Term {
            if equalInt(b, 1) { return a }
            if equalInt(b, -1) { return try neg(a) }
            if head(b) == "^", looksNeg(arg(b, 2), loose: false) || equalInt(a, 1) {
                return try mul(a, try normalize(.op("^", [arg(b, 1), try neg(arg(b, 2))])))
            }
            if head(a) == "neg" { return try neg(try div(arg(a, 1), b)) }
            if head(b) == "neg" { return try neg(try div(a, arg(b, 1))) }
            if head(a) == "/" { return try div(arg(a, 1), try mul(arg(a, 2), b)) }
            if head(b) == "/" { return try div(try mul(a, arg(b, 2)), arg(b, 1)) }
            if case .number(.frac(let n, let d)) = b { return try mul(.number(try fraction(d, n)), a) }
            if let f = head(a), f == "+" || f == "-", objectp(arg(a, 1)) || objectp(arg(a, 2)), objectp(b) {
                let (x, y) = (try div(arg(a, 1), b), try div(arg(a, 2), b))
                return f == "+" ? try add(x, y) : try sub(x, y)
            }
            if head(a) == "-" || looksNeg(a), looksNeg(b) { return try div(try neg(a), try neg(b)) }
            if head(b) == "-", looksNeg(a) { return try div(try neg(a), try neg(b)) }
            if head(a) == "*" {
                if head(b) == "*" {
                    if let c = try combineProd(arg(a, 1), arg(b, 1), invA: false, invB: true, scalarOkay: true) {
                        return try div(try mul(c, arg(a, 2)), arg(b, 2))
                    }
                } else if let c = try combineProd(arg(a, 1), b, invA: false, invB: true, scalarOkay: true) {
                    return try mul(c, arg(a, 2))
                }
            } else if head(b) == "*" {
                if let c = try combineProd(a, arg(b, 1), invA: false, invB: true, scalarOkay: true) { return try div(c, arg(b, 2)) }
            } else if let c = try combineProd(a, b, invA: false, invB: true, scalarOkay: false) {
                return c
            }
            if infinitep(a) != nil {
                if infinitep(b) != nil { return nan }
                if a == nan || a == uinf { return a }
                if a == inf {
                    if posp(b) { return a }
                    if negp(b) { return try neg(a) }
                    if objectp(b) { throw Unsupported("symbolic arithmetic") }
                }
            }
            if infinitep(b) != nil {
                if b == nan { return b }
                return floatp(a) || floatp(b) ? .number(.float(0, 0)) : .number(.int(0))
            }
            return .op("/", [a, b])
        }

        /// `math-mul-or-div`.
        static func mulOrDiv(_ a: Term, _ b: Term, invA: Bool, invB: Bool) throws -> Term {
            if invA { return invB ? try div(try div(.number(.int(1)), a), b) : try div(b, a) }
            return invB ? try div(a, b) : try mul(a, b)
        }

        /// `math-combine-prod`: two factors that are powers of the same thing, multiplied.
        static func combineProd(_ a: Term, _ b: Term, invA: Bool, invB: Bool, scalarOkay: Bool) throws -> Term? {
            if (invA && zerop(a)) || (invB && zerop(b)) { return nil }
            if scalarOkay, objectp(a), objectp(b) {
                let r = try mulOrDiv(a, b, invA: invA, invB: invB)
                return objectp(r) ? r : nil
            }
            if head(a) == "^", invA, looksNeg(arg(a, 2)) { return try mul(try pow(arg(a, 1), try neg(arg(a, 2))), b) }
            if head(b) == "^", invB, looksNeg(arg(b, 2)) { return try mul(a, try pow(arg(b, 1), try neg(arg(b, 2)))) }
            func split(_ t: Term) throws -> (Term, Term) {
                var (base, power) = (t, Term.number(.int(1)))
                if head(t) == "^", objectp(arg(t, 2)) { (base, power) = (arg(t, 1), arg(t, 2)) }
                if head(t) == "sqrt" || head(t) == "exp" { throw Unsupported("symbolic arithmetic") }
                if case .number(.frac(let n, let d)) = base, n < d {
                    (base, power) = (try div(.number(.int(1)), base), try neg(power))
                }
                return (base, power)
            }
            var (baseA, powA) = try split(a)
            var (baseB, powB) = try split(b)
            if invA { powA = try neg(powA) }
            if invB { powB = try neg(powB) }
            func isFrac(_ t: Term) -> Bool {
                if case .number(.frac) = t { return true }
                return false
            }
            if baseA == baseB {
                var sum = try add(powA, powB)
                if !integerp(baseA) || zerop(sum) || isFrac(powA) == isFrac(powB) {
                    if looksNeg(sum), ratp(baseA), posp(baseA) {
                        (baseA, sum) = (try div(.number(.int(1)), baseA), try neg(sum))
                    }
                    if sum == .number(.frac(1, 2)) || sum == .number(.frac(-1, 2)) { throw Unsupported("symbolic arithmetic") }
                    return try pow(baseA, sum)
                }
            }
            if powA == powB, case .number(.int(let x)) = baseA, case .number(.int(let y)) = baseB, x >= 0, y >= 0 {
                if powA == .number(.frac(1, 2)) || powA == .number(.frac(-1, 2)) { throw Unsupported("symbolic arithmetic") }
                return try pow(try mul(baseA, baseB), powA)
            }
            return nil
        }

        /// `math-pow`.
        static func pow(_ a: Term, _ b: Term) throws -> Term {
            if b == nan { return b }
            if zerop(a) {
                if let y = number(b) {
                    if try sign(y) > 0 { return floatp(b) ? try float(a) : a }
                    return .number(try power(number(a)!, y, fractions: fractions))
                }
                // `math-pow-of-zero` with a formula.
                switch try signs(b) {
                case 4: return a
                case 1: return try div(.number(.int(1)), a)
                default: return infinitep(b) != nil ? nan : .op("^", [a, b])
                }
            }
            if a == .number(.int(1)) || b == .number(.int(1)) { return a }
            if a == .number(.float(1, 0)) || b == .number(.float(1, 0)) { return a }
            if zerop(b) {
                if let x = number(a) { return .number(try power(x, number(b)!, fractions: fractions)) }
                // `math-pow-zero`.
                if infinitep(a) != nil { return nan }
                return floatp(b) ? .number(.float(1, 0)) : .number(.int(1))
            }
            if let x = number(a), let y = number(b) { return .number(try power(x, y, fractions: fractions)) }
            return try powFancy(a, b)
        }

        /// `math-pow-fancy` with a formula.
        static func powFancy(_ a: Term, _ b: Term) throws -> Term {
            let (a1, a2) = (arg(a, 1), arg(a, 2))
            switch head(a) {
            case "*" where try knownNumInteger(b) || knownNonneg(a1) || knownNonneg(a2):
                return try mul(try pow(a1, b), try pow(a2, b))
            case "/" where try knownNumInteger(b) || knownNonneg(a2):
                return try div(try pow(a1, b), try pow(a2, b))
            case "/" where try knownNonneg(a1) && !equalInt(a1, 1):
                return try mul(try pow(a1, b), try pow(try div(.number(.int(1)), a2), b))
            case "^" where try knownNumInteger(b) || knownNonneg(a1):
                return try pow(a1, try mul(a2, b))
            case "^":
                // `math-known-evenp` of an exponent with a variable is false.
                if case .number(let n) = a2, isWhole(n), try trunc(n) % 2 == 0, let y = number(b), let q = quarter(y),
                   (1...3).contains(q), try signs(a1) < 8 { throw Unsupported("symbolic arithmetic") }
            default: break
            }
            if looksNeg(a), case .number(.int(let n)) = b {
                let p = try pow(try neg(a), b)
                return n % 2 == 0 ? p : try neg(p)
            }
            if let infinity = infinitep(a) {
                if infinity == nan { return infinity }
                if head(a) == "neg" { return try mul(try pow(.number(.int(-1)), b), try pow(a1, b)) }
                if posp(b) { return a }
                if negp(b) { return floatp(b) ? .number(.float(0, 0)) : .number(.int(0)) }
                if objectp(b) || infinitep(b) != nil { return nan }
                throw Unsupported("symbolic arithmetic")
            }
            if infinitep(b) != nil {
                guard let x = number(a), b == inf else { throw Unsupported("symbolic arithmetic") }
                // `calcFunc-abssqr` of a real number is its square.
                let scale = try multiply(x, x)
                if scale == .int(1) || scale == .float(1, 0) { return nan }
                if try compare(scale, .int(1)) < 0 { return floatp(a) ? .number(.float(0, 0)) : .number(.int(0)) }
                if try compare(.int(1), x) < 0 { return b }
                return uinf
            }
            return .op("^", [a, b])
        }

        // MARK: Display

        /// `math-format-value`: `math-compose-expr` in the flat language.
        static func format(_ t: Term, _ floatFormat: FloatFormat) throws -> String {
            let text = try compose(t, 0, floatFormat)
            // Past its width of 1000, `calc-eval` breaks the line.
            guard text.count < 1000 else { throw Unsupported("symbolic arithmetic") }
            return text
        }

        /// Left and right precedence, from `math-standard-ops` with
        /// `calc-multiplication-has-precedence`.
        static let operators: [String: (Int, Int)] = ["+": (180, 181), "-": (180, 181), "*": (196, 195), "/": (190, 191), "^": (201, 200)]

        static func compose(_ t: Term, _ prec: Int, _ floatFormat: FloatFormat, div: Bool = false) throws -> String {
            switch t {
            case .number(let v): return try Calc.format(v, floatFormat)
            case .variable(let name): return name
            case .op("neg", let args):
                if prec > 197 { return "(" + (try compose(t, 0, floatFormat)) + ")" }
                return "-" + (try compose(args[0], 197, floatFormat))
            case .op(let f, let args):
                guard let (left, right) = operators[f], args.count == 2 else {
                    return f + "(" + (try args.map { try compose($0, 0, floatFormat) }).joined(separator: ", ") + ")"
                }
                if prec > min(left, right) || (div && f == "*") { return "(" + (try compose(t, 0, floatFormat)) + ")" }
                var lhs = try compose(args[0], left, floatFormat)
                let rhs = try compose(args[1], right, floatFormat, div: f == "/")
                if f == "^", lhs.first == "-" { lhs = "(" + lhs + ")" }
                if f == "*", let next = rhs.first {
                    var lastFactor = args[0]
                    while head(lastFactor) == "*" { lastFactor = arg(lastFactor, 2) }
                    let isVariable = if case .variable = lastFactor { true } else { false }
                    if (next.isASCII && (next.isLetter || next.isNumber)) || ".#_([{".contains(next), !(isVariable && next == "(") {
                        return lhs + " " + rhs
                    }
                    return lhs + "*" + rhs
                }
                if f == "^" { return lhs + "^" + rhs }
                if f == "/", let x = number(args[0]), isWhole(x), case .number(.int) = args[1] { return lhs + "/" + rhs }
                return lhs + " " + f + " " + rhs
            }
        }
    }
}
