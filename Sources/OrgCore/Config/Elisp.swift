import Foundation

/// A small Emacs Lisp evaluator over `Sexp` values: the special forms and functions diary
/// sexps and table formulas use, with dynamic binding unless `lexical` is set. A function or
/// form it doesn't have throws `Unsupported`; errors Emacs would signal throw `Signal`.
public final class Elisp {
    public struct Unsupported: Error, Equatable, CustomStringConvertible {
        public let what: String
        public var description: String { what }
    }

    public struct Signal: Error, Equatable, CustomStringConvertible {
        public let message: String
        /// The error symbol, by default from the message, and its data when known: what
        /// `condition-case` binds.
        public let symbol: String?
        public let data: [Sexp]?
        public var description: String { message }

        public init(message: String, symbol: String? = nil, data: [Sexp]? = nil) {
            self.message = message
            self.symbol = symbol ?? Self.symbols.first(where: { message.hasPrefix($0.prefix) })?.symbol
            self.data = data ?? (message == "Arithmetic error" ? [] : nil)
        }

        static let symbols: [(prefix: String, symbol: String)] = [
            ("Arithmetic error", "arith-error"), ("Args out of range", "args-out-of-range"), ("Invalid function", "invalid-function"),
            ("Symbol’s value as variable is void", "void-variable"), ("Wrong number of arguments", "wrong-number-of-arguments"),
            ("Wrong type argument", "wrong-type-argument"),
        ]
    }

    /// What `condition-case` binds its variable to for an error whose data isn't known.
    static let unknownError = Sexp.symbol("\u{0}error")

    public typealias Builtin = (Elisp, [Sexp]) throws -> Sexp

    /// A set of bindings, shared by the closures created while it is in scope.
    final class Frame {
        var vars: [String: Sexp]
        init(_ vars: [String: Sexp] = [:]) { self.vars = vars }
    }

    /// The global frame, then the visible local ones, innermost last.
    var scopes: [Frame] = [Frame()]
    /// `lexical-binding`: lambdas close over the local frames, and only special variables
    /// (the host's and `defvar`'s) are bound dynamically.
    public var lexical = false
    /// Variables bound dynamically when `lexical` is set.
    var specials: Set<String> = []
    /// Under lexical binding, running a lambda list, which Emacs evaluates with dynamic binding:
    /// every variable is bound dynamically and lambdas aren't closures.
    private var dynamicOnly = false
    /// The functions `defun` defined, which may take closures.
    var defined: Set<String> = []
    /// Each closure's captured frames, by the id in its `(closure ID ARGS . BODY)` value.
    var closures: [[Frame]] = []
    /// The scopes of the callers of running closures, and the global values that dynamic
    /// bindings of special variables hide.
    private var hiddenScopes: [[Frame]] = []
    private var hiddenValues: [Sexp] = []
    /// Values held while a form evaluates: each call's evaluated arguments, innermost last.
    private var pending: [[Sexp]] = []
    /// The variable an in-place function's first argument named, for that function to read.
    private var inPlaceVariable: String?
    /// The syntax table regexps and case conversion use.
    var syntax = ElispSyntax.org {
        didSet { regexes = [:] }
    }
    private var functions: [String: Builtin] = [:]
    /// Forms the host defines, given their arguments unevaluated.
    private var forms: [String: Builtin] = [:]
    var steps = 0
    static let stepLimit = 1_000_000
    /// Nested evaluations, as `max-lisp-eval-depth` limits them.
    private var depth = 0
    static let depthLimit = 1600
    /// The most elements a list built at once may have.
    static let lengthLimit = 1_000_000
    /// What `princ` and the other printers wrote: the innermost `with-output-to-string`, or
    /// standard output.
    private var outputs: [String] = [""]
    /// What went to standard output.
    public var standardOutput: String { outputs[0] }
    /// What `message` wrote.
    public private(set) var messages = ""
    /// What the last `string-match` matched: each group's range in characters.
    var matchData: [Range<Int>?] = []
    var regexes: [String: ElispRegex] = [:]

    public init() {
        Self.core(self)
        Self.library(self)
        Self.regexFunctions(self)
    }

    /// Defines or replaces a function.
    public func define(_ name: String, _ function: @escaping Builtin) { functions[name] = function }

    /// Defines a macro by its value: `form` gets the arguments unevaluated.
    public func defineForm(_ name: String, _ form: @escaping Builtin) { forms[name] = form }

    /// Sets a global variable, which is special.
    public func set(_ name: String, _ value: Sexp) {
        scopes[0].vars[name] = value
        specials.insert(name)
    }

    public func value(_ name: String) throws -> Sexp {
        for scope in scopes.reversed() {
            guard let v = scope.vars[name] else { continue }
            if v == Self.unknownError { throw Unsupported(what: "the data of this error") }
            return v
        }
        throw Signal(message: "Symbol’s value as variable is void: \(name)", data: [.symbol(name)])
    }

    /// Evaluates `body` with `bindings` added: in a new frame, or for special variables under
    /// lexical binding, as their global values until `body` returns.
    public func binding<T>(_ bindings: [String: Sexp], _ body: () throws -> T) rethrows -> T {
        try binding(Frame(bindings), body)
    }

    func binding<T>(_ frame: Frame, _ body: () throws -> T) rethrows -> T {
        let dynamic = dynamicOnly ? Array(frame.vars.keys) : lexical ? frame.vars.keys.filter(specials.contains) : []
        var saved: [(String, Sexp?)] = []
        for name in dynamic {
            saved.append((name, scopes[0].vars[name]))
            if let old = scopes[0].vars[name] { hiddenValues.append(old) }
            scopes[0].vars[name] = frame.vars.removeValue(forKey: name)
        }
        scopes.append(frame)
        defer {
            scopes.removeLast()
            for (name, old) in saved.reversed() {
                scopes[0].vars[name] = old
                if old != nil { hiddenValues.removeLast() }
            }
        }
        return try body()
    }

    func assign(_ name: String, _ v: Sexp) {
        for scope in scopes.reversed() where scope.vars[name] != nil {
            scope.vars[name] = v
            return
        }
        scopes[0].vars[name] = v
    }

