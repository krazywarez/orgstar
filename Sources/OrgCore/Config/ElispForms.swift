import Foundation

// `defun`, `defvar`, `defconst`, `let-alist`, `pcase`, `cl-loop`, `cl-incf`, `cl-decf` and
// `save-match-data`.

extension Elisp {
    /// The special forms and macros beyond the core ones; nil when `name` isn't one.
    func moreSpecial(_ name: String, _ args: [Sexp]) throws -> Sexp? {
        switch name {
        case "defun": return try defun(args)
        case "defvar", "defconst": return try defineVariable(args, constant: name == "defconst")
        case "let-alist": return try letAlist(args)
        case "pcase": return try pcase(args)
        case "cl-loop": return try loop(args)
        case "cl-incf", "cl-decf": return try increment(args, decrement: name == "cl-decf")
        case "save-match-data":
            let saved = matchData
            defer { matchData = saved }
            return try progn(args)
        default: return nil
        }
    }

    func defun(_ args: [Sexp]) throws -> Sexp {
        guard args.count >= 2, case .symbol(let name) = args[0] else { throw Signal(message: "Malformed defun") }
        var body = Array(args.dropFirst(2))
        if body.count > 1, case .string = body[0] { body.removeFirst() }
        while let head = body.first?.head, head == "declare" || head == "interactive" { body.removeFirst() }
        let function = closure(.list([.symbol("lambda"), args[1]] + body))
        define(name) { lisp, values in try lisp.call(function, values) }
        defined.insert(name)
        return .symbol(name)
    }

    /// `defvar` sets a variable only when it has no global value; `defconst` always does.
    func defineVariable(_ args: [Sexp], constant: Bool) throws -> Sexp {
        guard case .symbol(let name)? = args.first, args.count <= 3 else { throw Signal(message: "Malformed \(constant ? "defconst" : "defvar")") }
        if constant, args.count < 2 { throw Signal(message: "Wrong number of arguments: defconst, 1") }
        specials.insert(name)
        if args.count > 1, constant || scopes[0].vars[name] == nil { scopes[0].vars[name] = try eval(args[1]) }
        return .symbol(name)
    }

    /// `let-alist`: `.key` and `.key.inner` in the body, outside inner `let-alist` bodies, bound
    /// to the alist's values.
    func letAlist(_ args: [Sexp]) throws -> Sexp {
        guard let first = args.first else { throw Signal(message: "Wrong number of arguments: let-alist, 0") }
        let alist = try eval(first)
        var names: Set<String> = []
        func search(_ form: Sexp) {
            switch form {
            case .symbol(let s) where s.hasPrefix("."): names.insert(s)
            case .list(let items) where items.first == .symbol("let-alist"): if items.count > 1 { search(items[1]) }
            case .list(let items), .vector(let items): items.forEach(search)
            case .dotted(let items, let last):
                if items.first == .symbol("let-alist") {
                    if items.count > 1 { search(items[1]) }
                } else {
                    items.forEach(search)
                    search(last)
                }
            default: break
            }
        }
        args.dropFirst().forEach(search)
        var bindings: [String: Sexp] = [:]
        for name in names {
            guard !name.hasPrefix("..") else { throw Unsupported(what: "let-alist \(name)") }
            var value = alist
            for key in name.dropFirst().split(separator: ".", omittingEmptySubsequences: false) {
                var pair = Sexp.nil
                for item in try Self.elements(value) {
                    if let car = try? Self.car(item), car == .symbol(String(key)), Self.isCons(item) {
                        pair = item
                        break
                    }
                }
                value = try Self.cdr(pair)
            }
            bindings[name] = value
        }
        return try binding(bindings) { try progn(args.dropFirst()) }
    }

    static func isCons(_ v: Sexp) -> Bool {
        switch v {
        case .list(let items): !items.isEmpty
        case .dotted: true
        default: false
        }
    }

    /// `pcase` with literal, symbol, quote, backquote and `pred` patterns.
    func pcase(_ args: [Sexp]) throws -> Sexp {
        guard let first = args.first else { throw Signal(message: "Wrong number of arguments: pcase, 0") }
        let value = try eval(first)
        for clause in args.dropFirst() {
            let parts = try Self.elements(clause)
            guard let pattern = parts.first else { continue }
            var bindings: [String: Sexp] = [:]
            if try matches(pattern, value, &bindings) { return try binding(bindings) { try progn(parts.dropFirst()) } }
        }
        return .nil
    }

    func matches(_ pattern: Sexp, _ value: Sexp, _ bindings: inout [String: Sexp]) throws -> Bool {
        switch pattern {
        case .symbol("_"):
            return true
        case .symbol(let s) where s.hasPrefix(":"):
            return value == pattern
        case .symbol(let s) where s != "nil" && s != "t":
            // A variable used twice must match the same object the second time.
            if let bound = bindings[s] { return Self.eq(bound, value) }
            bindings[s] = value
            return true
        case .integer, .character:
            return Self.eq(pattern, value)
        case .string:
            return pattern == value
        case .list(let items) where items.count == 2 && items[0] == .symbol("quote"):
            return Self.normalized(items[1]) == Self.normalized(value)
        case .list(let items) where items.count == 2 && items[0] == .symbol("\\`"):
            return try backquoted(items[1], value, &bindings)
        case .list(let items) where items.count == 2 && items[0] == .symbol("pred") && (items[1].symbol != nil || items[1].head == "lambda"):
            let soFar = bindings
            return !Self.isNil(try binding(soFar) { try call(closure(items[1]), [value]) })
        default:
            throw Unsupported(what: "pcase pattern \(pattern.description)")
        }
    }

