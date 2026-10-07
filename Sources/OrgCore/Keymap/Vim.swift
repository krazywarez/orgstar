import Foundation

/// Modal editing as Doom's evil gives it: normal, insert, visual and visual-line states;
/// counts, registers, operators with motions and text objects, `.` repeat, evil-snipe's `s`
/// and `S`, `Y` to the end of the line, and the unnamed register on the system clipboard.
/// Keys go in; edits, moves and commands come out for the editor to apply.
public struct Vim: Sendable {
    public enum Mode: String, Sendable {
        case normal, insert, visual
        case visualLine = "visual-line"
        case visualBlock = "visual-block"

        /// The keymap mode name for bindings.
        public var keymapMode: String {
            switch self {
            case .normal: "normal"
            case .insert: "insert"
            case .visual, .visualLine, .visualBlock: "visual"
            }
        }
    }

    public enum Action: Equatable, Sendable {
        /// Replace text and put the caret (and, in visual states, the selection) somewhere.
        case edit([TextEdit], caret: Int)
        case move(caret: Int)
        /// The selection to show in a visual state, `lowerBound..<upperBound`.
        case select(Range<Int>)
        case command(String)
        case undo(Int)
        case redo(Int)
        case setClipboard(String)
        /// Ask for a search pattern (`/`, `?`) or an ex command (`:`).
        case prompt(String)
        case message(String)
        /// `m`: a mark at this offset, for the editor to keep through edits.
        case setMark(Character, Int)
        /// A jump left this offset: the editor adds it to the jump list.
        case jumped(from: Int)
        /// C-o and C-i through the jump list.
        case jumpBack(Int)
        case jumpForward(Int)
        /// `q`: start recording keys into a register, or with nil stop.
        case recordMacro(Character?)
        /// `@`: play a register's keys, this many times.
        case playMacro(Character, Int)
        /// A block selection: one range per line.
        case selectBlock([Range<Int>])
        /// `gj`, `gk`: down (or, negative, up) by screen lines, which only the editor knows.
        case visualLines(Int)
    }

    public struct Context: Sendable {
        public var text: String
        public var caret: Int
        public var clipboard: String?
        /// Lines in a half page, for C-d and C-u.
        public var halfPage: Int
        /// Marks where the editor keeps them now; `'` and `` ` `` are the last jump's start.
        public var marks: [Character: Int]

        public init(text: String, caret: Int, clipboard: String? = nil, halfPage: Int = 15, marks: [Character: Int] = [:]) {
            self.text = text
            self.caret = caret
            self.clipboard = clipboard
            self.halfPage = halfPage
            self.marks = marks
        }
    }

    public internal(set) var mode: Mode = .normal
    /// Keys of the command being typed.
    public private(set) var pending: [KeyChord] = []
    var registers: [Character: (text: String, linewise: Bool)] = [:]
    /// What the clipboard held when this engine last wrote it, and whether that was whole lines.
    var clipboardRecord: (text: String, linewise: Bool)?
    var anchor = 0
    var goalColumn: Int?
    var lastFind: (kind: Character, char: String)?
    var lastSnipe: (forward: Bool, chars: String)?
    var lastSearch: (pattern: String, forward: Bool)?
    /// The keys and inserted text of the last change, for `.`.
    var lastChange: (keys: [KeyChord], inserted: String?)?
    var changeKeys: [KeyChord]?
    var insertStart = 0
    /// The caret when the command began, for commands that keep its column.
    var caretForApply = 0
    /// Typed in insert state since it began, kept by `inserted(_:)`.
    var insertedText = ""
    /// The last visual selection, for `gv`.
    var lastVisual: (anchor: Int, caret: Int, mode: Mode)?
    /// Marks the engine set this run, for a context without the editor's.
    var marks: [Character: Int] = [:]
    /// Where block `I`, `A` and `c` copy what was typed when insert state ends: the other lines,
    /// by number from 1, the column, and whether short lines are padded to it.
    var blockInsert: (lines: [Int], column: Int, pad: Bool)?
    /// The editor's marks for this key.
    var contextMarks: [Character: Int] = [:]
    /// Keys are going into a macro register.
    public internal(set) var recording = false
    var lastMacro: Character?
    /// `$` in block visual state: every line to its end.
    var blockToEnd = false

    public init() {}

    // MARK: - Feeding keys

    public mutating func feed(_ key: KeyChord, _ context: Context) -> [Action] {
        switch mode {
        case .insert:
            return insertKey(key, context)
        case .normal, .visual, .visualLine, .visualBlock:
            pending.append(key)
            let keys = pending
            caretForApply = context.caret
            contextMarks = context.marks
            var buffer = Buffer(context)
            switch parse(keys, &buffer, context) {
            case .incomplete:
                return []
            case .invalid:
                pending = []
                return []
            case .done(let actions):
                pending = []
                return actions
            }
        }
    }

    /// Text typed in insert state, recorded for `.`.
    public mutating func inserted(_ text: String) {
        insertedText += text
    }

    public mutating func deletedBackward() {
        if !insertedText.isEmpty { insertedText.removeLast() }
    }

    private mutating func insertKey(_ key: KeyChord, _ context: Context) -> [Action] {
        let buffer = Buffer(context)
        if key == KeyChord("ESC") || key == KeyChord("[", .control) || key == KeyChord("g", .control) {
            mode = .normal
            if var keys = changeKeys {
                keys.append(KeyChord("ESC"))
                lastChange = (keys, insertedText)
                changeKeys = nil
            }
            let caret = context.caret
            let lineStart = buffer.lineStart(caret)
            if let block = blockInsert {
                blockInsert = nil
                if !insertedText.isEmpty, !insertedText.contains("\n") { return replicateBlockInsert(block, buffer, caret: caret) }
            }
            return [.move(caret: caret > lineStart ? caret - 1 : caret)]
        }
        if key == KeyChord("w", .control) {
            let start = buffer.wordBackward(context.caret, bigWord: false, stopAtLine: true)
            guard start < context.caret else { return [] }
            return [.edit([TextEdit(range: start..<context.caret, replacement: "")], caret: start)]
        }
        if key == KeyChord("u", .control) {
            let start = buffer.firstNonBlank(buffer.lineStart(context.caret))
            let from = context.caret > start ? start : buffer.lineStart(context.caret)
            guard from < context.caret else { return [] }
            return [.edit([TextEdit(range: from..<context.caret, replacement: "")], caret: from)]
        }
        return []
    }

    /// Whether a key in insert state belongs to the text system.
    public func passesThrough(_ key: KeyChord) -> Bool {
        guard mode == .insert else { return false }
        return !(key == KeyChord("ESC") || key == KeyChord("[", .control) || key == KeyChord("g", .control)
            || key == KeyChord("w", .control) || key == KeyChord("u", .control))
    }

    public mutating func enterInsert(at caret: Int, keys: [KeyChord]) {
        mode = .insert
        insertStart = caret
        insertedText = ""
        changeKeys = keys
    }