    /// A lambda as `function` makes it: a closure over the local frames under lexical
    /// binding, else the list itself.
    func closure(_ lambda: Sexp) -> Sexp {
        guard lexical, !dynamicOnly, case .list(let items) = lambda, items.first == .symbol("lambda"), items.count >= 2 else { return lambda }
        closures.append(Array(scopes.dropFirst()))
        return .list([.symbol("closure"), .integer(closures.count - 1)] + items.dropFirst())
    }

    static func isClosure(_ v: Sexp) -> Bool {
        if case .list(let items) = v, items.count >= 3, items[0] == .symbol("closure"), items[1].integer != nil { return true }
        return false
    }

    /// Builtins that may take closures as arguments, from the given position on: those that
    /// call them or only hold them. Emacs's closures aren't lists, as they are here.
    static let closureArguments: [String: Int] = [
        "funcall": 0, "apply": 0, "mapcar": 0, "mapc": 0, "mapconcat": 0, "seq-map": 0, "seq-filter": 0, "seq-remove": 0,
        "seq-reduce": 0, "cl-reduce": 0, "cl-remove-if": 0, "cl-remove-if-not": 0, "cl-find": 1, "cl-position": 1, "sort": 0,
        "replace-regexp-in-string": 1, "list": 0, "identity": 0, "ignore": 0, "null": 0, "not": 0,
    ]
    /// Builtins that compare or print what lists hold.
    static let closureInspectors: Set<String> = [
        "equal", "eq", "eql", "member", "memq", "memql", "assoc", "assq", "delete", "delq", "delete-dups", "seq-uniq",
        "format", "format-message", "message", "error", "user-error", "prin1-to-string", "princ", "prin1", "print",
    ]

    /// Refuses a builtin call that would look inside a closure.
    func refuseClosures(_ name: String, _ args: [Sexp]) throws {
        guard !closures.isEmpty, !defined.contains(name) else { return }
        for (i, arg) in args.enumerated() {
            if Self.isClosure(arg) ? i < Self.closureArguments[name] ?? .max : Self.closureInspectors.contains(name) && Self.containsClosure(arg) {
                throw Unsupported(what: "\(name) on a closure")
            }
        }
    }

    /// Whether `v` contains a closure, which Emacs prints in a form this evaluator doesn't.
    static func containsClosure(_ v: Sexp) -> Bool {
        switch v {
        case .list(let items): isClosure(v) || items.contains(where: containsClosure)
        case .dotted(let items, let last): items.contains(where: containsClosure) || containsClosure(last)
        case .vector(let items): items.contains(where: containsClosure)
        default: false
        }
    }

    /// The variable named by the first argument of the function being called from `eval`, read
    /// once.
    func takeInPlaceVariable() -> String? {
        defer { inPlaceVariable = nil }
        return inPlaceVariable
    }

    /// Refuses an in-place change to `v` when another binding, list or pending argument may
    /// share its cells, which Emacs would change too: any value holding a list that ends like
    /// `v`, or an equal vector or string. `variable`'s innermost binding is the one `eval`
    /// updates after the call.
    func refuseShared(_ v: Sexp, variable: String?, _ name: String) throws {
        let matches: (Sexp) -> Bool
        switch v {
        case .list(let items):
            guard let last = items.last.map(Self.normalized) else { return }
            matches = { if case .list(let xs) = $0, let l = xs.last { Self.normalized(l) == last } else { false } }
        case .dotted(let items, let tail):
            let last = Self.normalized(items.last!)
            matches = { if case .dotted(let xs, let t) = $0 { t == tail && Self.normalized(xs.last!) == last } else { false } }
        case .vector, .string:
            matches = { $0 == v }
        default:
            return
        }
        func contains(_ x: Sexp) -> Bool {
            if matches(x) { return true }
            switch x {
            case .list(let items), .vector(let items): return items.contains(where: contains)
            case .dotted(let items, let last): return items.contains(where: contains) || contains(last)
            default: return false
            }
        }
        let owner = variable.flatMap { name in scopes.last { $0.vars[name] != nil } }
        var seen: Set<ObjectIdentifier> = []
        for frame in (hiddenScopes + [scopes] + closures).joined() where seen.insert(ObjectIdentifier(frame)).inserted {
            for (key, value) in frame.vars where !(frame === owner && key == variable) && contains(value) {
                throw Unsupported(what: "\(name) on a list another value shares")
            }
        }
        if (hiddenValues + pending.dropLast().joined()).contains(where: contains) { throw Unsupported(what: "\(name) on a list another value shares") }
    }

    // MARK: - Values

    public static let t = Sexp.symbol("t")

    public static func isNil(_ v: Sexp) -> Bool { v == .nil || v == .list([]) }
    public static func bool(_ b: Bool) -> Sexp { b ? t : .nil }
    static func list(_ items: [Sexp]) -> Sexp { items.isEmpty ? .nil : .list(items) }

    static func cons(_ a: Sexp, _ b: Sexp) -> Sexp {
        switch b {
        case .list(let items): .list([a] + items)
        case .dotted(let items, let last): .dotted([a] + items, last)
        case _ where isNil(b): .list([a])
        default: .dotted([a], b)
        }
    }

    static func car(_ v: Sexp) throws -> Sexp {
        if isClosure(v) { throw Unsupported(what: "car on a closure") }
        return switch v {
        case .list(let items): items.first ?? .nil
        case .dotted(let items, _): items[0]
        case _ where isNil(v): .nil
        default: throw Signal(message: "Wrong type argument: listp, \(v.description)", data: [.symbol("listp"), v])
        }
    }

    static func cdr(_ v: Sexp) throws -> Sexp {
        if isClosure(v) { throw Unsupported(what: "cdr on a closure") }
        return switch v {
        case .list(let items): list(Array(items.dropFirst()))
        case .dotted(let items, let last): items.count == 1 ? last : .dotted(Array(items.dropFirst()), last)
        case _ where isNil(v): .nil
        default: throw Signal(message: "Wrong type argument: listp, \(v.description)", data: [.symbol("listp"), v])
        }
    }

    /// A proper list's elements.
    static func elements(_ v: Sexp) throws -> [Sexp] {
        if isClosure(v) { throw Unsupported(what: "a closure as a list") }
        if case .list(let items) = v { return items }
        if isNil(v) { return [] }
        throw Signal(message: "Wrong type argument: listp, \(v.description)")
    }