    func backquoted(_ pattern: Sexp, _ value: Sexp, _ bindings: inout [String: Sexp]) throws -> Bool {
        switch pattern {
        case .list(let items) where items.count == 2 && items[0] == .symbol(","):
            return try matches(items[1], value, &bindings)
        case .list(let items) where items.first == .symbol(",@"):
            throw Unsupported(what: "pcase pattern ,@")
        case .list(let items) where !items.isEmpty:
            guard Self.isCons(value) else { return false }
            return try backquoted(items[0], Self.car(value), &bindings) && backquoted(Self.list(Array(items.dropFirst())), Self.cdr(value), &bindings)
        case .dotted(let items, let last):
            guard Self.isCons(value) else { return false }
            let rest = items.count == 1 ? last : .dotted(Array(items.dropFirst()), last)
            return try backquoted(items[0], Self.car(value), &bindings) && backquoted(rest, Self.cdr(value), &bindings)
        case .vector(let patterns):
            guard case .vector(let values) = value, values.count == patterns.count else { return false }
            for (p, v) in zip(patterns, values) where !(try backquoted(p, v, &bindings)) { return false }
            return true
        default:
            return Self.normalized(pattern) == Self.normalized(value)
        }
    }

    /// `cl-loop` with `for VAR in LIST`, `for VAR from START [to END]`, `collect`, `sum` and
    /// `do`.
    func loop(_ args: [Sexp]) throws -> Sexp {
        enum Iterator {
            case list(String)
            case range(String, limit: Sexp?)
        }
        var iterators: [Iterator] = []
        // What each `in` clause has left.
        var lists: [Int: Sexp] = [:]
        var actions: [(kind: String, forms: [Sexp])] = []
        scopes.append(Frame())
        defer { scopes.removeLast() }
        var i = 0
        func next() throws -> Sexp {
            guard i < args.count else { throw Signal(message: "Syntax error in cl-loop") }
            i += 1
            return args[i - 1]
        }
        while i < args.count {
            let word = try next()
            switch word.symbol {
            case "for":
                guard case .symbol(let variable) = try next() else { throw Unsupported(what: "cl-loop destructuring") }
                switch try next() {
                case .symbol("in"):
                    lists[iterators.count] = try eval(try next())
                    scopes[scopes.count - 1].vars[variable] = .nil
                    iterators.append(.list(variable))
                case .symbol("from"):
                    scopes[scopes.count - 1].vars[variable] = try eval(try next())
                    var limit: Sexp?
                    if i < args.count, args[i] == .symbol("to") {
                        i += 1
                        limit = try eval(try next())
                    }
                    iterators.append(.range(variable, limit: limit))
                case let other:
                    throw Unsupported(what: "cl-loop for \(variable) \(other.description)")
                }
            case "collect", "sum":
                actions.append((word.symbol!, [try next()]))
            case "do":
                var forms: [Sexp] = []
                while i < args.count, Self.isCons(args[i]) {
                    forms.append(args[i])
                    i += 1
                }
                actions.append(("do", forms))
            default:
                throw Unsupported(what: "cl-loop \(word.description)")
            }
        }
        guard !iterators.isEmpty else { throw Unsupported(what: "cl-loop without for") }
        guard Set(actions.map(\.kind)).subtracting(["do"]).count <= 1 else { throw Unsupported(what: "cl-loop with collect and sum") }
        var collected: [Sexp] = []
        var total = Sexp.integer(0)
        var first = true
        iterations: while true {
            steps += 1
            if steps > Self.stepLimit { throw Signal(message: "Evaluation took too long") }
            if !first {
                for (n, iterator) in iterators.enumerated() {
                    switch iterator {
                    case .list: lists[n] = try Self.cdr(lists[n]!)
                    case .range(let variable, _): assign(variable, try callNamed("+", [try value(variable), .integer(1)]))
                    }
                }
            }
            first = false
            for (n, iterator) in iterators.enumerated() {
                switch iterator {
                case .list(let variable):
                    guard Self.isCons(lists[n]!) else { break iterations }
                    assign(variable, try Self.car(lists[n]!))
                case .range(let variable, let limit):
                    if let limit, Self.isNil(try callNamed("<=", [try value(variable), limit])) { break iterations }
                }
            }
            for (kind, forms) in actions {
                switch kind {
                case "collect": collected.append(try eval(forms[0]))
                case "sum": total = try callNamed("+", [total, try eval(forms[0])])
                default: _ = try progn(forms)
                }
            }
        }
        if actions.contains(where: { $0.kind == "collect" }) { return Self.list(collected) }
        return actions.contains(where: { $0.kind == "sum" }) ? total : .nil
    }

    func increment(_ args: [Sexp], decrement: Bool) throws -> Sexp {
        let name = decrement ? "cl-decf" : "cl-incf"
        guard (1...2).contains(args.count) else { throw Signal(message: "Wrong number of arguments: \(name), \(args.count)") }
        guard case .symbol(let variable) = args[0] else { throw Unsupported(what: "\(name) on a place") }
        let current = try value(variable)
        let delta = args.count > 1 ? try eval(args[1]) : .integer(1)
        let new = try callNamed(decrement ? "-" : "+", [current, delta])
        assign(variable, new)
        return new
    }
}
