import Foundation
import OrgCore

/// Settings, folders, capture templates and key bindings read from an Emacs configuration
/// without running it: `setq`-style forms with values Orgstar can work out, inside `after!`,
/// `with-eval-after-load`, `use-package` and the like. For Doom, Doom's own org defaults are
/// read first, as they apply under your config.
public struct EmacsImport: Sendable {
    public enum Change: Sendable, Equatable {
        /// A `config.toml` setting.
        case setting(key: String, value: TOML.Value)
        /// A folder to add (`org-directory`, folders of `org-agenda-files`).
        case folder(String)
        /// A `[[template]]` table for capture.toml.
        case capture(key: String, toml: String)
        /// A `[[bind]]` table for keymap.toml.
        case binding(keys: String, command: String, mode: String?)
        /// An `[org-structure-template-alist]` entry for config.toml.
        case structureTemplate(key: String, type: String)
    }

    public struct Item: Sendable, Identifiable {
        public let id: Int
        /// The Emacs variable or binding, as it reads in the file.
        public let name: String
        /// What it becomes in Orgstar, for the review list.
        public let summary: String
        /// `config.el:27`, or `Doom default` for Doom's own settings.
        public let source: String
        public let change: Change
    }

    public struct Note: Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let reason: String
        public let source: String
    }

    public var items: [Item] = []
    /// Org settings and bindings Orgstar has no equivalent for.
    public var unsupported: [Note] = []
    /// Values worked out at run time, which reading can't follow.
    public var unreadable: [Note] = []
    /// Files that couldn't be read, with why.
    public var problems: [String] = []
    /// Variables that aren't about org or the editor, left alone.
    public var skipped = 0
    /// Doom's own org defaults Orgstar has no use for, not listed one by one.
    public var doomDefaultsLeftOut = 0
    public var isDoom = false

    // MARK: - Finding the configuration

    /// The configuration files in `folder` (a Doom folder, an `.emacs.d`) or the file itself.
    public static func files(in location: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [location] }
        return ["init.el", "config.el", "custom.el"].map { location.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where an Emacs configuration usually is, first found first.
    public static func defaultLocations() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let doom = environment["DOOMDIR"] { candidates.append(URL(fileURLWithPath: doom)) }
        candidates += [".config/doom", ".doom.d", ".config/emacs", ".emacs.d"].map { home.appendingPathComponent($0) }
        candidates.append(home.appendingPathComponent(".emacs"))
        return candidates.filter { !files(in: $0).isEmpty && !isDoomInstall($0) }
    }

    /// Doom's own source folder, which holds `lisp/doom.el`, isn't a user configuration.
    static func isDoomInstall(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("lisp/doom.el").path)
    }

    /// Doom's org module and core defaults, if Doom is installed.
    static func doomDefaultFiles() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let environment = ProcessInfo.processInfo.environment
        let installs = ([environment["EMACSDIR"]].compactMap { $0 }.map { URL(fileURLWithPath: $0) })
            + [".config/emacs", ".emacs.d"].map { home.appendingPathComponent($0) }
        guard let install = installs.first(where: isDoomInstall) else { return [] }
        var files = [install.appendingPathComponent("lisp/doom-emacs.el")]
        var moduleRoots = [install.appendingPathComponent("modules")]
        if let sources = try? FileManager.default.contentsOfDirectory(at: install.appendingPathComponent("sources"), includingPropertiesForKeys: nil) {
            moduleRoots += sources.map { $0.appendingPathComponent("modules") }
        }
        if let org = moduleRoots.map({ $0.appendingPathComponent("lang/org/config.el") }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            files.insert(org, at: 0)
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Reading

    /// Reads `files`, and for a Doom configuration Doom's own defaults under them.
    public static func scan(_ files: [URL], doomDefaults: [URL]? = nil) -> EmacsImport {
        var sources: [(name: String, text: String, priority: Int)] = []
        var result = EmacsImport()
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                result.problems.append("Can't read \(url.path)")
                continue
            }
            sources.append((url.lastPathComponent, text, 1))
        }
        result.isDoom = sources.contains { $0.text.contains("(doom!") || $0.text.contains("(map! ") || $0.text.contains("(after! ") }
        if result.isDoom {
            for url in doomDefaults ?? doomDefaultFiles() {
                if let text = try? String(contentsOf: url, encoding: .utf8) { sources.insert(("Doom", text, 0), at: 0) }
            }
        }
        var scanner = Scanner()
        for source in sources {
            do {
                let forms = try LispReader.read(source.text)
                for form in forms {
                    scanner.visit(form.sexp, source: source.priority == 0 ? "Doom default" : "\(source.name):\(form.line)",
                                  priority: source.priority, deferred: false, insideDefun: false, doom: source.priority == 0)
                }
            } catch {
                result.problems.append("\(source.name): \(error)")
            }
        }
        result.build(from: scanner)
        return result
    }

    struct Assignment {
        let name: String
        let value: Sexp
        let source: String
        /// Doom defaults, then the config, then what runs after a package loads.
        let rank: Int
    }

    struct Binding {
        let keys: String
        let command: Sexp
        let modes: [String?]
        let source: String
    }

    struct Scanner {
        var assignments: [Assignment] = []
        var bindings: [Binding] = []
        /// `(add-to-list 'org-structure-template-alist '("el" . "src emacs-lisp"))` entries.
        var addedTemplates: [(entry: Sexp, source: String)] = []
        var usesEvil = false
        var order = 0

        mutating func assign(_ name: String, _ value: Sexp, _ source: String, priority: Int, deferred: Bool) {
            assignments.append(Assignment(name: name, value: value, source: source, rank: priority * 2 + (deferred ? 1 : 0)))
        }

        mutating func visit(_ form: Sexp, source: String, priority: Int, deferred: Bool, insideDefun: Bool, doom: Bool) {
            guard let items = form.elements, let head = form.head else { return }
            let args = Array(items.dropFirst())
            func body(_ forms: ArraySlice<Sexp>, deferred: Bool) {
                for f in forms { visit(f, source: source, priority: priority, deferred: deferred, insideDefun: insideDefun, doom: doom) }
            }
            switch head {
            case "setq", "setq-default", "setq!", "setopt", "csetq":
                var i = 0
                while i + 1 < args.count {
                    if let name = args[i].symbol { assign(name, args[i + 1], source, priority: priority, deferred: deferred) }
                    i += 2
                }
            case "add-to-list":
                if args.count >= 2, unquote(args[0])?.symbol == "org-structure-template-alist", let entry = unquote(args[1]) {
                    addedTemplates.append((entry, source))
                }
            case "defvar", "defcustom":
                // Only sets a variable nothing set, so under every assignment.
                if args.count >= 2, let name = args[0].symbol { assign(name, args[1], source, priority: -1, deferred: false) }
            case "custom-set-variables":
                for arg in args {
                    guard let entry = unquote(arg)?.elements, entry.count >= 2, let name = entry[0].symbol else { continue }
                    assign(name, .list([.symbol("quote"), entry[1]]), source, priority: priority, deferred: deferred)
                }
            case "after!", "with-eval-after-load", "eval-after-load", "use-package!", "use-package":
                if head.hasPrefix("use-package") {
                    var i = 1
                    var section = ""
                    while i < args.count {
                        if let keyword = args[i].symbol, keyword.hasPrefix(":") {
                            section = keyword
                        } else if section == ":config" || section == ":init" {
                            visit(args[i], source: source, priority: priority, deferred: true, insideDefun: insideDefun, doom: doom)
                        } else if section == ":custom", let pair = args[i].elements, pair.count >= 2, let name = pair[0].symbol {
                            assign(name, pair[1], source, priority: priority, deferred: true)
                        }
                        i += 1
                    }
                } else {
                    let forms = head == "eval-after-load" ? args.dropFirst().compactMap(unquote) : Array(args.dropFirst())
                    body(forms[...], deferred: true)
                }
            case "progn", "when", "unless", "if", "let", "let*", "with-no-warnings":
                let skip = ["let", "let*", "when", "unless", "if"].contains(head) ? 1 : 0
                body(args.dropFirst(skip), deferred: deferred)
            case "defun", "defun!", "add-hook!":
                // Doom sets org's defaults in the functions its module runs when org loads.
                if doom, head == "defun" { body(args.dropFirst(2), deferred: true) }
            case "doom!":
                usesEvil = args.contains { $0.symbol == "evil" || $0.head == "evil" }
            case "map!":
                if !doom { bindings += mapBindings(args, prefix: "", modes: [nil], source: source) }
            case "define-key", "keymap-set", "evil-define-key", "evil-define-key*", "global-set-key", "keymap-global-set":
                guard !doom else { break }
                var rest = args
                var modes: [String?] = [nil]
                if head.hasPrefix("evil-define-key"), let state = rest.first {
                    modes = evilStates(state)
                    rest = Array(rest.dropFirst())
                }
                if !head.hasPrefix("global"), head != "keymap-global-set" { rest = Array(rest.dropFirst()) }
                var i = 0
                while i + 1 < rest.count {
                    if let keys = keyString(rest[i]) { bindings.append(Binding(keys: keys, command: rest[i + 1], modes: modes, source: source)) }
                    i += 2
                }
            default:
                break
            }
        }

        func evilStates(_ sexp: Sexp) -> [String?] {
            let names = (unquote(sexp)?.elements ?? [unquote(sexp) ?? sexp]).compactMap(\.symbol)
            let modes = names.compactMap { name -> String? in
                switch name {
                case "normal", "motion": "normal"
                case "insert": "insert"
                case "visual": "visual"
                default: nil
                }
            }
            return modes.isEmpty ? [nil] : modes
        }

        /// `(kbd "C-c x")` or `"C-c x"` (keymap-set); key vectors such as `[f5]` are skipped.
        func keyString(_ sexp: Sexp) -> String? {
            if let s = sexp.string { return s }
            if sexp.head == "kbd", let s = sexp.elements?.dropFirst().first?.string { return s }
            return nil
        }

        /// Doom's `map!`: `:leader`, `:localleader`, `:prefix`, state keywords such as `:n`
        /// and `:nv`, `:map`, `:desc`, and nested groups.
        func mapBindings(_ args: [Sexp], prefix: String, modes: [String?], source: String) -> [Binding] {
            var result: [Binding] = []
            var prefix = prefix
            var modes = modes
            var i = 0
            while i < args.count {
                let arg = args[i]
                if let keyword = arg.symbol, keyword.hasPrefix(":") {
                    switch keyword {
                    case ":leader":
                        prefix = "SPC"
                        modes = ["normal"]
                    case ":localleader":
                        prefix = "SPC m"
                        modes = ["normal"]
                    case ":prefix", ":prefix-map":
                        if i + 1 < args.count {
                            let p = args[i + 1].string ?? args[i + 1].elements?.first?.string ?? ""
                            prefix = [prefix, p].filter { !$0.isEmpty }.joined(separator: " ")
                        }
                        i += 1
                    case ":desc", ":map", ":mode", ":after", ":when", ":unless":
                        i += 1
                    default:
                        let states = keyword.dropFirst()
                        let mapped = states.compactMap { c -> String? in
                            switch c {
                            case "n", "m": "normal"
                            case "i": "insert"
                            case "v": "visual"
                            default: nil
                            }
                        }
                        if !mapped.isEmpty { modes = Array(Set(mapped)).sorted() }
                    }
                } else if let group = arg.elements, arg.head?.hasPrefix(":") == true || group.first?.string != nil && group.count > 2 {
                    result += mapBindings(group, prefix: prefix, modes: modes, source: source)
                } else if let key = arg.string, i + 1 < args.count {
                    let keys = [prefix, key].filter { !$0.isEmpty }.joined(separator: " ")
                    result.append(Binding(keys: keys, command: args[i + 1], modes: modes, source: source))
                    i += 1
                }
                i += 1
            }
            return result
        }
    }

    // MARK: - Values

    /// `(font-spec :family "JetBrains Mono" :size 14)`, or `"JetBrains Mono-14"`.
    static func fontSpec(_ sexp: Sexp) -> (family: String?, size: Int?)? {
        if let name = sexp.string {
            let parts = name.split(separator: "-")
            if parts.count > 1, let size = Int(parts.last!) { return (parts.dropLast().joined(separator: "-"), size) }
            return (name, nil)
        }
        guard sexp.head == "font-spec", let args = sexp.elements?.dropFirst() else { return nil }
        let list = Array(args)
        var family: String?
        var size: Int?
        var i = 0
        while i + 1 < list.count {
            switch list[i].symbol {
            case ":family": family = list[i + 1].string
            case ":size":
                if let n = list[i + 1].integer { size = n }
                if case .float(let d) = list[i + 1] { size = Int(d.rounded()) }
            default: break
            }
            i += 2
        }
        return family == nil && size == nil ? nil : (family, size)
    }

    static func unquote(_ sexp: Sexp) -> Sexp? {
        if let items = sexp.elements, items.count == 2, items[0].symbol == "quote" || items[0].symbol == "function" { return items[1] }
        if case .list(let items) = sexp, items.count == 2, items[0].symbol == "\\`" { return items[1] }
        return nil
    }

    /// What a form evaluates to, for the few forms configurations build values with; nil
    /// when reading can't tell.
    static func evaluate(_ sexp: Sexp, _ env: [String: Sexp]) -> Sexp? {
        switch sexp {
        case .string, .integer, .float, .character, .vector: return sexp
        case .symbol(let name):
            if name == "t" || name == "nil" || name.hasPrefix(":") { return sexp }
            return env[name]
        case .dotted: return nil
        case .list(let items):
            guard let head = items.first?.symbol else { return nil }
            let args = Array(items.dropFirst())
            switch head {
            case "quote", "function": return args.first
            case "\\`":
                guard let inner = args.first else { return nil }
                return backquote(inner, env)
            case "list":
                let values = args.compactMap { evaluate($0, env) }
                return values.count == args.count ? .list(values) : nil
            case "concat":
                let parts = args.compactMap { evaluate($0, env)?.string }
                return parts.count == args.count ? .string(parts.joined()) : nil
            case "expand-file-name", "file-name-concat":
                let parts = args.compactMap { evaluate($0, env)?.string }
                guard parts.count == args.count, !parts.isEmpty else { return nil }
                if head == "expand-file-name" {
                    let name = parts[0]
                    if name.hasPrefix("/") || name.hasPrefix("~") || parts.count == 1 { return .string(name) }
                    return .string((parts[1] as NSString).appendingPathComponent(name))
                }
                return .string(parts.dropFirst().reduce(parts[0]) { ($0 as NSString).appendingPathComponent($1) })
            case "file-name-as-directory":
                guard let s = args.first.flatMap({ evaluate($0, env)?.string }) else { return nil }
                return .string(s.hasSuffix("/") ? s : s + "/")
            default:
                return nil
            }
        }
    }

    /// A backquoted form with its `,` and `,@` parts evaluated.
    static func backquote(_ sexp: Sexp, _ env: [String: Sexp]) -> Sexp? {
        guard case .list(let items) = sexp else {
            if case .dotted(let items, let last) = sexp {
                let values = items.compactMap { backquote($0, env) }
                guard values.count == items.count, let tail = backquote(last, env) else { return nil }
                return .dotted(values, tail)
            }
            return sexp
        }
        if items.count == 2, items[0].symbol == "," { return evaluate(items[1], env) }
        var out: [Sexp] = []
        for item in items {
            if case .list(let parts) = item, parts.count == 2, parts[0].symbol == ",@" {
                guard let spliced = evaluate(parts[1], env)?.elements else { return nil }
                out += spliced
            } else {
                guard let value = backquote(item, env) else { return nil }
                out.append(value)
            }
        }
        return .list(out)
    }

    // MARK: - Results

    static let orgRelated = ["org-", "appt-", "display-line-numbers", "fill-column", "evil-", "doom-font", "doom-variable-pitch-font", "doom-theme", "calendar-week-start-day"]

    mutating func build(from scanner: Scanner) {
        var next = 0
        func id() -> Int { next += 1; return next }
        // The last assignment of each variable wins, those after a package loads over the rest.
        var winners: [String: Assignment] = [:]
        var env: [String: Sexp] = [:]
        for assignment in scanner.assignments.enumerated().sorted(by: { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }).map(\.element) {
            winners[assignment.name] = assignment
            if let value = Self.evaluate(assignment.value, env) { env[assignment.name] = value }
        }
        if isDoom || scanner.usesEvil {
            items.append(Item(id: id(), name: isDoom ? "Doom Emacs" : "evil-mode", summary: "keymap = \"doom\"", source: "", change: .setting(key: "keymap", value: .string("doom"))))
        }
        for name in winners.keys.sorted() {
            let assignment = winners[name]!
            guard Self.orgRelated.contains(where: { name.hasPrefix($0) }) else {
                if assignment.rank >= 2 { skipped += 1 }
                continue
            }
            if name == "doom-font", let spec = Self.fontSpec(assignment.value) {
                if let family = spec.family {
                    items.append(Item(id: id(), name: name, summary: "font = \"\(family)\"", source: assignment.source, change: .setting(key: "font", value: .string(family))))
                }
                if let size = spec.size {
                    items.append(Item(id: id(), name: name, summary: "font-size = \(size)", source: assignment.source, change: .setting(key: "font-size", value: .integer(size))))
                }
                continue
            }
            guard let value = Self.evaluate(assignment.value, env) else {
                if assignment.rank < 2 {
                    doomDefaultsLeftOut += 1
                    continue
                }
                unreadable.append(Note(id: id(), name: name, reason: "worked out when Emacs runs: \(assignment.value.description.prefix(80))", source: assignment.source))
                continue
            }
            let before = unsupported.count
            convert(name, value, source: assignment.source, env: env, id: id)
            if assignment.rank < 2, unsupported.count > before {
                doomDefaultsLeftOut += unsupported.count - before
                unsupported.removeLast(unsupported.count - before)
            }
        }
        for (entry, source) in scanner.addedTemplates { structureTemplates([entry], source: source, id: id) }
        // One item per folder.
        var folders: Set<String> = []
        items.removeAll { item in
            guard case .folder(let path) = item.change else { return false }
            let key = (path as NSString).expandingTildeInPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !folders.insert(key).inserted
        }
        for binding in scanner.bindings {
            guard let commandName = Self.unquote(binding.command)?.symbol ?? binding.command.symbol else {
                unsupported.append(Note(id: id(), name: binding.keys, reason: "bound to code, not a command", source: binding.source))
                continue
            }
            guard let command = Self.commands[commandName] else {
                unsupported.append(Note(id: id(), name: "\(binding.keys) → \(commandName)", reason: "orgstar has no such command", source: binding.source))
                continue
            }
            guard let keys = KeySequence.parse(binding.keys).map(KeySequence.format) else {
                unsupported.append(Note(id: id(), name: binding.keys, reason: "keys orgstar can't read", source: binding.source))
                continue
            }
            let modes = isDoom ? binding.modes.map { $0 ?? "normal" } : binding.modes
            for mode in Array(Set(modes.map { $0 ?? "" })).sorted() {
                items.append(Item(id: id(), name: "\(keys) → \(commandName)", summary: mode.isEmpty ? command : "\(command) in \(mode) state",
                                  source: binding.source, change: .binding(keys: keys, command: command, mode: mode.isEmpty ? nil : mode)))
            }
        }
    }

    mutating func convert(_ name: String, _ value: Sexp, source: String, env: [String: Sexp] = [:], id: () -> Int) {
        func add(_ key: String, _ toml: TOML.Value, _ summary: String? = nil) {
            items.append(Item(id: id(), name: name, summary: summary ?? "\(key) = \(UserConfig.format(toml))", source: source, change: .setting(key: key, value: toml)))
        }
        func note(_ reason: String) { unsupported.append(Note(id: id(), name: name, reason: reason, source: source)) }
        let truthy = value.symbol != "nil" && value.elements?.isEmpty != true
        switch name {
        case "fill-column", "org-tags-column", "appt-message-warning-time", "org-deadline-warning-days":
            guard let n = value.integer else { return note("not a number") }
            add(name, .integer(n))
        case "org-insert-heading-respect-content", "org-list-allow-alphabetical", "org-hide-emphasis-markers", "org-pretty-entities",
             "org-cycle-hide-drawer-startup", "org-cycle-hide-block-startup", "org-use-speed-commands", "org-startup-with-inline-images",
             "org-startup-indented", "org-hide-leading-stars", "org-startup-align-all-tables", "org-startup-truncated",
             "org-enforce-todo-dependencies", "org-enforce-todo-checkbox-dependencies",
             "org-agenda-todo-ignore-with-date", "org-agenda-tags-todo-honor-ignore-options", "org-clock-out-remove-zero-time-clocks",
             "org-agenda-sort-notime-is-late", "org-agenda-sort-noeffort-is-high":
            add(name, .bool(truthy))
        case "org-archive-location":
            guard let location = value.string, location.contains("::") else { return note("not a file::heading location") }
            add(name, .string(location))
        case "org-use-tag-inheritance":
            if let regexp = value.string { add(name, .string("{\(regexp)}")) } else if let tags = value.elements, !tags.isEmpty {
                add(name, .string(tags.compactMap(\.string).joined(separator: " ")))
            } else { add(name, .string(truthy ? "t" : "nil")) }
        case "org-tags-exclude-from-inheritance":
            add(name, .string((value.elements ?? []).compactMap(\.string).joined(separator: " ")))
        case "org-tag-alist":
            guard let alist = Self.tagAlist(value.elements ?? []) else { return note("entries orgstar can't read") }
            add(name, .string(alist))
        case "org-track-ordered-property-with-tag":
            if let tag = value.string { add(name, .string(tag)) } else { add(name, .string(truthy ? "t" : "nil")) }
        case "org-agenda-log-mode-items":
            let items = (value.elements ?? []).compactMap(\.symbol).filter { ["closed", "clock", "state"].contains($0) }
            guard !items.isEmpty || value.symbol == "nil" else { return note("not a list of closed, clock and state") }
            add(name, .string(items.joined(separator: " ")))
        case "org-agenda-todo-ignore-scheduled", "org-agenda-todo-ignore-deadlines", "org-agenda-todo-ignore-timestamp":
            if let days = value.integer { add(name, .string("\(days)")) } else if let symbol = value.symbol, AgendaOptions.TodoIgnore(symbol) != nil { add(name, .string(symbol)) } else { note("unexpected value \(value.description)") }
        case "org-structure-template-alist":
            structureTemplates(value.elements ?? [], source: source, id: id)
        case "org-agenda-dim-blocked-tasks":
            add(name, .string(value.symbol == "invisible" ? "invisible" : truthy ? "t" : "nil"))
        case "org-hide-drawer-startup", "org-hide-block-startup":
            add(name == "org-hide-drawer-startup" ? "org-cycle-hide-drawer-startup" : "org-cycle-hide-block-startup", .bool(truthy))
        case "org-M-RET-may-split-line":
            if let alist = value.elements, !alist.isEmpty {
                // `((default . nil))`: the default entry, as most configurations write it.
                let entry = alist.first { if case .dotted(let k, _) = $0 { return k.first?.symbol == "default" } else { return false } }
                if case .dotted(_, let v)? = entry { add(name, .bool(v.symbol != "nil")) } else { note("per-context values aren't supported") }
            } else {
                add(name, .bool(truthy))
            }
        case "org-agenda-sorting-strategy":
            // `((agenda habit-down time-up) (todo urgency-down))`, or one list for every view.
            func keys(_ items: [Sexp]) -> String? {
                let names = items.compactMap(\.symbol)
                guard names.count == items.count else { return nil }
                if let bad = names.first(where: { !AgendaSort.keys.contains($0) }) { note("\(bad) isn't supported"); return nil }
                return names.joined(separator: " ")
            }
            let entries = value.elements ?? []
            if entries.allSatisfy({ $0.symbol != nil }) {
                if let s = keys(entries) { for view in ["agenda", "todo", "tags", "search"] { add("org-agenda-sorting-strategy.\(view)", .string(s)) } }
            } else {
                for entry in entries {
                    var items = entry.elements
                    if case .dotted(let head, let tail) = entry { items = head + (tail.elements ?? [tail]) }
                    guard let items, let view = items.first?.symbol, ["agenda", "todo", "tags", "search"].contains(view) else { continue }
                    if let s = keys(Array(items.dropFirst())) { add("org-agenda-sorting-strategy.\(view)", .string(s)) }
                }
            }
        case "org-agenda-prefix-format":
            if let s = value.string {
                for view in ["agenda", "todo", "tags"] { add("org-agenda-prefix-format.\(view)", .string(s)) }
            } else {
                for entry in value.elements ?? [] {
                    guard case .dotted(let key, let format) = entry, let view = key.first?.symbol, let s = format.string else { continue }
                    if ["agenda", "todo", "tags"].contains(view) { add("org-agenda-prefix-format.\(view)", .string(s)) }
                }
            }
        case "org-log-done", "org-log-reschedule", "org-log-redeadline":
            switch value.symbol {
            case "nil": add(name, .string("nil"))
            case "time", "t": add(name, .string("time"))
            case "note": add(name, .string("note"))
            default: note("unexpected value \(value.description)")
            }
        case "org-log-into-drawer":
            if let s = value.string { add(name, .string(s)) } else { add(name, .string(truthy ? "LOGBOOK" : "")) }
        case "display-line-numbers-type":
            add(name, .bool(truthy), truthy && value.symbol != "t" ? "display-line-numbers-type = true (orgstar numbers lines absolutely)" : nil)
        case "org-agenda-span":
            let days: Int? = value.integer ?? ["day": 1, "week": 7, "fortnight": 14, "month": 30, "year": 365][value.symbol ?? ""]
            guard let days else { return note("unknown span \(value.description)") }
            add(name, .integer(days))
        case "org-agenda-start-on-weekday":
            if value.symbol == "nil" { add(name, .string("nil")) } else if let day = value.integer, (0...6).contains(day) { add(name, .string("\(day)")) } else { note("not nil or a weekday from 0 to 6") }
        case "org-clock-idle-time":
            // nil is never; a number is minutes.
            if value.symbol == "nil" { add(name, .integer(0)) } else if let minutes = value.integer, minutes > 0 { add(name, .integer(minutes)) } else { note("not a number of minutes") }
        case "org-clock-rounding-minutes":
            guard let n = value.integer, n >= 0 else { return note("not a number of minutes") }
            add(name, .integer(n))
        case "org-clock-in-switch-to-state":
            if let state = value.string { add(name, .string(state)) } else if value.symbol == "nil" { add(name, .string("")) } else { note("a function isn't supported; use a keyword") }
        case "org-clock-out-when-done":
            if let states = value.elements, !states.isEmpty {
                let names = states.compactMap(\.string)
                guard names.count == states.count else { return note("not a list of keywords") }
                add(name, .string(names.joined(separator: " ")))
            } else {
                add(name, .string(truthy ? "t" : "nil"))
            }
        case "org-clock-into-drawer":
            if let drawer = value.string { add(name, .string(drawer)) } else if let n = value.integer { add(name, .string("\(n)")) } else { add(name, .string(truthy ? "t" : "nil")) }
        case "org-clock-history-length":
            guard let length = value.integer, length > 0 else { return note("not a positive number") }
            add(name, .integer(length))
        case "org-agenda-start-day":
            if value.symbol == "nil" { add(name, .string("+0d")) } else if let s = value.string, UserConfig.dayOffset(s) != nil { add(name, .string(s)) } else { note("only day offsets such as \"-3d\" are supported") }
        case "org-todo-keywords":
            let sequences = (value.elements ?? []).compactMap { $0.elements }.filter { $0.count > 1 }.map { $0.dropFirst().compactMap(\.string) }
            let lines = sequences.filter { !$0.contains { $0.contains(where: \.isWhitespace) } }.map { $0.joined(separator: " ") }
            guard !lines.isEmpty else { return note("unexpected value") }
            if lines.count < sequences.count {
                note("\(sequences.count - lines.count) sequence(s) with spaces in a keyword left out; #+TODO syntax can't write them")
            }
            if (value.elements ?? []).contains(where: { $0.elements?.first?.symbol == "type" }) { note("type sequences are read as sequences") }
            add(name, .string(lines.joined(separator: "\n")))
        case "org-directory":
            guard let path = value.string else { return note("not a folder") }
            items.append(Item(id: id(), name: name, summary: "add folder \(path)", source: source, change: .folder(path)))
        case "org-agenda-files":
            let paths = (value.elements ?? [value]).compactMap(\.string)
            guard !paths.isEmpty else { return note("not a list of files or folders") }
            for path in paths {
                let folder = path.hasSuffix(".org") ? (path as NSString).deletingLastPathComponent : path
                items.append(Item(id: id(), name: name, summary: "add folder \(folder)", source: source, change: .folder(folder)))
            }
        case "org-capture-templates":
            for entry in value.elements ?? [] { captureTemplate(entry, source: source, env: env, id: id) }
        case "doom-font":
            note("not a font-spec orgstar can read")
        case "doom-variable-pitch-font":
            note("orgstar uses one font; set it with doom-font or [theme] font")
        case "doom-theme":
            note("Emacs themes aren't read; set colors under [theme] in config.toml")
        default:
            note("orgstar has no equivalent")
        }
    }

    /// `org-tag-alist` in `#+TAGS` syntax: `("work" . ?w)` is `work(w)`, `(:startgroup)` `{`,
    /// `(:startgrouptag)` `[`, `(:grouptags)` `:`, and `(:newline)` a new line.
    static func tagAlist(_ entries: [Sexp]) -> String? {
        var lines: [[String]] = [[]]
        for entry in entries {
            let marker = entry.elements?.first?.symbol ?? entry.symbol
            switch marker {
            case ":startgroup": lines[lines.count - 1].append("{")
            case ":endgroup": lines[lines.count - 1].append("}")
            case ":startgrouptag": lines[lines.count - 1].append("[")
            case ":endgrouptag": lines[lines.count - 1].append("]")
            case ":grouptags": lines[lines.count - 1].append(":")
            case ":newline": lines.append([])
            default:
                if let tag = entry.string {
                    lines[lines.count - 1].append(tag)
                } else if case .dotted(let head, let key) = entry, head.count == 1, let tag = head[0].string {
                    guard case .character(let code) = key, let scalar = Unicode.Scalar(code) else {
                        lines[lines.count - 1].append(tag)
                        continue
                    }
                    lines[lines.count - 1].append("\(tag)(\(Character(scalar)))")
                } else {
                    return nil
                }
            }
        }
        return lines.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `("el" . "src emacs-lisp")` entries that aren't Org's own.
    mutating func structureTemplates(_ entries: [Sexp], source: String, id: () -> Int) {
        for entry in entries {
            guard case .dotted(let head, let tail) = entry, head.count == 1, let key = head[0].string, let type = tail.string else {
                unsupported.append(Note(id: id(), name: "org-structure-template-alist", reason: "an entry that isn't (\"key\" . \"type\")", source: source))
                continue
            }
            if StructureTemplate.defaults.contains(StructureTemplate(key: key, type: type)) { continue }
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                unsupported.append(Note(id: id(), name: "structure template \"\(key)\"", reason: "config.toml keys are letters, digits, _ and -", source: source))
                continue
            }
            items.removeAll { if case .structureTemplate(key, _) = $0.change { true } else { false } }
            items.append(Item(id: id(), name: "structure template \"\(key)\"", summary: "<\(key) inserts a \(type) block", source: source,
                              change: .structureTemplate(key: key, type: type)))
        }
    }

    mutating func captureTemplate(_ entry: Sexp, source: String, env: [String: Sexp] = [:], id: () -> Int) {
        guard let parts = entry.elements, parts.count >= 2, let key = parts[0].string else { return }
        let name = parts[1].string ?? key
        guard parts.count >= 5, let type = parts[2].symbol, let target = parts[3].elements, let kind = target.first?.symbol,
              let template = parts[4].string else {
            // A key and a name only: a group of templates.
            if parts.count == 2 { return }
            unsupported.append(Note(id: id(), name: "capture \"\(key)\"", reason: "a template that isn't a string", source: source))
            return
        }
        guard ["entry", "item", "checkitem", "plain", "table-line"].contains(type) else {
            unsupported.append(Note(id: id(), name: "capture \"\(key)\"", reason: "\(type) templates aren't supported", source: source))
            return
        }
        func quoted(_ s: String) -> String { UserConfig.format(.string(s)) }
        var toml = "[[template]]\nkey = \(quoted(key))\nname = \(quoted(name))\ntype = \(quoted(type))\n"
        // `org-capture-expand-file`: a variable's value, or a form evaluated.
        let strings = target.dropFirst().compactMap { $0.string ?? Self.evaluate($0, env)?.string }
        // Property list after the template: `:prepend t :empty-lines 1 …`.
        var properties: [String: Sexp] = [:]
        let rest = Array(parts.dropFirst(5))
        for i in stride(from: 0, to: rest.count - 1, by: 2) { if let name = rest[i].symbol { properties[name] = rest[i + 1] } }
        let allStrings = strings.count == target.count - 1
        var treeType = properties[":tree-type"]?.symbol
        let place: String? = switch kind {
        case "file" where strings.count == 1 && target.count == 2:
            "file = \(quoted(strings[0]))\n"
        case "file+headline" where strings.count == 2 && target.count == 3:
            "file = \(quoted(strings[0]))\nheadline = \(quoted(strings[1]))\n"
        case "file+olp" where strings.count >= 2 && allStrings:
            "file = \(quoted(strings[0]))\nolp = \(quoted(strings.dropFirst().joined(separator: "/")))\n"
        case "file+olp+datetree" where strings.count >= 1 && allStrings:
            "file = \(quoted(strings[0]))\ndatetree = true\n" + (strings.count > 1 ? "olp = \(quoted(strings.dropFirst().joined(separator: "/")))\n" : "")
        case let legacy where (legacy == "file+datetree" || legacy == "file+weektree") && strings.count == 1 && target.count == 2:
            "file = \(quoted(strings[0]))\ndatetree = true\n"
        case "id" where strings.count == 1 && target.count == 2:
            "id = \(quoted(strings[0]))\n"
        case "clock" where target.count == 1:
            "clock = true\n"
        default:
            nil
        }
        guard let place else {
            unsupported.append(Note(id: id(), name: "capture \"\(key)\"", reason: "target \(kind) isn't supported", source: source))
            return
        }
        if kind == "file+weektree" { treeType = "week" }
        toml += place
        if let treeType {
            guard ["day", "week", "month"].contains(treeType) else {
                unsupported.append(Note(id: id(), name: "capture \"\(key)\"", reason: ":tree-type \(treeType) isn't supported", source: source))
                return
            }
            if treeType != "day" { toml += "tree-type = \(quoted(treeType))\n" }
        }
        for flag in ["prepend", "immediate-finish", "jump-to-captured", "clock-in", "clock-keep", "clock-resume"] {
            if let value = properties[":" + flag], value.symbol != "nil" { toml += "\(flag) = true\n" }
        }
        for count in ["empty-lines", "empty-lines-before", "empty-lines-after"] {
            if let n = properties[":" + count]?.integer { toml += "\(count) = \(n)\n" }
        }
        if let pos = properties[":table-line-pos"]?.string { toml += "table-line-pos = \(quoted(pos))\n" }
        let ignored = properties.keys.filter { ![":prepend", ":immediate-finish", ":jump-to-captured", ":clock-in", ":clock-keep", ":clock-resume", ":empty-lines", ":empty-lines-before", ":empty-lines-after", ":tree-type", ":table-line-pos"].contains($0) }
        if !ignored.isEmpty {
            unsupported.append(Note(id: id(), name: "capture \"\(key)\"", reason: "\(ignored.sorted().joined(separator: ", ")) left out", source: source))
        }
        toml += "template = \(quoted(template))\n"
        items.append(Item(id: id(), name: "capture \"\(key)\" \(name)", summary: "capture template \"\(key)\"", source: source, change: .capture(key: key, toml: toml)))
    }

    /// Emacs commands and the Orgstar commands that do the same.
    static let commands: [String: String] = [
        "org-todo": "org.todo.cycle", "org-shiftright": "org.todo.next", "org-shiftleft": "org.todo.previous", "org-priority-up": "org.priority.up", "org-priority-down": "org.priority.down",
        "org-metaleft": "org.heading.promote", "org-metaright": "org.heading.demote", "org-do-promote": "org.heading.promote", "org-do-demote": "org.heading.demote",
        "org-promote-subtree": "org.subtree.promote", "org-demote-subtree": "org.subtree.demote",
        "org-shiftmetaleft": "org.subtree.promote", "org-shiftmetaright": "org.subtree.demote",
        "org-move-subtree-up": "org.subtree.up", "org-move-subtree-down": "org.subtree.down", "org-metaup": "org.subtree.up", "org-metadown": "org.subtree.down",
        "org-insert-heading": "org.heading.insert", "org-meta-return": "org.heading.insert",
        "org-insert-heading-respect-content": "org.heading.insert-after-subtree", "+org/insert-item-below": "org.heading.insert-after-subtree",
        "org-insert-todo-heading": "org.heading.insert-todo",
        "org-next-visible-heading": "org.heading.next", "org-previous-visible-heading": "org.heading.previous",
        "org-forward-heading-same-level": "org.heading.forward-same-level", "org-backward-heading-same-level": "org.heading.backward-same-level",
        "outline-up-heading": "org.heading.up", "org-up-element": "org.heading.up",
        "org-set-tags-command": "org.tags.set", "org-set-property": "org.property.read-and-set",
        "org-toggle-checkbox": "org.checkbox.toggle", "org-ctrl-c-ctrl-c": "org.ctrl-c-ctrl-c", "+org/dwim-at-point": "org.dwim",
        "org-schedule": "org.schedule", "org-deadline": "org.deadline", "org-time-stamp": "org.timestamp.active", "org-timestamp": "org.timestamp.active",
        "org-time-stamp-inactive": "org.timestamp.inactive", "org-timestamp-inactive": "org.timestamp.inactive",
        "org-fill-paragraph": "org.fill-paragraph", "org-cycle": "org.cycle", "org-shifttab": "org.cycle-global", "org-global-cycle": "org.cycle-global",
        "org-table-create": "org.table.create", "org-table-align": "org.table.align", "org-table-recalculate": "org.table.recalc",
        "org-table-insert-row": "org.table.insert-row", "org-table-insert-column": "org.table.insert-column",
        "org-table-delete-column": "org.table.delete-column", "org-table-kill-row": "org.table.kill-row", "org-table-insert-hline": "org.table.insert-hline",
        "org-babel-execute-src-block": "org.babel.execute", "org-clock-in": "app.clock.in", "org-clock-out": "app.clock.out",
        "org-clock-cancel": "app.clock.cancel", "org-clock-goto": "app.clock.goto", "org-clock-in-last": "app.clock.in-last",
        "org-resolve-clocks": "app.clock.resolve", "org-clock-mark-default-task": "app.clock.default",
        "org-refile": "app.refile", "org-copy": "app.refile.copy", "org-refile-copy": "app.refile.copy", "org-archive-subtree": "app.archive", "org-archive-subtree-default": "app.archive",
        "org-capture": "app.capture", "org-agenda": "app.agenda", "org-agenda-list": "app.agenda",
        "save-buffer": "app.save", "find-file": "app.quick-open", "projectile-find-file": "app.quick-open", "+default/find-file-under-here": "app.quick-open",
        "execute-extended-command": "app.palette", "counsel-M-x": "app.palette",
        "isearch-forward": "edit.find", "isearch-backward": "edit.find", "consult-line": "edit.find", "+default/search-buffer": "edit.find", "swiper": "edit.find",
        "query-replace": "edit.replace", "query-replace-regexp": "edit.replace",
        "save-buffers-kill-terminal": "app.quit", "save-buffers-kill-emacs": "app.quit",
    ]
}