    enum Number {
        case int(Int), float(Double)
        var double: Double {
            switch self {
            case .int(let i): Double(i)
            case .float(let d): d
            }
        }
    }

    static func number(_ v: Sexp) throws -> Number {
        switch v {
        case .integer(let i): return .int(i)
        case .float(let d): return .float(d)
        case .character(let c): return .int(c)
        default: throw Signal(message: "Wrong type argument: number-or-marker-p, \(v.description)")
        }
    }

    static func int(_ v: Sexp) throws -> Int {
        switch v {
        case .integer(let i): return i
        case .character(let c): return c
        default: throw Signal(message: "Wrong type argument: integerp, \(v.description)")
        }
    }

    static func string(_ v: Sexp) throws -> String {
        guard case .string(let s) = v else { throw Signal(message: "Wrong type argument: stringp, \(v.description)") }
        return s
    }

    static func sexp(_ n: Number) -> Sexp {
        switch n {
        case .int(let i): .integer(i)
        case .float(let d): .float(d)
        }
    }

    /// `prin1-to-string` with `princ` for strings when `escape` is false.
    public static func printed(_ v: Sexp, escape: Bool = false) -> String {
        switch v {
        case .string(let s): return escape ? "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
        case .float(let d): return floatText(d)
        case .character(let c): return String(c)
        case .list(let items): return "(" + items.map { printed($0, escape: true) }.joined(separator: " ") + ")"
        case .dotted(let items, let last): return "(" + items.map { printed($0, escape: true) }.joined(separator: " ") + " . " + printed(last, escape: true) + ")"
        case .vector(let items): return "[" + items.map { printed($0, escape: true) }.joined(separator: " ") + "]"
        default: return v.description
        }
    }

    /// Emacs's float printing: the shortest text that reads back, with `.0` on whole numbers.
    static func floatText(_ d: Double) -> String {
        if d.isNaN { return d.sign == .minus ? "-0.0e+NaN" : "0.0e+NaN" }
        if d.isInfinite { return d < 0 ? "-1.0e+INF" : "1.0e+INF" }
        var text = "\(d)"
        if let e = text.firstIndex(of: "e") {
            let mantissa = text[..<e]
            var exponent = String(text[text.index(after: e)...])
            if !exponent.hasPrefix("-"), !exponent.hasPrefix("+") { exponent = "+" + exponent }
            text = mantissa.hasSuffix(".0") ? String(mantissa.dropLast(2)) + "e" + exponent : mantissa + "e" + exponent
        }
        return text
    }

    // MARK: - Evaluation

    /// Less than 128 KB of this thread's stack left: background threads have only 512 KB.
    static func stackIsLow() -> Bool {
        var marker = 0
        let here = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let size = UInt(pthread_get_stacksize_np(pthread_self()))
        return here < top - size + 128 * 1024
    }

    public func eval(_ form: Sexp) throws -> Sexp {
        steps += 1
        if steps > Self.stepLimit { throw Signal(message: "Evaluation took too long") }
        depth += 1
        defer { depth -= 1 }
        if depth > Self.depthLimit || Self.stackIsLow() { throw Signal(message: "Lisp nesting exceeds ‘max-lisp-eval-depth’") }
        switch form {
        case .symbol(let name):
            if name == "nil" || name == "t" || name.hasPrefix(":") { return form }
            return try value(name)
        case .character(let c): return .integer(c)
        case .list(let items):
            guard let head = items.first else { return .nil }
            guard case .symbol(let name) = head else {
                if case .list(let lambda) = head, lambda.first == .symbol("lambda") {
                    return try call(closure(head), try evaluated(items.dropFirst()))
                }
                throw Signal(message: "Invalid function: \(head.description)")
            }
            let args = Array(items.dropFirst())
            if let value = try special(name, args) { return value }
            if let form = forms[name] { return try form(self, args) }
            // The function first, so an unknown one, or a macro this evaluator lacks, is
            // unsupported rather than an error from its arguments.
            guard let function = functions[name] else { throw Unsupported(what: "function \(name)") }
            pending.append([])
            defer { pending.removeLast() }
            for arg in args { pending[pending.count - 1].append(try eval(arg)) }
            let values = pending[pending.count - 1]
            try refuseClosures(name, values)
            var variable: String?
            if case .symbol(let s)? = args.first, s != "nil", s != "t", !s.hasPrefix(":") { variable = s }
            inPlaceVariable = variable
            let result = try function(self, values)
            inPlaceVariable = nil
            if let variable, let after = Self.afterInPlace(name, values, result) { assign(variable, after) }
            return result
        case .dotted: throw Signal(message: "Invalid function")
        default: return form
        }
    }

    /// `forms`' values, held as pending while the later ones evaluate.
    func evaluated(_ forms: some Collection<Sexp>) throws -> [Sexp] {
        pending.append([])
        defer { pending.removeLast() }
        for form in forms { pending[pending.count - 1].append(try eval(form)) }
        return pending[pending.count - 1]
    }

    func progn(_ body: some Collection<Sexp>) throws -> Sexp {
        var result = Sexp.nil
        for form in body { result = try eval(form) }
        return result
    }