    // MARK: - Parsing

    enum Parse {
        case incomplete
        case invalid
        case done([Action])
    }

    struct Command {
        var register: Character?
        var count: Int?
        var keys: ArraySlice<KeyChord>
    }

    /// `evil-shift-width`, which Doom keeps equal to `tab-width`: 8 in Org.
    static let shiftWidth = 8

    /// What `indent-according-to-mode` gives a line after `line` in Org: under a list item,
    /// its text's column; under a heading, none; otherwise `line`'s own indentation.
    static func indentation(for buffer: Buffer, line: Int) -> String {
        let text = buffer.substring(buffer.lineStart(line)..<buffer.lineEnd(line))
        let item = try! NSRegularExpression(pattern: "^[ \\t]*([-+*]|[0-9]+[.)])[ \\t]+")
        let ns = text as NSString
        if text.hasPrefix("*") { return "" }
        if let m = item.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return String(repeating: " ", count: m.range.length)
        }
        return String(text.prefix { $0 == " " || $0 == "\t" })
    }

    static func digit(_ key: KeyChord) -> Int? {
        guard key.modifiers.isEmpty, key.key.count == 1, let d = Int(key.key) else { return nil }
        return d
    }

    /// Reads `"r` and a count off the front of `keys`.
    static func prefix(_ keys: [KeyChord]) -> (register: Character?, count: Int?, rest: ArraySlice<KeyChord>)? {
        var rest = keys[...]
        var register: Character?
        if rest.first?.key == "\"", rest.first?.modifiers.isEmpty == true {
            guard rest.count >= 2 else { return nil }
            register = rest[rest.startIndex + 1].key == "SPC" ? " " : rest[rest.startIndex + 1].key.first
            rest = rest.dropFirst(2)
        }
        var count: Int?
        while let key = rest.first, let d = digit(key), !(d == 0 && count == nil) {
            count = (count ?? 0) * 10 + d
            rest = rest.dropFirst()
        }
        return (register, count, rest)
    }

    mutating func parse(_ keys: [KeyChord], _ buffer: inout Buffer, _ context: Context) -> Parse {
        guard let (register, count, rest) = Self.prefix(keys) else { return .incomplete }
        guard let first = rest.first else { return .incomplete }
        let visual = mode == .visual || mode == .visualLine
        let n = count ?? 1
        let caret = context.caret

        if mode == .visualBlock { return parseBlock(rest, &buffer, context, register: register, count: n, keys: keys) }
        if let result = parseExtras(rest, &buffer, context, register: register, count: count, keys: keys) { return result }

        // Operators.
        let operatorKeys: [String: String] = ["d": "d", "c": "c", "y": "y", ">": ">", "<": "<"]
        var op: String?
        var afterOp = rest.dropFirst()
        if first.modifiers.isEmpty, let o = operatorKeys[first.key] {
            op = o
        } else if first.key == "g", first.modifiers.isEmpty {
            guard let second = rest.dropFirst().first else { return .incomplete }
            if ["~", "u", "U", "c"].contains(second.key), second.modifiers.isEmpty {
                op = "g" + second.key
                afterOp = rest.dropFirst(2)
            }
        }
        if let op {
            if visual {
                let range = visualRange(buffer, caret)
                return .done(apply(op, range: range.range, linewise: range.linewise, buffer, register: register, keys: keys, count: n))
            }
            // A second count and the motion.
            guard let (_, count2, motionKeys) = Self.prefix(Array(afterOp)), let motionFirst = motionKeys.first else { return .incomplete }
            let total = n * (count2 ?? 1)
            let doubled = op.count == 1 ? op : String(op.last!)
            if motionFirst.key == doubled, motionFirst.modifiers.isEmpty, motionKeys.count == 1 || (op.count == 2 && motionFirst.key == String(op.last!)) {
                // dd, cc, yy, >>, <<, g~~, guu, gUU: whole lines.
                let startLine = buffer.lineStart(caret)
                var end = startLine
                for _ in 0..<total {
                    let next = buffer.lineEnd(end)
                    end = next < buffer.length ? next + 1 : next
                    if end >= buffer.length { break }
                }
                return .done(apply(op, range: startLine..<max(end, buffer.lineEnd(startLine)), linewise: true, buffer, register: register, keys: keys, count: total))
            }
            if motionFirst.key == "i" || motionFirst.key == "a", motionFirst.modifiers.isEmpty {
                guard motionKeys.count >= 2 else { return .incomplete }
                guard let object = textObject(motionFirst.key == "i", motionKeys[motionKeys.startIndex + 1], buffer, caret, count: total) else { return .invalid }
                // evil-org's subtree objects move point to the heading first.
                if motionKeys[motionKeys.startIndex + 1].key == "R" { caretForApply = buffer.lineStart(object.range.lowerBound) }
                return .done(apply(op, range: object.range, linewise: object.linewise, buffer, register: register, keys: keys, count: total))
            }
            var motionCaret = caret
            if op == "c", motionFirst.key == "w" || motionFirst.key == "W", motionFirst.modifiers.isEmpty,
               let c = buffer.char(caret), !Buffer.isBlank(c) {
                // cw acts as ce on a word.
                var end = caret
                for _ in 0..<total { end = buffer.wordEnd(end, bigWord: motionFirst.key == "W", fromInside: true) }
                return .done(apply(op, range: caret..<min(buffer.length, end + 1), linewise: false, buffer, register: register, keys: keys, count: total))
            }
            switch motion(Array(motionKeys), &buffer, &motionCaret, count: total, operatorPending: true) {
            case .incomplete: return .incomplete
            case .invalid: return .invalid
            case .moved(let target, let kind):
                var range: Range<Int>
                var linewise = false
                switch kind {
                case .linewise:
                    let a = buffer.lineStart(min(caret, target))
                    let b = buffer.lineEnd(max(caret, target))
                    range = a..<min(buffer.length, b + 1)
                    linewise = true
                case .inclusive:
                    range = min(caret, target)..<min(buffer.length, max(caret, target) + 1)
                case .exclusive:
                    range = min(caret, target)..<max(caret, target)
                    // dw at the end of a line stops at the line's end.
                    if motionFirst.key == "w" || motionFirst.key == "W", buffer.lineStart(range.upperBound) != buffer.lineStart(range.lowerBound), range.upperBound > range.lowerBound {
                        var end = buffer.lineEnd(range.lowerBound)
                        if end == range.lowerBound, total == 1 { end = min(buffer.length, end + 1) }
                        let upper = buffer.firstNonBlankOrEnd(buffer.lineStart(range.upperBound)) == range.upperBound
                            ? max(range.lowerBound, min(end, range.upperBound)) : range.upperBound
                        range = range.lowerBound..<(upper == range.lowerBound ? end : upper)
                        if buffer.lineStart(range.upperBound) != buffer.lineStart(range.lowerBound) {
                            range = range.lowerBound..<buffer.lineEnd(range.lowerBound)
                        }
                    }
                }
                return .done(apply(op, range: range, linewise: linewise, buffer, register: register, keys: keys, count: total))
            }
        }

        if visual, first.modifiers.isEmpty {
            switch first.key {
            case "ESC":
                lastVisual = (anchor, caret, mode)
                mode = .normal
                return .done([.move(caret: buffer.clampNormal(caret))])
            case "o":
                let old = anchor
                anchor = caret
                return .done(visualActions(buffer, old))
            case "x":
                let range = visualRange(buffer, caret)
                return .done(apply("d", range: range.range, linewise: range.linewise, buffer, register: register, keys: keys, count: n))
            case "~", "u", "U":
                let range = visualRange(buffer, caret)
                return .done(apply(first.key == "~" ? "g~" : "g" + first.key, range: range.range, linewise: range.linewise, buffer, register: register, keys: keys, count: n))
            case "J":
                let range = visualRange(buffer, caret)
                let lines = max(2, buffer.lineCount(range.range))
                mode = .normal
                return .done(join(buffer, at: range.range.lowerBound, lines: lines, keys: keys))
            case "p", "P":
                let range = visualRange(buffer, caret)
                guard let (text, linewise) = paste(register, context) else { return .done([]) }
                mode = .normal
                var replacement = text
                if linewise, !range.linewise { replacement = "\n" + text }
                if !linewise, range.linewise { replacement += "\n" }
                let removed = buffer.substring(range.range)
                var actions: [Action] = [.edit([TextEdit(range: range.range, replacement: replacement)], caret: range.range.lowerBound + (linewise ? 0 : max(0, replacement.utf16.count - 1)))]
                actions += store(removed, linewise: range.linewise, register: nil, yank: false)
                return .done(actions)
            case "v":
                if mode == .visual {
                    mode = .normal
                    return .done([.move(caret: buffer.clampNormal(caret))])
                }
                mode = .visual
                return .done(visualActions(buffer, caret))
            case "V":
                if mode == .visualLine {
                    mode = .normal
                    return .done([.move(caret: buffer.clampNormal(caret))])
                }
                mode = .visualLine
                return .done(visualActions(buffer, caret))
            case "i", "a":
                guard rest.count >= 2 else { return .incomplete }
                guard let object = textObject(first.key == "i", rest[rest.startIndex + 1], buffer, caret, count: n) else { return .invalid }
                if object.linewise { mode = .visualLine }
                anchor = object.range.lowerBound
                let end = max(object.range.lowerBound, object.range.upperBound - 1)
                return .done(visualActions(buffer, end))
            default:
                break
            }
        }

        if !visual {
            switch (first.key, first.modifiers) {
            case ("i", []), ("a", []), ("I", []), ("A", []), ("o", []), ("O", []):
                return .done(enterInsert(first.key, buffer, caret, keys: keys))
            case ("v", []):
                mode = .visual
                anchor = caret
                return .done(visualActions(buffer, caret))
            case ("V", []):
                mode = .visualLine
                anchor = caret
                return .done(visualActions(buffer, caret))
            case ("x", []), ("<delete>", []):
                guard let c = buffer.char(caret), c != 10 else { return .done([]) }
                let end = min(buffer.lineEnd(caret), caret + n)
                return .done(apply("d", range: caret..<end, linewise: false, buffer, register: register, keys: keys, count: n))
            case ("X", []):
                let start = max(buffer.lineStart(caret), caret - n)
                guard start < caret else { return .done([]) }
                return .done(apply("d", range: start..<caret, linewise: false, buffer, register: register, keys: keys, count: n))
            case ("D", []), ("C", []):
                var end = buffer.lineEnd(caret)
                for _ in 1..<max(1, n) where end < buffer.length { end = buffer.lineEnd(end + 1) }
                return .done(apply(first.key == "D" ? "d" : "c", range: caret..<end, linewise: false, buffer, register: register, keys: keys, count: n))
            case ("Y", []):
                // `evil-want-Y-yank-to-eol`.
                return .done(apply("y", range: caret..<buffer.lineEnd(caret), linewise: false, buffer, register: register, keys: keys, count: n))
            case ("p", []), ("P", []):
                guard let (text, linewise) = paste(register, context) else { return .done([]) }
                let repeated = String(repeating: text, count: n)
                if linewise {
                    let body = repeated.hasSuffix("\n") ? repeated : repeated + "\n"
                    if first.key == "p" {
                        let end = buffer.lineEnd(caret)
                        if end >= buffer.length {
                            let insertion = "\n" + String(body.dropLast())
                            return .done(change([TextEdit(range: end..<end, replacement: insertion)], caret: buffer.firstNonBlankIn(insertion, at: end + 1), keys: keys))
                        }
                        return .done(change([TextEdit(range: (end + 1)..<(end + 1), replacement: body)], caret: buffer.firstNonBlankIn(body, at: end + 1), keys: keys))
                    }
                    let start = buffer.lineStart(caret)
                    return .done(change([TextEdit(range: start..<start, replacement: body)], caret: buffer.firstNonBlankIn(body, at: start), keys: keys))
                }
                let at = first.key == "p" && buffer.char(caret).map({ $0 != 10 }) == true ? caret + 1 : caret
                return .done(change([TextEdit(range: at..<at, replacement: repeated)], caret: at + max(0, repeated.utf16.count - 1), keys: keys))
            case ("J", []):
                return .done(join(buffer, at: caret, lines: max(2, n), keys: keys))
            case ("~", []):
                let end = min(buffer.lineEnd(caret), caret + n)
                guard end > caret else { return .done([]) }
                let flipped = String(buffer.substring(caret..<end).map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
                return .done(change([TextEdit(range: caret..<end, replacement: flipped)], caret: buffer.clampNormal(end, in: buffer.lineStart(caret)), keys: keys))
            case ("r", []):
                guard rest.count >= 2 else { return .incomplete }
                let target = rest[rest.startIndex + 1]
                let char = target.key == "SPC" ? " " : target.key == "RET" ? "\n" : target.key
                guard char.count == 1, caret + n <= buffer.lineEnd(caret) else { return .done([]) }
                let replacement = char == "\n" ? "\n" : String(repeating: char, count: n)
                return .done(change([TextEdit(range: caret..<(caret + n), replacement: replacement)], caret: char == "\n" ? caret + 1 : caret + n - 1, keys: keys))
            case ("u", []):
                return .done([.undo(n)])
            case ("r", [.control]):
                return .done([.redo(n)])
            case (".", []):
                return .done(repeatChange(n, context))
            case (":", []):
                return .done([.prompt(":")])
            case ("/", []), ("?", []):
                return .done([.prompt(first.key)])
            case ("Z", []):
                guard rest.count >= 2 else { return .incomplete }
                switch rest[rest.startIndex + 1].key {
                case "Z": return .done([.command("app.save")])
                case "Q": return .done([.message("ZQ isn't available; use the window's close button")])
                default: return .invalid
                }
            default:
                break
            }
        }

        if mode == .normal, rest.count == 2, first == KeyChord("g"), rest.last == KeyChord("j") || rest.last == KeyChord("k") {
            return .done([.visualLines(rest.last == KeyChord("j") ? n : -n)])
        }

        // Motions move the caret, or extend the selection in visual states.
        var target = caret
        switch motion(Array(rest), &buffer, &target, count: n, operatorPending: false) {
        case .incomplete: return .incomplete
        case .invalid: return .invalid
        case .moved(let to, _):
            if visual { return .done(visualActions(buffer, to)) }
            let jump: [Action] = Self.isJump(Array(rest)) && to != caret ? [.jumped(from: caret)] : []
            return .done(jump + [.move(caret: buffer.clampNormal(to))])
        }
    }

    // MARK: - Motions

    enum MotionKind { case exclusive, inclusive, linewise }

    enum MotionResult {
        case incomplete
        case invalid
        case moved(Int, MotionKind)
    }

    mutating func motion(_ keys: [KeyChord], _ buffer: inout Buffer, _ caret: inout Int, count n: Int, operatorPending: Bool) -> MotionResult {
        guard let key = keys.first else { return .incomplete }
        let c = caret
        func column(_ position: Int) -> Int { position - buffer.lineStart(position) }
        switch (key.key, key.modifiers) {
        case ("h", []), ("<left>", []), ("DEL", []):
            goalColumn = nil
            return .moved(max(buffer.lineStart(c), c - n), .exclusive)
        case ("l", []), ("<right>", []), ("SPC", []):
            goalColumn = nil
            let end = buffer.lineEnd(c)
            let limit = operatorPending ? end : max(buffer.lineStart(c), end - 1)
            return .moved(min(limit, c + n), .exclusive)
        case ("j", []), ("k", []), ("<down>", []), ("<up>", []), ("d", [.control]), ("u", [.control]), ("+", []), ("-", []), ("RET", []):
            let down = ["j", "<down>", "+", "RET"].contains(key.key) || key == KeyChord("d", .control)
            let lines = key.modifiers.contains(.control) ? (n == 1 ? 15 : n) : n
            let goal = goalColumn ?? column(c)
            var line = buffer.lineStart(c)
            var moved = 0
            for _ in 0..<lines {
                if down {
                    let end = buffer.lineEnd(line)
                    guard end < buffer.length, end + 1 <= buffer.length else { break }
                    if end + 1 == buffer.length { break }
                    line = end + 1
                } else {
                    guard line > 0 else { break }
                    line = buffer.lineStart(line - 1)
                }
                moved += 1
            }
            if moved == 0, !key.modifiers.contains(.control) { return .invalid }
            if ["+", "-", "RET"].contains(key.key) { return .moved(buffer.firstNonBlank(line), .linewise) }
            goalColumn = goal
            let length = buffer.lineEnd(line) - line
            return .moved(line + min(goal, operatorPending ? length : max(0, length - 1)), .linewise)
        case ("w", []), ("W", []):
            goalColumn = nil
            var p = c
            for _ in 0..<n { p = buffer.wordForward(p, bigWord: key.key == "W") }
            return .moved(p, .exclusive)
        case ("b", []), ("B", []):
            goalColumn = nil
            var p = c
            for _ in 0..<n { p = buffer.wordBackward(p, bigWord: key.key == "B", stopAtLine: false) }
            return .moved(p, .exclusive)
        case ("e", []), ("E", []):
            goalColumn = nil
            var p = c
            for _ in 0..<n { p = buffer.wordEnd(p, bigWord: key.key == "E", fromInside: false) }
            return .moved(p, .inclusive)
        case ("0", []), ("<home>", []):
            goalColumn = nil
            return .moved(buffer.lineStart(c), .exclusive)
        case ("^", []):
            goalColumn = nil
            return .moved(buffer.firstNonBlank(buffer.lineStart(c)), .exclusive)
        case ("$", []), ("<end>", []):
            var line = buffer.lineStart(c)
            for _ in 1..<max(1, n) where buffer.lineEnd(line) < buffer.length { line = buffer.lineEnd(line) + 1 }
            goalColumn = Int.max
            let end = buffer.lineEnd(line)
            if mode == .visual { return .moved(end, .inclusive) }
            return .moved(max(line, end - 1), .inclusive)
        case ("G", []):
            // `evil-start-of-line` nil: the column stays.
            let line = n > 1 || keys.count > 1 ? buffer.lineOffset(n) : buffer.lineStart(buffer.length)
            let column = c - buffer.lineStart(c)
            let length = buffer.lineEnd(line) - line
            return .moved(line + min(column, operatorPending ? length : max(0, length - 1)), .linewise)
        case ("g", []):
            guard keys.count >= 2 else { return .incomplete }
            switch keys[1].key {
            case "g":
                let line = buffer.lineOffset(n)
                let column = c - buffer.lineStart(c)
                let length = buffer.lineEnd(line) - line
                return .moved(line + min(column, operatorPending ? length : max(0, length - 1)), .linewise)
            case "e", "E":
                var p = c
                for _ in 0..<n { p = buffer.wordEndBackward(p, bigWord: keys[1].key == "E") }
                return .moved(p, .inclusive)
            case "j":
                return motion([KeyChord("j")], &buffer, &caret, count: n, operatorPending: operatorPending)
            case "k":
                return motion([KeyChord("k")], &buffer, &caret, count: n, operatorPending: operatorPending)
            case "_":
                let end = buffer.lineEnd(c)
                var p = end
                while p > buffer.lineStart(c), let ch = buffer.char(p - 1), Buffer.isBlank(ch) { p -= 1 }
                return .moved(max(buffer.lineStart(c), p - 1), .inclusive)
            default:
                return .invalid
            }
        case ("f", []), ("F", []), ("t", []), ("T", []):
            guard keys.count >= 2 else { return .incomplete }
            let char = keys[1].key == "SPC" ? " " : keys[1].key
            guard char.count == 1 else { return .invalid }
            lastFind = (Character(key.key), char)
            guard let p = find(Character(key.key), char, buffer, c, count: n) else { return .invalid }
            return .moved(p, key.key == "f" || key.key == "t" ? .inclusive : .exclusive)
        case (";", []), (",", []):
            guard let last = lastFind else { return .invalid }
            var kind = last.kind
            if key.key == "," {
                kind = ["f": "F", "F": "f", "t": "T", "T": "t"][kind]!
            }
            guard let p = find(kind, last.char, buffer, c, count: n, repeating: true) else { return .invalid }
            return .moved(p, kind == "f" || kind == "t" ? .inclusive : .exclusive)
        case ("s", []) where !operatorPending, ("S", []) where !operatorPending:
            // evil-snipe with `evil-snipe-scope` line.
            guard keys.count >= 3 else { return .incomplete }
            let chars = keys[1].key + keys[2].key
            lastSnipe = (key.key == "s", chars)
            guard let p = snipe(forward: key.key == "s", chars, buffer, c, count: n) else { return .invalid }
            return .moved(p, .exclusive)
        case ("%", []):
            guard let p = buffer.matchingBracket(c) else { return .invalid }
            return .moved(p, .inclusive)
        case ("'", []), ("`", []):
            guard keys.count >= 2 else { return .incomplete }
            let name = keys[1].key == "'" || keys[1].key == "`" ? Character("'") : keys[1].key.first
            guard let name, let mark = currentMarks[name] else { return .invalid }
            goalColumn = nil
            let p = min(mark, buffer.length)
            return key.key == "'" ? .moved(buffer.firstNonBlank(buffer.lineStart(p)), .linewise) : .moved(p, .exclusive)
        case ("}", []), ("{", []):
            var p = c
            for _ in 0..<n { p = buffer.paragraph(p, forward: key.key == "}") }
            return .moved(p, .exclusive)
        case ("n", []), ("N", []):
            guard let search = lastSearch else { return .invalid }
            let forward = key.key == "n" ? search.forward : !search.forward
            guard let p = buffer.search(search.pattern, from: c, forward: forward, count: n) else { return .invalid }
            return .moved(p, .exclusive)
        case ("*", []), ("#", []):
            guard let word = buffer.wordAt(c) else { return .invalid }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
            lastSearch = (pattern, key.key == "*")
            guard let p = buffer.search(pattern, from: buffer.wordStart(c), forward: key.key == "*", count: n) else { return .invalid }
            return .moved(p, .exclusive)
        default:
            return .invalid
        }
    }

    func find(_ kind: Character, _ char: String, _ buffer: Buffer, _ c: Int, count n: Int, repeating: Bool = false) -> Int? {
        let target = char.utf16.first!
        let forward = kind == "f" || kind == "t"
        var p = c
        for i in 0..<n {
            var q = p
            // Repeating t/T starts past the character it stopped before.
            let skip = repeating && i == 0 && (kind == "t" || kind == "T") ? 1 : 0
            if forward {
                q += 1 + skip
                while q < buffer.lineEnd(c), buffer.char(q) != target { q += 1 }
                guard q < buffer.lineEnd(c) else { return nil }
            } else {
                q -= 1 + skip
                while q >= buffer.lineStart(c), buffer.char(q) != target { q -= 1 }
                guard q >= buffer.lineStart(c) else { return nil }
            }
            p = q
        }
        if kind == "t" { return p - 1 }
        if kind == "T" { return p + 1 }
        return p
    }

    func snipe(forward: Bool, _ chars: String, _ buffer: Buffer, _ c: Int, count n: Int) -> Int? {
        let line = buffer.substring(buffer.lineStart(c)..<buffer.lineEnd(c)) as NSString
        let start = buffer.lineStart(c)
        let smart = chars == chars.lowercased()
        var p = c - start
        for _ in 0..<n {
            let range: NSRange
            if forward {
                guard p + 1 < line.length else { return nil }
                range = line.range(of: chars, options: smart ? .caseInsensitive : [], range: NSRange(location: p + 1, length: line.length - p - 1))
            } else {
                guard p > 0 else { return nil }
                range = line.range(of: chars, options: smart ? [.caseInsensitive, .backwards] : .backwards, range: NSRange(location: 0, length: p))
            }
            guard range.location != NSNotFound else { return nil }
            p = range.location
        }
        return start + p
    }

    // MARK: - Text objects

    func textObject(_ inner: Bool, _ key: KeyChord, _ buffer: Buffer, _ c: Int, count: Int) -> (range: Range<Int>, linewise: Bool)? {
        switch key.key {
        case "w", "W":
            return buffer.wordObject(c, inner: inner, bigWord: key.key == "W", count: count).map { ($0, false) }
        case "\"", "'", "`":
            return buffer.quoteObject(c, quote: key.key.utf16.first!, inner: inner).map { ($0, false) }
        case "(", ")", "b":
            return buffer.bracketObject(c, open: 40, close: 41, inner: inner).map { ($0, false) }
        case "[", "]":
            return buffer.bracketObject(c, open: 91, close: 93, inner: inner).map { ($0, false) }
        case "{", "}", "B":
            return buffer.bracketObject(c, open: 123, close: 125, inner: inner).map { ($0, false) }
        case "<", ">":
            return buffer.bracketObject(c, open: 60, close: 62, inner: inner).map { ($0, false) }
        case "p":
            return buffer.paragraphObject(c, inner: inner).map { ($0, true) }
        case "e", "E", "r", "R":
            return Self.orgObject(key.key, inner: inner, buffer, c)
        default:
            return nil
        }
    }

    // MARK: - Applying

    func visualRange(_ buffer: Buffer, _ caret: Int) -> (range: Range<Int>, linewise: Bool) {
        let a = min(anchor, caret)
        let b = max(anchor, caret)
        if mode == .visualLine {
            let end = buffer.lineEnd(b)
            return (buffer.lineStart(a)..<min(buffer.length, end + 1), true)
        }
        return (a..<min(buffer.length, b + 1), false)
    }

    func visualActions(_ buffer: Buffer, _ caret: Int) -> [Action] {
        let a = min(anchor, caret)
        let b = max(anchor, caret)
        let range = mode == .visualLine ? buffer.lineStart(a)..<buffer.lineEnd(b) : a..<min(buffer.length, b + 1)
        return [.move(caret: caret), .select(range)]
    }

    mutating func store(_ text: String, linewise: Bool, register: Character?, yank: Bool) -> [Action] {
        if register == "_" { return [] }
        if let register, register.isLetter {
            let key = Character(register.lowercased())
            if register.isUppercase, let existing = registers[key] {
                registers[key] = (existing.text + text, existing.linewise || linewise)
            } else {
                registers[key] = (text, linewise)
            }
            return []
        }
        if yank { registers["0"] = (text, linewise) }
        clipboardRecord = (text, linewise)
        return [.setClipboard(text)]
    }

    func paste(_ register: Character?, _ context: Context) -> (String, Bool)? {
        if let register, register != "\"", register != "+", register != "*" {
            return registers[Character(register.lowercased())]
        }
        guard let clip = context.clipboard ?? clipboardRecord?.text else { return nil }
        if let record = clipboardRecord, record.text == clip { return (clip, record.linewise) }
        return (clip, false)
    }

    mutating func change(_ edits: [TextEdit], caret: Int, keys: [KeyChord]) -> [Action] {
        lastChange = (keys, nil)
        return [.edit(edits, caret: caret)]
    }

    mutating func apply(_ op: String, range: Range<Int>, linewise: Bool, _ buffer: Buffer, register: Character?, keys: [KeyChord], count: Int) -> [Action] {
        let wasVisual = mode == .visual || mode == .visualLine
        if wasVisual { lastVisual = (anchor, caretForApply, mode) }
        let context0Column = max(0, caretForApply - buffer.lineStart(caretForApply))
        mode = .normal
        let text = buffer.substring(range)
        switch op {
        case "y":
            var actions = store(text, linewise: linewise, register: register, yank: true)
            let caret = linewise && !wasVisual ? min(range.lowerBound, buffer.length) : range.lowerBound
            actions.append(.move(caret: linewise && wasVisual ? buffer.lineStart(range.lowerBound) : caret))
            return actions
        case "d":
            var actions = store(text, linewise: linewise, register: register, yank: false)
            var deletion = range
            if linewise, range.upperBound >= buffer.length, range.lowerBound > 0, buffer.char(range.upperBound - 1) != 10 || range.upperBound == buffer.length {
                // The last line takes the newline before it.
                if buffer.char(range.lowerBound - 1) == 10, range.upperBound == buffer.length, !(text.hasSuffix("\n")) {
                    deletion = (range.lowerBound - 1)..<range.upperBound
                }
            }
            let after = buffer.removing(deletion)
            var caret = deletion.lowerBound
            if linewise {
                let column = context0Column
                let line = after.lineStart(min(deletion.lowerBound, after.length))
                let length = after.lineEnd(line) - line
                caret = line + min(column, max(0, length - 1))
            } else {
                caret = after.clampNormal(caret)
            }
            lastChange = (wasVisual ? [] : keys, nil)
            actions.insert(.edit([TextEdit(range: deletion, replacement: "")], caret: caret), at: 0)
            return actions
        case "c":
            var actions = store(text, linewise: linewise, register: register, yank: false)
            var deletion = range
            var replacement = ""
            if linewise {
                // cc keeps the newline and indents as the line before it calls for.
                replacement = range.lowerBound == 0 ? "" : Self.indentation(for: buffer, line: range.lowerBound - 1)
                if buffer.char(range.upperBound - 1) == 10 { deletion = range.lowerBound..<(range.upperBound - 1) }
            }
            let caret = deletion.lowerBound + replacement.utf16.count
            actions.insert(.edit([TextEdit(range: deletion, replacement: replacement)], caret: caret), at: 0)
            enterInsert(at: caret, keys: wasVisual ? [] : keys)
            return actions
        case ">", "<":
            let start = buffer.lineStart(range.lowerBound)
            var edits: [TextEdit] = []
            var line = start
            let end = linewise ? range.upperBound : max(range.upperBound, buffer.lineEnd(max(range.lowerBound, range.upperBound - 1)))
            while line < end || (line == start && line <= buffer.length) {
                let lineEnd = buffer.lineEnd(line)
                if lineEnd > line {
                    if op == ">" {
                        edits.append(TextEdit(range: line..<line, replacement: String(repeating: " ", count: Self.shiftWidth)))
                    } else {
                        let indent = buffer.substring(line..<buffer.firstNonBlankOrEnd(line))
                        let remove = min(Self.shiftWidth, indent.count)
                        if remove > 0 { edits.append(TextEdit(range: line..<(line + remove), replacement: "")) }
                    }
                }
                guard lineEnd < buffer.length else { break }
                line = lineEnd + 1
                if line >= end { break }
            }
            lastChange = (wasVisual ? [] : keys, nil)
            return [.edit(edits, caret: start)]
        case "gc":
            lastChange = (wasVisual ? [] : keys, nil)
            return [.edit(Self.toggleComments(buffer, range), caret: buffer.lineStart(range.lowerBound))]
        default:
            let transformed: String
            switch op {
            case "gu": transformed = text.lowercased()
            case "gU": transformed = text.uppercased()
            default: transformed = String(text.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
            }
            lastChange = (wasVisual ? [] : keys, nil)
            return [.edit([TextEdit(range: range, replacement: transformed)], caret: range.lowerBound)]
        }
    }

    mutating func enterInsert(_ key: String, _ buffer: Buffer, _ caret: Int, keys: [KeyChord]) -> [Action] {
        switch key {
        case "i":
            enterInsert(at: caret, keys: keys)
            return [.move(caret: caret)]
        case "a":
            let p = buffer.char(caret).map { $0 != 10 } == true ? caret + 1 : caret
            enterInsert(at: p, keys: keys)
            return [.move(caret: p)]
        case "I":
            let p = buffer.firstNonBlank(buffer.lineStart(caret))
            enterInsert(at: p, keys: keys)
            return [.move(caret: p)]
        case "A":
            let p = buffer.lineEnd(caret)
            enterInsert(at: p, keys: keys)
            return [.move(caret: p)]
        case "o":
            let end = buffer.lineEnd(caret)
            let indent = Self.indentation(for: buffer, line: caret)
            enterInsert(at: end + 1 + indent.utf16.count, keys: keys)
            return [.edit([TextEdit(range: end..<end, replacement: "\n" + indent)], caret: end + 1 + indent.utf16.count)]
        default:
            let start = buffer.lineStart(caret)
            let indent = Self.indentation(for: buffer, line: max(0, start - 1)) == "" || start == 0 ? "" : Self.indentation(for: buffer, line: start - 1)
            enterInsert(at: start + indent.utf16.count, keys: keys)
            return [.edit([TextEdit(range: start..<start, replacement: indent + "\n")], caret: start + indent.utf16.count)]
        }
    }

    mutating func join(_ buffer: Buffer, at caret: Int, lines: Int, keys: [KeyChord]) -> [Action] {
        var edits: [TextEdit] = []
        var line = buffer.lineStart(caret)
        var position = caret
        for _ in 1..<lines {
            let end = buffer.lineEnd(line)
            guard end < buffer.length else { break }
            let nextStart = end + 1
            let nextText = buffer.firstNonBlankOrEnd(nextStart)
            let joinsEmpty = buffer.lineEnd(nextStart) == nextText
            let separator = joinsEmpty || buffer.char(nextText) == 41 ? "" : (end > line && buffer.char(end - 1) == 32 ? "" : " ")
            var from = end
            while from > line, let c = buffer.char(from - 1), c == 32 || c == 9 { from -= 1 }
            if !separator.isEmpty || from == end { from = end }
            edits.append(TextEdit(range: from..<nextText, replacement: separator))
            position = from
            line = nextStart
        }
        guard !edits.isEmpty else { return [] }
        lastChange = (keys, nil)
        // Positions in edits refer to the original text; apply back to front.
        let shift = edits.dropLast().reduce(0) { $0 + $1.replacement.utf16.count - $1.range.count }
        return [.edit(edits, caret: position + shift)]
    }

    mutating func repeatChange(_ count: Int, _ context: Context) -> [Action] {
        guard let change = lastChange, !change.keys.isEmpty else { return [] }
        var copy = self
        copy.lastChange = nil
        copy.pending = []
        var keys = change.keys
        if count > 1, let (_, _, rest) = Self.prefix(keys) {
            keys = Array("\(count)".map { KeyChord(String($0)) }) + Array(rest)
        }
        var actions: [Action] = []
        var text = context.text
        var caret = context.caret
        for key in keys {
            if copy.mode == .insert, key == KeyChord("ESC") {
                if let inserted = change.inserted, !inserted.isEmpty {
                    let edit = TextEdit(range: caret..<caret, replacement: inserted)
                    actions.append(.edit([edit], caret: caret + inserted.utf16.count))
                    text = edit.apply(to: text)
                    caret += inserted.utf16.count
                }
            }
            let produced = copy.feed(key, Context(text: text, caret: caret, clipboard: context.clipboard, halfPage: context.halfPage))
            for action in produced {
                switch action {
                case .edit(let edits, let to):
                    var new = text
                    for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
                    text = new
                    caret = to
                case .move(let to):
                    caret = to
                default:
                    break
                }
                actions.append(action)
            }
        }
        let preserved = (registers, clipboardRecord)
        self = copy
        registers = preserved.0
        clipboardRecord = copy.clipboardRecord ?? preserved.1
        lastChange = change
        return actions
    }

    /// `/pattern` or `?pattern` from the prompt: the caret's new place.
    public mutating func search(_ pattern: String, forward: Bool, _ context: Context) -> [Action] {
        lastSearch = (pattern, forward)
        let buffer = Buffer(context)
        guard let p = buffer.search(pattern, from: context.caret, forward: forward, count: 1) else { return [.message("Search failed: \(pattern)")] }
        if mode == .visual || mode == .visualLine { return visualActions(buffer, p) }
        return [.jumped(from: context.caret), .move(caret: p)]
    }

    /// Leave a visual state without acting, as `ESC` does.
    public mutating func reset() {
        pending = []
        if mode == .visual || mode == .visualLine || mode == .visualBlock { mode = .normal }
    }

    // MARK: - Text

    struct Buffer {
        let ns: NSString
        var length: Int { ns.length }

        init(_ context: Context) { ns = context.text as NSString }
        init(_ text: String) { ns = text as NSString }

        func char(_ i: Int) -> unichar? { i >= 0 && i < ns.length ? ns.character(at: i) : nil }
        func substring(_ r: Range<Int>) -> String { ns.substring(with: NSRange(location: r.lowerBound, length: r.count)) }
        func lineStart(_ i: Int) -> Int { ns.lineRange(for: NSRange(location: min(i, ns.length), length: 0)).location }
        func lineEnd(_ i: Int) -> Int {
            var end = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: min(i, ns.length), length: 0))
            return end
        }
        func removing(_ r: Range<Int>) -> Buffer { Buffer(ns.replacingCharacters(in: NSRange(location: r.lowerBound, length: r.count), with: "")) }
        func applying(_ edits: [TextEdit]) -> Buffer {
            var text = ns as String
            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { text = edit.apply(to: text) }
            return Buffer(text)
        }

        static func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 }
        static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        static func isWord(_ c: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(c) else { return true }
            return CharacterSet.alphanumerics.contains(scalar) || c == 95
        }

        /// 0 blank, 1 word, 2 other.
        func kind(_ i: Int, bigWord: Bool) -> Int {
            guard let c = char(i) else { return 0 }
            if Self.isSpace(c) { return 0 }
            if bigWord { return 1 }
            return Self.isWord(c) ? 1 : 2
        }

        func clampNormal(_ i: Int) -> Int { clampNormal(i, in: lineStart(i)) }
        func clampNormal(_ i: Int, in line: Int) -> Int {
            let end = lineEnd(line)
            return max(line, min(i, end > line ? end - 1 : line))
        }

        func firstNonBlank(_ line: Int) -> Int {
            var p = line
            let end = lineEnd(line)
            while p < end, let c = char(p), Self.isBlank(c) { p += 1 }
            return p == end && end > line ? end - 1 : (p == end ? line : p)
        }

        func firstNonBlankOrEnd(_ line: Int) -> Int {
            var p = line
            let end = lineEnd(line)
            while p < end, let c = char(p), Self.isBlank(c) { p += 1 }
            return p
        }

        func firstNonBlankIn(_ inserted: String, at start: Int) -> Int {
            start + inserted.prefix { $0 == " " || $0 == "\t" }.utf16.count
        }

        func lineOffset(_ number: Int) -> Int {
            var line = 0
            for _ in 1..<max(1, number) {
                let end = lineEnd(line)
                guard end < length, end + 1 < length else { break }
                line = end + 1
            }
            return line
        }

        /// The number, from 1, of the line holding `i`.
        func lineNumber(_ i: Int) -> Int {
            var count = 1
            var p = 0
            while p < min(i, length) {
                if char(p) == 10 { count += 1 }
                p += 1
            }
            return count
        }

        func lineCount(_ r: Range<Int>) -> Int {
            substring(r).filter { $0 == "\n" }.count + (r.upperBound > 0 && char(r.upperBound - 1) == 10 ? 0 : 1)
        }

        func wordForward(_ c: Int, bigWord: Bool) -> Int {
            var p = c
            let k = kind(p, bigWord: bigWord)
            if k != 0 { while p < length, kind(p, bigWord: bigWord) == k { p += 1 } }
            // Skip blanks; an empty line is a word.
            while p < length, kind(p, bigWord: bigWord) == 0 {
                if char(p) == 10, p > c, char(p - 1) == 10 { return p }
                if char(p) == 10, p + 1 < length, char(p + 1) == 10, p + 1 > c { return p + 1 }
                p += 1
            }
            return min(p, length)
        }

        func wordBackward(_ c: Int, bigWord: Bool, stopAtLine: Bool) -> Int {
            var p = c
            guard p > 0 else { return 0 }
            p -= 1
            while p > 0, kind(p, bigWord: bigWord) == 0 {
                if char(p) == 10, char(p - 1) == 10, !stopAtLine { return p }
                if stopAtLine, char(p) == 10 { return p + 1 }
                p -= 1
            }
            let k = kind(p, bigWord: bigWord)
            while p > 0, kind(p - 1, bigWord: bigWord) == k, k != 0 { p -= 1 }
            return p
        }

        func wordEnd(_ c: Int, bigWord: Bool, fromInside: Bool) -> Int {
            var p = fromInside ? c : c + 1
            while p < length, kind(p, bigWord: bigWord) == 0 { p += 1 }
            let k = kind(p, bigWord: bigWord)
            while p + 1 < length, kind(p + 1, bigWord: bigWord) == k, k != 0 { p += 1 }
            return min(p, max(0, length - 1))
        }

        func wordEndBackward(_ c: Int, bigWord: Bool) -> Int {
            var p = c
            let k = kind(p, bigWord: bigWord)
            while p > 0, kind(p, bigWord: bigWord) == k, k != 0 { p -= 1 }
            while p > 0, kind(p, bigWord: bigWord) == 0 { p -= 1 }
            return p
        }

        func wordStart(_ c: Int) -> Int {
            var p = c
            while p > 0, let ch = char(p - 1), Self.isWord(ch) { p -= 1 }
            return p
        }

        func wordAt(_ c: Int) -> String? {
            var p = c
            while p < lineEnd(c), let ch = char(p), !Self.isWord(ch) { p += 1 }
            guard let ch = char(p), Self.isWord(ch) else { return nil }
            let start = wordStart(p)
            var end = p
            while end < length, let e = char(end), Self.isWord(e) { end += 1 }
            return substring(start..<end)
        }

        func matchingBracket(_ c: Int) -> Int? {
            let pairs: [unichar: (unichar, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true), 41: (40, false), 93: (91, false), 125: (123, false)]
            var p = c
            let end = lineEnd(c)
            while p < end, let ch = char(p), pairs[ch] == nil { p += 1 }
            guard let open = char(p), let (close, forward) = pairs[open] else { return nil }
            var depth = 0
            var q = p
            while q >= 0, q < length {
                if char(q) == open { depth += 1 }
                if char(q) == close {
                    depth -= 1
                    if depth == 0 { return q }
                }
                q += forward ? 1 : -1
            }
            return nil
        }

        func paragraph(_ c: Int, forward: Bool) -> Int {
            func blank(_ line: Int) -> Bool { substring(line..<lineEnd(line)).allSatisfy { $0 == " " || $0 == "\t" } }
            var line = lineStart(c)
            if forward {
                while lineEnd(line) < length, blank(line) { line = lineEnd(line) + 1 }
                while lineEnd(line) < length {
                    line = lineEnd(line) + 1
                    if blank(line) { return line }
                }
                return max(0, length - (length > 0 && char(length - 1) == 10 ? 1 : 0))
            }
            while line > 0, blank(line) { line = lineStart(line - 1) }
            while line > 0 {
                line = lineStart(line - 1)
                if blank(line) { return line }
            }
            return 0
        }

        func search(_ pattern: String, from c: Int, forward: Bool, count: Int) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let all = regex.matches(in: ns as String, range: NSRange(location: 0, length: length)).map(\.range.location)
            guard !all.isEmpty else { return nil }
            var p = c
            for _ in 0..<count {
                if forward {
                    p = all.first { $0 > p } ?? all[0]
                } else {
                    p = all.last { $0 < p } ?? all[all.count - 1]
                }
            }
            return p
        }

        func wordObject(_ c: Int, inner: Bool, bigWord: Bool, count: Int) -> Range<Int>? {
            guard c < length else { return nil }
            var start = c
            var end = c
            let k = kind(c, bigWord: bigWord)
            let lineS = lineStart(c)
            let lineE = lineEnd(c)
            while start > lineS, kind(start - 1, bigWord: bigWord) == k, char(start - 1) != 10 { start -= 1 }
            while end < lineE, kind(end, bigWord: bigWord) == k { end += 1 }
            if inner {
                for _ in 1..<max(1, count) {
                    let k2 = kind(end, bigWord: bigWord)
                    while end < lineE, kind(end, bigWord: bigWord) == k2 { end += 1 }
                }
                return start..<end
            }
            for _ in 1..<max(1, count) {
                while end < lineE, let ch = char(end), Self.isBlank(ch) { end += 1 }
                let k2 = kind(end, bigWord: bigWord)
                while end < lineE, kind(end, bigWord: bigWord) == k2 { end += 1 }
            }
            if k == 0 {
                let k2 = kind(end, bigWord: bigWord)
                while end < lineE, kind(end, bigWord: bigWord) == k2 { end += 1 }
                return start..<end
            }
            var trailing = end
            while trailing < lineE, let ch = char(trailing), Self.isBlank(ch) { trailing += 1 }
            if trailing > end { return start..<trailing }
            while start > lineS, let ch = char(start - 1), Self.isBlank(ch) { start -= 1 }
            return start..<end
        }

        func quoteObject(_ c: Int, quote: unichar, inner: Bool) -> Range<Int>? {
            let s = lineStart(c)
            let e = lineEnd(c)
            var positions: [Int] = []
            var p = s
            while p < e {
                if char(p) == quote, p == s || char(p - 1) != 92 { positions.append(p) }
                p += 1
            }
            var pair: (Int, Int)?
            var i = 0
            while i + 1 < positions.count {
                if positions[i] <= c, c <= positions[i + 1] { pair = (positions[i], positions[i + 1]); break }
                i += 2
            }
            guard let (open, close) = pair else { return nil }
            if inner { return (open + 1)..<close }
            var end = close + 1
            while end < e, let ch = char(end), Self.isBlank(ch) { end += 1 }
            var start = open
            if end == close + 1 { while start > s, let ch = char(start - 1), Self.isBlank(ch) { start -= 1 } }
            return start..<end
        }

        func bracketObject(_ c: Int, open: unichar, close: unichar, inner: Bool) -> Range<Int>? {
            var depth = 0
            var p = c
            var start: Int?
            if char(c) == open {
                start = c
            } else {
                if char(c) == close { p = c - 1 }
                while p >= 0 {
                    if char(p) == close { depth += 1 }
                    if char(p) == open {
                        if depth == 0 { start = p; break }
                        depth -= 1
                    }
                    p -= 1
                }
            }
            if start == nil {
                var f = c
                while f < lineEnd(c), char(f) != open { f += 1 }
                if f < lineEnd(c) { start = f }
            }
            guard let s = start else { return nil }
            depth = 0
            var q = s
            var end: Int?
            while q < length {
                if char(q) == open { depth += 1 }
                if char(q) == close {
                    depth -= 1
                    if depth == 0 { end = q; break }
                }
                q += 1
            }
            guard let e = end else { return nil }
            if !inner { return s..<(e + 1) }
            var innerStart = s + 1
            var innerEnd = e
            // A block that starts and ends on its own lines keeps them.
            if char(innerStart) == 10, lineStart(innerEnd) == innerEnd || substring(lineStart(innerEnd)..<innerEnd).allSatisfy({ $0 == " " || $0 == "\t" }) {
                innerStart += 1
                innerEnd = lineStart(innerEnd)
            }
            return innerStart..<innerEnd
        }

        func paragraphObject(_ c: Int, inner: Bool) -> Range<Int>? {
            func blank(_ line: Int) -> Bool { substring(line..<lineEnd(line)).allSatisfy { $0 == " " || $0 == "\t" } }
            var start = lineStart(c)
            let isBlank = blank(start)
            while start > 0, blank(lineStart(start - 1)) == isBlank { start = lineStart(start - 1) }
            var end = lineEnd(c)
            while end < length, end + 1 <= length, end + 1 < length || !isBlank, blank(end + 1) == isBlank, end + 1 < length {
                end = lineEnd(end + 1)
            }
            var upper = min(length, end + 1)
            if !inner {
                var after = upper
                while after < length, blank(after) {
                    let next = lineEnd(after)
                    after = min(length, next + 1)
                    if next >= length { break }
                }
                upper = after
            }
            return start..<upper
        }
    }
}