extension EmacsImport {
    /// Applies `items`: settings to `defaults` (and so config.toml), folders to the workspace,
    /// capture templates and key bindings appended to capture.toml and keymap.toml in
    /// `directory`, leaving out templates whose key is there already and bindings that are
    /// there already. Returns a summary.
    @MainActor
    public static func apply(
        _ items: [Item], defaults: UserDefaults = .standard, workspace: WorkspaceModel?, directory: URL = UserConfig.directory
    ) async -> String {
        var settings = 0, folders = 0, templates = 0, bindings = 0, blocks = 0
        var problems: [String] = []
        for item in items {
            guard case .setting(let key, let value) = item.change,
                  let setting = UserConfig.settings.first(where: { $0.path == key || $0.key == key }) else { continue }
            if let problem = UserConfig.store(value, setting, in: defaults) { problems.append(problem) } else { settings += 1 }
        }
        for item in items {
            guard case .folder(let path) = item.change else { continue }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard let workspace, FileManager.default.fileExists(atPath: url.path) else {
                problems.append("\(path) doesn't exist")
                continue
            }
            if workspace.roots.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == url.path }) { continue }
            do {
                try await workspace.addRoot(url)
                folders += 1
            } catch {
                problems.append("Can't add \(path): \(error.localizedDescription)")
            }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let captureFile = directory.appendingPathComponent("capture.toml")
        var capture = (try? String(contentsOf: captureFile, encoding: .utf8)) ?? ""
        let existingKeys = Set((try? TOML.parse(capture))?.compactMap { $0.values["key"]?.string } ?? [])
        var addedCapture = ""
        for item in items {
            guard case .capture(let key, let toml) = item.change, !existingKeys.contains(key) else { continue }
            addedCapture += "\n" + toml
            templates += 1
        }
        if !addedCapture.isEmpty {
            capture += (capture.isEmpty ? "# Capture templates. Imported from Emacs.\n" : "\n# Imported from Emacs.\n") + addedCapture
            try? capture.write(to: captureFile, atomically: true, encoding: .utf8)
        }
        let keymapFile = directory.appendingPathComponent("keymap.toml")
        var keymap = (try? String(contentsOf: keymapFile, encoding: .utf8)) ?? ""
        func binding(_ keys: String?, _ command: String?, _ mode: String?) -> String { [keys ?? "", command ?? "", mode ?? ""].joined(separator: "\u{0}") }
        var existingBindings = Set((try? TOML.parse(keymap))?.filter { $0.name == "bind" && $0.values["when"] == nil }
            .map { binding($0.values["keys"]?.string, $0.values["command"]?.string, $0.values["mode"]?.string) } ?? [])
        var addedKeys = ""
        for item in items {
            guard case .binding(let keys, let command, let mode) = item.change,
                  existingBindings.insert(binding(keys, command, mode)).inserted else { continue }
            addedKeys += "\n[[bind]]\nkeys = \(UserConfig.format(.string(keys)))\ncommand = \(UserConfig.format(.string(command)))\n"
            if let mode { addedKeys += "mode = \(UserConfig.format(.string(mode)))\n" }
            bindings += 1
        }
        if !addedKeys.isEmpty {
            keymap += (keymap.isEmpty ? "" : "\n") + "# Imported from Emacs.\n" + addedKeys
            try? keymap.write(to: keymapFile, atomically: true, encoding: .utf8)
        }
        // Into user defaults, from where ConfigSync writes them into config.toml.
        var rows = UserConfig.structureTemplates(defaults)
        for item in items {
            guard case .structureTemplate(let key, let type) = item.change else { continue }
            rows.removeAll { $0.key == key }
            rows.append(StructureTemplate(key: key, type: type))
            blocks += 1
        }
        if blocks > 0 { UserConfig.setStructureTemplates(rows, in: defaults) }
        func count(_ n: Int, _ word: String) -> String? { n == 0 ? nil : "\(n) \(word)\(n == 1 ? "" : "s")" }
        let done = [count(settings, "setting"), count(folders, "folder"), count(templates, "capture template"), count(bindings, "key binding"),
                    count(blocks, "structure template")].compactMap { $0 }
        var summary = done.isEmpty ? "Nothing new to import." : "Imported " + done.joined(separator: ", ") + "."
        if !problems.isEmpty { summary += " " + problems.joined(separator: "; ") + "." }
        return summary
    }
}