    /// Special forms and macros; nil when `name` is an ordinary function.
    private func special(_ name: String, _ args: [Sexp]) throws -> Sexp? {
        switch name {
        case "quote":
            return args.first ?? .nil
        case "function":
            return closure(args.first ?? .nil)
        case "lambda":
            return closure(.list([.symbol("lambda")] + args))
        case "progn":
            return try progn(args)
        case "prog1":
            guard let first = args.first else { return .nil }
            pending.append([try eval(first)])
            defer { pending.removeLast() }
            _ = try progn(args.dropFirst())
            return pending[pending.count - 1][0]
        case "if":
            guard args.count >= 2 else { throw Signal(message: "Wrong number of arguments: if") }
            return Self.isNil(try eval(args[0])) ? try progn(args.dropFirst(2)) : try eval(args[1])
        case "when", "unless":
            guard let test = args.first else { return .nil }
            return Self.isNil(try eval(test)) == (name == "unless") ? try progn(args.dropFirst()) : .nil
        case "cond":
            for clause in args {
                let parts = try Self.elements(clause)
                guard let test = parts.first else { continue }
                let value = try eval(test)
                if !Self.isNil(value) { return parts.count == 1 ? value : try progn(parts.dropFirst()) }
            }
            return .nil
        case "and":
            var value = Self.t
            for form in args {
                value = try eval(form)
                if Self.isNil(value) { return .nil }
            }
            return value
        case "or":
            for form in args {
                let value = try eval(form)
                if !Self.isNil(value) { return value }
            }
            return .nil
        case "let", "let*":
            guard let first = args.first else { return .nil }
            var specs: [(String, Sexp?)] = []
            for binding in try Self.elements(first) {
                if case .symbol(let s) = binding {
                    specs.append((s, nil))
                } else {
                    let parts = try Self.elements(binding)
                    guard case .symbol(let s)? = parts.first else { throw Signal(message: "Bad binding") }
                    specs.append((s, parts.count > 1 ? parts[1] : nil))
                }
            }
            if name == "let" {
                let values = try evaluated(specs.map { $0.1 ?? .nil })
                var bindings: [String: Sexp] = [:]
                for ((variable, _), value) in zip(specs, values) { bindings[variable] = value }
                return try binding(bindings) { try progn(args.dropFirst()) }
            }
            // `let*` nests a binding per variable, so a closure sees the ones before it.
            func bind(_ rest: ArraySlice<(String, Sexp?)>) throws -> Sexp {
                guard let (variable, form) = rest.first else { return try progn(args.dropFirst()) }
                let value = try form.map(eval) ?? .nil
                return try binding([variable: value]) { try bind(rest.dropFirst()) }
            }
            return try bind(specs[...])
        case "setq":
            var value = Sexp.nil
            var i = 0
            while i + 1 < args.count {
                guard case .symbol(let variable) = args[i] else { throw Signal(message: "Bad setq") }
                value = try eval(args[i + 1])
                assign(variable, value)
                i += 2
            }
            return value
        case "push", "pop":
            guard case .symbol(let variable)? = (name == "push" ? args.dropFirst().first : args.first) else { throw Unsupported(what: "\(name) on a place") }
            let list = try value(variable)
            if name == "pop" {
                assign(variable, try Self.cdr(list))
                return try Self.car(list)
            }
            if Self.isClosure(list) { throw Unsupported(what: "push on a closure") }
            let pushed = Self.cons(try eval(args[0]), list)
            assign(variable, pushed)
            return pushed
        case "while":
            guard let test = args.first else { return .nil }
            while !Self.isNil(try eval(test)) { _ = try progn(args.dropFirst()) }
            return .nil
        case "dolist", "dotimes":
            let spec = try args.first.map(Self.elements) ?? []
            guard case .symbol(let variable)? = spec.first, spec.count >= 2 else { throw Signal(message: "Bad \(name)") }
            let source = try eval(spec[1])
            let items = name == "dolist" ? try Self.elements(source) : []
            let count = name == "dolist" ? items.count : max(0, try Self.int(source))
            pending.append([source])
            defer { pending.removeLast() }
            // A new binding each time round, as closures over the variable see it.
            for i in 0..<count {
                steps += 1
                if steps > Self.stepLimit { throw Signal(message: "Evaluation took too long") }
                _ = try binding([variable: name == "dolist" ? items[i] : .integer(i)]) { try progn(args.dropFirst()) }
            }
            if spec.count > 2 {
                return try binding([variable: name == "dotimes" ? .integer(count) : .nil]) { try eval(spec[2]) }
            }
            return .nil
        case "with-output-to-string":
            outputs.append("")
            do {
                _ = try progn(args)
            } catch {
                outputs.removeLast()
                throw error
            }
            return .string(outputs.removeLast())
        case "ignore-errors":
            do { return try progn(args) } catch is Signal { return .nil }
        case "condition-case":
            guard args.count >= 2 else { throw Signal(message: "Bad condition-case") }
            do {
                return try eval(args[1])
            } catch let signal as Signal {
                // Every error has the `error` condition as well as its own.
                let conditions = ["error", "t"] + (signal.symbol.map { [$0] } ?? [])
                for handler in args.dropFirst(2) {
                    let parts = try Self.elements(handler)
                    guard let condition = parts.first else { continue }
                    let names = ((try? Self.elements(condition)) ?? [condition]).compactMap(\.symbol)
                    guard names.contains(where: conditions.contains) else {
                        if signal.symbol == nil, !names.isEmpty { throw Unsupported(what: "condition-case on \(names.joined(separator: " "))") }
                        continue
                    }
                    var bindings: [String: Sexp] = [:]
                    if let variable = args[0].symbol, variable != "nil" {
                        bindings[variable] = signal.symbol.flatMap { symbol in signal.data.map { .list([.symbol(symbol)] + $0) } } ?? Self.unknownError
                    }
                    return try binding(bindings) { try progn(parts.dropFirst()) }
                }
                throw signal
            }
        default:
            return try moreSpecial(name, args)
        }
    }

    /// Calls a function value: a symbol naming one, or a lambda list.
    public func call(_ function: Sexp, _ args: [Sexp]) throws -> Sexp {
        switch function {
        case .symbol(let name): return try callNamed(name, args)
        case .list(let items) where Self.isClosure(function):
            guard closures.indices.contains(items[1].integer!) else { throw Unsupported(what: "a closure as a list") }
            let saved = dynamicOnly
            dynamicOnly = false
            defer { dynamicOnly = saved }
            return try apply(parameters: items[2], body: items.dropFirst(3), args, scope: closures[items[1].integer!])
        case .list(let items) where items.first == .symbol("lambda") && items.count >= 2:
            guard lexical else { return try apply(parameters: items[1], body: items.dropFirst(2), args, scope: nil) }
            // Under lexical binding, a lambda list runs outside the caller's local frames, with
            // dynamic binding.
            let saved = dynamicOnly
            dynamicOnly = true
            defer { dynamicOnly = saved }
            return try apply(parameters: items[1], body: items.dropFirst(2), args, scope: [])
        default:
            throw Signal(message: "Invalid function: \(function.description)")
        }
    }

    /// Binds `parameters` to `args` and runs `body`, in `scope`'s frames instead of the
    /// caller's when given.
    private func apply(parameters: Sexp, body: ArraySlice<Sexp>, _ args: [Sexp], scope: [Frame]?) throws -> Sexp {
        var bindings: [String: Sexp] = [:]
        var mode = "required"
        var i = 0
        for parameter in try Self.elements(parameters) {
            guard case .symbol(let p) = parameter else { throw Signal(message: "Bad lambda list") }
            if p == "&optional" || p == "&rest" {
                mode = p
                continue
            }
            if mode == "&rest" {
                bindings[p] = Self.list(Array(args.dropFirst(i)))
                i = args.count
            } else if i < args.count {
                bindings[p] = args[i]
                i += 1
            } else if mode == "&optional" {
                bindings[p] = .nil
            } else {
                throw Signal(message: "Wrong number of arguments")
            }
        }
        if i < args.count { throw Signal(message: "Wrong number of arguments") }
        guard let scope else { return try binding(bindings) { try progn(body) } }
        let caller = scopes
        hiddenScopes.append(caller)
        scopes = [scopes[0]] + scope
        defer {
            scopes = caller
            hiddenScopes.removeLast()
        }
        return try binding(bindings) { try progn(body) }
    }

    func callNamed(_ name: String, _ args: [Sexp]) throws -> Sexp {
        guard let function = functions[name] else { throw Unsupported(what: "function \(name)") }
        try refuseClosures(name, args)
        inPlaceVariable = nil
        return try function(self, args)
    }

    static func arity(_ args: [Sexp], _ range: ClosedRange<Int>, _ name: String) throws {
        guard range.contains(args.count) else { throw Signal(message: "Wrong number of arguments: \(name), \(args.count)") }
    }

    // MARK: - Functions

    private static func core(_ lisp: Elisp) {
        func arithmetic(_ name: String, identity: Int, _ intOp: @escaping (Int, Int) -> (Int, Bool), _ floatOp: @escaping (Double, Double) -> Double) {
            lisp.define(name) { _, args in
                let numbers = try args.map(number)
                guard var result = numbers.first else { return .integer(identity) }
                if numbers.count == 1, name == "-" {
                    switch result {
                    case .int(let i):
                        guard i != .min else { throw Unsupported(what: "integer size") }
                        return .integer(-i)
                    case .float(let d): return .float(-d)
                    }
                }
                for n in numbers.dropFirst() {
                    switch (result, n) {
                    case (.int(let a), .int(let b)):
                        let (value, overflow) = intOp(a, b)
                        if overflow { throw Unsupported(what: "integer size") }
                        result = .int(value)
                    default:
                        result = .float(floatOp(result.double, n.double))
                    }
                }
                return sexp(result)
            }
        }
        arithmetic("+", identity: 0, { $0.addingReportingOverflow($1) }, +)
        arithmetic("-", identity: 0, { $0.subtractingReportingOverflow($1) }, -)
        arithmetic("*", identity: 1, { $0.multipliedReportingOverflow(by: $1) }, *)
        lisp.define("/") { _, args in
            try arity(args, 1...Int.max, "/")
            let numbers = try args.map(number)
            let floating = numbers.contains { if case .float = $0 { true } else { false } }
            if numbers.count == 1 { return try sexp(divide(.int(1), numbers[0], floating: floating)) }
            var result = numbers[0]
            for n in numbers.dropFirst() { result = try divide(result, n, floating: floating) }
            return sexp(result)
        }
        lisp.define("%") { _, args in
            try arity(args, 2...2, "%")
            let b = try int(args[1])
            guard b != 0 else { throw Signal(message: "Arithmetic error") }
            let (r, overflow) = try int(args[0]).remainderReportingOverflow(dividingBy: b)
            if overflow { throw Unsupported(what: "integer size") }
            return .integer(r)
        }
        lisp.define("mod") { _, args in
            try arity(args, 2...2, "mod")
            switch (try number(args[0]), try number(args[1])) {
            case (.int(let a), .int(let b)):
                guard b != 0 else { throw Signal(message: "Arithmetic error") }
                let (r, overflow) = a.remainderReportingOverflow(dividingBy: b)
                if overflow { throw Unsupported(what: "integer size") }
                return .integer(r != 0 && (r < 0) != (b < 0) ? r + b : r)
            case (let a, let b):
                let r = fmod(a.double, b.double)
                return .float(r != 0 && (r < 0) != (b.double < 0) ? r + b.double : r)
            }
        }
        lisp.define("1+") { _, args in try arity(args, 1...1, "1+"); return try sexp(add(number(args[0]), 1)) }
        lisp.define("1-") { _, args in try arity(args, 1...1, "1-"); return try sexp(add(number(args[0]), -1)) }
        lisp.define("abs") { _, args in
            try arity(args, 1...1, "abs")
            switch try number(args[0]) {
            case .int(let i):
                guard i != .min else { throw Unsupported(what: "integer size") }
                return .integer(abs(i))
            case .float(let d): return .float(abs(d))
            }
        }
        for name in ["max", "min"] {
            lisp.define(name) { _, args in
                try arity(args, 1...Int.max, name)
                let numbers = try args.map(number)
                let floating = numbers.contains { if case .float = $0 { true } else { false } }
                var best = numbers[0]
                for n in numbers.dropFirst() where name == "max" ? n.double > best.double : n.double < best.double { best = n }
                return floating ? .float(best.double) : sexp(best)
            }
        }
        for name in ["floor", "ceiling", "round", "truncate"] {
            lisp.define(name) { _, args in
                try arity(args, 1...2, name)
                var x = try number(args[0]).double
                if args.count == 2, !isNil(args[1]) {
                    let divisor = try number(args[1]).double
                    guard divisor != 0 else { throw Signal(message: "Arithmetic error") }
                    x /= divisor
                } else if case .int(let i) = try number(args[0]) {
                    return .integer(i)
                }
                let rule: FloatingPointRoundingRule = switch name {
                case "floor": .down
                case "ceiling": .up
                case "round": .toNearestOrEven
                default: .towardZero
                }
                guard let i = Int(exactly: x.rounded(rule)) else { throw Signal(message: "Arithmetic overflow error") }
                return .integer(i)
            }
        }
        lisp.define("float") { _, args in try arity(args, 1...1, "float"); return .float(try number(args[0]).double) }
        for (name, op) in [("=", { (a: Double, b: Double) in a == b }), ("<", { $0 < $1 }), (">", { $0 > $1 }), ("<=", { $0 <= $1 }), (">=", { $0 >= $1 })] {
            lisp.define(name) { _, args in
                try arity(args, 1...Int.max, name)
                let numbers = try args.map(number)
                for (a, b) in zip(numbers, numbers.dropFirst()) {
                    let holds: Bool = switch (a, b) {
                    case (.int(let x), .int(let y)): op(Double(x), Double(y)) && (name != "=" || x == y)
                    default: op(a.double, b.double)
                    }
                    if !holds { return .nil }
                }
                return t
            }
        }
        lisp.define("/=") { _, args in
            try arity(args, 2...2, "/=")
            return bool(try number(args[0]).double != (try number(args[1])).double)
        }
        lisp.define("zerop") { _, args in try arity(args, 1...1, "zerop"); return bool(try number(args[0]).double == 0) }
        lisp.define("not") { _, args in try arity(args, 1...1, "not"); return bool(isNil(args[0])) }
        lisp.define("null") { _, args in try arity(args, 1...1, "null"); return bool(isNil(args[0])) }
        lisp.define("eq") { _, args in try arity(args, 2...2, "eq"); return bool(eq(args[0], args[1])) }
        lisp.define("eql") { _, args in try arity(args, 2...2, "eql"); return bool(eq(args[0], args[1])) }
        lisp.define("equal") { _, args in try arity(args, 2...2, "equal"); return bool(normalized(args[0]) == normalized(args[1])) }
        lisp.define("numberp") { _, args in
            try arity(args, 1...1, "numberp")
            return bool((try? number(args[0])) != nil && args[0].character == nil)
        }
        lisp.define("integerp") { _, args in try arity(args, 1...1, "integerp"); return bool(args[0].integer != nil) }
        lisp.define("floatp") { _, args in
            try arity(args, 1...1, "floatp")
            if case .float = args[0] { return t }
            return .nil
        }
        lisp.define("stringp") { _, args in try arity(args, 1...1, "stringp"); return bool(args[0].string != nil) }
        lisp.define("listp") { _, args in
            try arity(args, 1...1, "listp")
            switch args[0] {
            case .list, .dotted: return t
            default: return bool(isNil(args[0]))
            }
        }
        lisp.define("consp") { _, args in
            try arity(args, 1...1, "consp")
            switch args[0] {
            case .list(let items): return bool(!items.isEmpty)
            case .dotted: return t
            default: return .nil
            }
        }
        lisp.define("symbolp") { _, args in try arity(args, 1...1, "symbolp"); return bool(args[0].symbol != nil || isNil(args[0])) }

        // Lists.
        lisp.define("car") { _, args in try arity(args, 1...1, "car"); return try car(args[0]) }
        lisp.define("cdr") { _, args in try arity(args, 1...1, "cdr"); return try cdr(args[0]) }
        lisp.define("cadr") { _, args in try arity(args, 1...1, "cadr"); return try car(cdr(args[0])) }
        lisp.define("cddr") { _, args in try arity(args, 1...1, "cddr"); return try cdr(cdr(args[0])) }
        lisp.define("cons") { _, args in try arity(args, 2...2, "cons"); return cons(args[0], args[1]) }
        lisp.define("list") { _, args in list(args) }
        lisp.define("nth") { _, args in
            try arity(args, 2...2, "nth")
            var v = args[1]
            for _ in 0..<max(0, try int(args[0])) { v = try cdr(v) }
            return try car(v)
        }
        lisp.define("nthcdr") { _, args in
            try arity(args, 2...2, "nthcdr")
            var v = args[1]
            for _ in 0..<max(0, try int(args[0])) { v = try cdr(v) }
            return v
        }
        lisp.define("elt") { _, args in
            try arity(args, 2...2, "elt")
            let items = try sequence(args[0])
            let i = try int(args[1])
            if case .list = args[0], i >= items.count { return .nil }
            guard items.indices.contains(i) else { throw Signal(message: "Args out of range") }
            return items[i]
        }
        lisp.define("aref") { _, args in
            try arity(args, 2...2, "aref")
            let items = try sequence(args[0])
            let i = try int(args[1])
            guard items.indices.contains(i) else { throw Signal(message: "Args out of range") }
            return items[i]
        }
        lisp.define("append") { _, args in
            guard let last = args.last else { return .nil }
            var items: [Sexp] = []
            for arg in args.dropLast() { items += try sequence(arg) }
            switch last {
            case .list(let rest): return .list(items + rest)
            case .dotted(let rest, let tail): return .dotted(items + rest, tail)
            case _ where isNil(last): return list(items)
            default: return items.isEmpty ? last : .dotted(items, last)
            }
        }
        lisp.define("length") { _, args in
            try arity(args, 1...1, "length")
            return .integer(try sequence(args[0]).count)
        }
        lisp.define("reverse") { _, args in
            try arity(args, 1...1, "reverse")
            if case .string(let s) = args[0] { return .string(String(s.reversed())) }
            return list(try elements(args[0]).reversed())
        }
        lisp.define("number-sequence") { _, args in
            try arity(args, 1...3, "number-sequence")
            let from = try int(args[0])
            guard args.count > 1, !isNil(args[1]) else { return .list([.integer(from)]) }
            let to = try int(args[1])
            let step = args.count > 2 && !isNil(args[2]) ? try int(args[2]) : 1
            guard step != 0 else { throw Signal(message: "The increment can not be zero") }
            let span = Double(to) - Double(from)
            guard span / Double(step) < Double(Self.lengthLimit) else { throw Signal(message: "Too many elements for number-sequence") }
            return list(Array(stride(from: from, through: to, by: step)).map { .integer($0) })
        }
        for name in ["memq", "member", "memql"] {
            lisp.define(name) { _, args in
                try arity(args, 2...2, name)
                var rest = args[1]
                while case .list(let items) = rest, let first = items.first {
                    if name == "member" ? normalized(first) == normalized(args[0]) : eq(first, args[0]) { return rest }
                    rest = list(Array(items.dropFirst()))
                }
                return .nil
            }
        }
        for name in ["assoc", "assq"] {
            lisp.define(name) { _, args in
                try arity(args, 2...3, name)
                for pair in try elements(args[1]) {
                    guard let key = try? car(pair) else { continue }
                    if name == "assoc" ? normalized(key) == normalized(args[0]) : eq(key, args[0]) { return pair }
                }
                return .nil
            }
        }
        lisp.define("identity") { _, args in try arity(args, 1...1, "identity"); return args[0] }
        lisp.define("ignore") { _, _ in .nil }
        lisp.define("funcall") { lisp, args in
            try arity(args, 1...Int.max, "funcall")
            return try lisp.call(args[0], Array(args.dropFirst()))
        }
        lisp.define("apply") { lisp, args in
            try arity(args, 1...Int.max, "apply")
            let spread = args.count > 1 ? Array(args[1..<(args.count - 1)]) + (try elements(args[args.count - 1])) : []
            return try lisp.call(args[0], spread)
        }
        lisp.define("mapcar") { lisp, args in
            try arity(args, 2...2, "mapcar")
            return list(try sequence(args[1]).map { try lisp.call(args[0], [$0]) })
        }
        lisp.define("mapc") { lisp, args in
            try arity(args, 2...2, "mapc")
            for item in try sequence(args[1]) { _ = try lisp.call(args[0], [item]) }
            return args[1]
        }
        lisp.define("mapconcat") { lisp, args in
            try arity(args, 1...3, "mapconcat")
            let separator = args.count > 2 ? try string(args[2]) : ""
            return .string(try sequence(args[1]).map { try printedString(lisp.call(args[0], [$0])) }.joined(separator: separator))
        }
        lisp.define("delq") { _, args in
            try arity(args, 2...2, "delq")
            return list(try elements(args[1]).filter { !eq($0, args[0]) })
        }
        lisp.define("delete") { _, args in
            try arity(args, 2...2, "delete")
            return list(try elements(args[1]).filter { normalized($0) != normalized(args[0]) })
        }
        for name in ["error", "user-error"] {
            lisp.define(name) { _, args in
                let message = args.isEmpty ? "" : try format(args)
                throw Signal(message: message, symbol: name, data: [.string(message)])
            }
        }

        // Printing.
        for (name, escape) in [("princ", false), ("prin1", true), ("print", true)] {
            lisp.define(name) { lisp, args in
                try arity(args, 1...2, name)
                let text = printed(args[0], escape: escape)
                lisp.outputs[lisp.outputs.count - 1] += name == "print" ? "\n" + text + "\n" : text
                return args[0]
            }
        }
        lisp.define("terpri") { lisp, _ in
            lisp.outputs[lisp.outputs.count - 1] += "\n"
            return t
        }
        lisp.define("message") { lisp, args in
            guard !args.isEmpty, !isNil(args[0]) else { return .nil }
            let text = try format(args)
            lisp.messages += text + "\n"
            return .string(text)
        }
        lisp.define("prin1-to-string") { _, args in
            try arity(args, 1...2, "prin1-to-string")
            return .string(printed(args[0], escape: args.count < 2 || isNil(args[1])))
        }

        // Strings.
        lisp.define("concat") { _, args in .string(try args.map(printedString).joined()) }
        lisp.define("format") { _, args in .string(try format(args)) }
        lisp.define("format-message") { _, args in .string(try format(args)) }
        lisp.define("string=") { _, args in
            try arity(args, 2...2, "string=")
            return bool(try stringOrSymbol(args[0]) == (try stringOrSymbol(args[1])))
        }
        lisp.define("string-equal") { _, args in
            try arity(args, 2...2, "string-equal")
            return bool(try stringOrSymbol(args[0]) == (try stringOrSymbol(args[1])))
        }
        lisp.define("string<") { _, args in
            try arity(args, 2...2, "string<")
            return bool(Array(try stringOrSymbol(args[0]).unicodeScalars.map(\.value)).lexicographicallyPrecedes(try stringOrSymbol(args[1]).unicodeScalars.map(\.value)))
        }
        lisp.define("string-lessp") { lisp, args in try lisp.callNamed("string<", args) }
        lisp.define("upcase") { _, args in
            try arity(args, 1...1, "upcase")
            if case .integer(let c) = args[0] { return .integer(Int(String(try scalar(c)).uppercased().unicodeScalars.first!.value)) }
            return .string(try string(args[0]).uppercased())
        }
        lisp.define("downcase") { _, args in
            try arity(args, 1...1, "downcase")
            if case .integer(let c) = args[0] { return .integer(Int(String(try scalar(c)).lowercased().unicodeScalars.first!.value)) }
            return .string(try string(args[0]).lowercased())
        }
        // A letter is upcased after a character without word syntax, downcased after one with it.
        lisp.define("capitalize") { lisp, args in
            try arity(args, 1...1, "capitalize")
            let s = try string(args[0])
            guard s.unicodeScalars.allSatisfy(\.isASCII) else { throw Unsupported(what: "capitalize past ASCII") }
            var inWord = false
            var out = ""
            for c in s.unicodeScalars {
                out += inWord ? String(c).lowercased() : String(c).uppercased()
                inWord = lisp.syntax.isWord(c)
            }
            return .string(out)
        }
        lisp.define("substring") { _, args in
            try arity(args, 1...3, "substring")
            let chars = Array(try string(args[0]).unicodeScalars)
            func index(_ v: Sexp?, _ fallback: Int) throws -> Int {
                guard let v, !isNil(v) else { return fallback }
                let i = try int(v)
                return i < 0 ? chars.count + i : i
            }
            let from = try index(args.count > 1 ? args[1] : nil, 0)
            let to = try index(args.count > 2 ? args[2] : nil, chars.count)
            guard from >= 0, to <= chars.count, from <= to else { throw Signal(message: "Args out of range") }
            return .string(String(String.UnicodeScalarView(chars[from..<to])))
        }
        lisp.define("string-to-number") { _, args in
            try arity(args, 1...2, "string-to-number")
            return stringToNumber(try string(args[0]))
        }
        for name in ["number-to-string", "int-to-string"] {
            lisp.define(name) { _, args in
                try arity(args, 1...1, name)
                return .string(printed(sexp(try number(args[0]))))
            }
        }
        lisp.define("string-prefix-p") { _, args in
            try arity(args, 2...3, "string-prefix-p")
            return bool(try string(args[1]).hasPrefix(try string(args[0])))
        }
        lisp.define("string-suffix-p") { _, args in
            try arity(args, 2...3, "string-suffix-p")
            return bool(try string(args[1]).hasSuffix(try string(args[0])))
        }
        lisp.define("string-empty-p") { _, args in
            try arity(args, 1...1, "string-empty-p")
            return bool(try stringOrSymbol(args[0]).isEmpty)
        }
        lisp.define("string-trim") { _, args in
            try arity(args, 1...1, "string-trim")
            return .string(try string(args[0]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func add(_ n: Number, _ k: Int) throws -> Number {
        switch n {
        case .int(let i):
            let (sum, overflow) = i.addingReportingOverflow(k)
            if overflow { throw Unsupported(what: "integer size") }
            return .int(sum)
        case .float(let d): return .float(d + Double(k))
        }
    }

    /// A character code as a character.
    static func scalar(_ code: Int) throws -> Unicode.Scalar {
        guard code >= 0, code <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(code)) else {
            throw Signal(message: "Invalid character: \(code)")
        }
        return scalar
    }

    static func divide(_ a: Number, _ b: Number, floating: Bool) throws -> Number {
        if !floating, case .int(let x) = a, case .int(let y) = b {
            guard y != 0 else { throw Signal(message: "Arithmetic error") }
            let (q, overflow) = x.dividedReportingOverflow(by: y)
            if overflow { throw Unsupported(what: "integer size") }
            return .int(q)
        }
        return .float(a.double / b.double)
    }

    static func eq(_ a: Sexp, _ b: Sexp) -> Bool {
        switch (normalized(a), normalized(b)) {
        case (.symbol(let x), .symbol(let y)): x == y
        case (.integer(let x), .integer(let y)): x == y
        case (.float(let x), .float(let y)): x == y
        default: false
        }
    }

    /// Characters as integers and the empty list as nil, for comparing.
    static func normalized(_ v: Sexp) -> Sexp {
        switch v {
        case .character(let c): .integer(c)
        case .list(let items): items.isEmpty ? .nil : .list(items.map(normalized))
        case .dotted(let items, let last): .dotted(items.map(normalized), normalized(last))
        case .vector(let items): .vector(items.map(normalized))
        default: v
        }
    }

    static func sequence(_ v: Sexp) throws -> [Sexp] {
        switch v {
        case .string(let s): return s.unicodeScalars.map { .integer(Int($0.value)) }
        case .vector(let items): return items
        default: return try elements(v)
        }
    }

    static func stringOrSymbol(_ v: Sexp) throws -> String {
        if case .symbol(let s) = v { return s }
        return try string(v)
    }

    /// What `concat` and `mapconcat` accept: strings, and lists or vectors of characters.
    static func printedString(_ v: Sexp) throws -> String {
        switch v {
        case .string(let s): return s
        case _ where isNil(v): return ""
        case .list, .vector:
            return String(String.UnicodeScalarView(try sequence(v).map { try scalar(try int($0)) }))
        default: throw Signal(message: "Wrong type argument: sequencep, \(v.description)")
        }
    }

    /// `string-to-number` in base 10.
    static func stringToNumber(_ s: String) -> Sexp {
        let trimmed = s.drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        guard let r = trimmed.range(of: "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?", options: .regularExpression) else { return .integer(0) }
        let text = String(trimmed[r])
        if text.range(of: "^[-+]?[0-9]+$", options: .regularExpression) != nil, let i = Int(text.hasPrefix("+") ? String(text.dropFirst()) : text) {
            return .integer(i)
        }
        if text.range(of: "^[-+]?[0-9]+\\.$", options: .regularExpression) != nil, let i = Int(text.dropLast().replacingOccurrences(of: "+", with: "")) {
            return .integer(i)
        }
        return .float(Double(text) ?? 0)
    }

    /// `format`.
    static func format(_ args: [Sexp]) throws -> String {
        let spec = Array(try string(args[0]))
        var out = ""
        var next = 1
        var i = 0
        func argument() throws -> Sexp {
            guard next < args.count else { throw Signal(message: "Not enough arguments for format string") }
            defer { next += 1 }
            return args[next]
        }
        while i < spec.count {
            let c = spec[i]
            i += 1
            guard c == "%" else {
                out.append(c)
                continue
            }
            var flags = ""
            while i < spec.count, "-+ #0".contains(spec[i]) {
                flags.append(spec[i])
                i += 1
            }
            var width = ""
            while i < spec.count, spec[i].isNumber {
                width.append(spec[i])
                i += 1
            }
            var precision: Int?
            if i < spec.count, spec[i] == "." {
                i += 1
                var digits = ""
                while i < spec.count, spec[i].isNumber {
                    digits.append(spec[i])
                    i += 1
                }
                precision = Int(digits) ?? 0
            }
            guard i < spec.count else { throw Signal(message: "Format string ends in middle of format specifier") }
            let conversion = spec[i]
            i += 1
            var text: String
            switch conversion {
            case "%":
                out.append("%")
                continue
            case "s", "S":
                text = printed(try argument(), escape: conversion == "S")
                if let precision { text = String(text.prefix(precision)) }
            case "d", "o", "x", "X":
                let value: Int
                switch try number(try argument()) {
                case .int(let n): value = n
                case .float(let d):
                    guard let n = Int(exactly: d.rounded(.towardZero)) else { throw Signal(message: "Arithmetic overflow") }
                    value = n
                }
                text = String(format: "%" + flags + width + (precision.map { ".\($0)" } ?? "") + (conversion == "d" ? "ld" : "l" + String(conversion)), value)
                out += text
                continue
            case "c":
                text = String(try scalar(try int(try argument())))
            case "e", "f", "g":
                let value = try number(try argument()).double
                out += String(format: "%" + flags + width + (precision.map { ".\($0)" } ?? "") + String(conversion), value)
                continue
            default:
                throw Signal(message: "Invalid format operation %\(conversion)")
            }
            let pad = max(0, (Int(width) ?? 0) - text.count)
            out += flags.contains("-") ? text + String(repeating: " ", count: pad) : String(repeating: " ", count: pad) + text
        }
        return out
    }
}

extension Sexp {
    var character: Int? { if case .character(let c) = self { return c } else { return nil } }
}

extension LispReader {
    /// The first form in `text` and the number of characters it spans, as `forward-sexp`
    /// would read it.
    public static func readFirst(_ text: String) throws -> (sexp: Sexp, length: Int) {
        var reader = Reader(Array(text.unicodeScalars))
        let sexp = try reader.form()
        let consumed = String(String.UnicodeScalarView(reader.chars[..<reader.index]))
        return (sexp, consumed.count)
    }
}
