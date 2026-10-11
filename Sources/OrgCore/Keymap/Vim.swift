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
        case replace

        /// The keymap mode name for bindings.
        public var keymapMode: String {
            switch self {
            case .normal: "normal"
            case .insert, .replace: "insert"
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
        /// `gq` and `gw`: fill these lines' paragraphs (`FillRegion`); the caret stays at
        /// `keep`, or without it goes to the last line's first non-blank.
        case fill(Range<Int>, keep: Int?)
        /// An ex command to run, as if typed after `:` (`ZZ` is `:wq`, `ZQ` is `:q!`).
        case ex(String)
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
        /// `zz`, `zt`, `zb`: scroll the caret's line to the window's middle, top or bottom.
        case scroll(ScrollLine)
        /// `q:`, `q/`, `q?`: the command-line window, the earlier commands or searches to pick
        /// from and edit.
        case commandWindow(String)
    }

    public struct Context: Sendable {
        public var text: String
        public var caret: Int
        public var clipboard: String?
        /// Lines in a half page, for C-d and C-u.
        public var halfPage: Int
        /// Marks where the editor keeps them now; `'` and `` ` `` are the last jump's start.
        public var marks: [Character: Int]
        /// The text the window shows, for H, M and L; nil when unknown.
        public var visible: Range<Int>?
        /// An Org buffer, where evil-org's keys apply.
        public var org: Bool

        public init(text: String, caret: Int, clipboard: String? = nil, halfPage: Int = 15, marks: [Character: Int] = [:], visible: Range<Int>? = nil, org: Bool = false) {
            self.org = org
            self.text = text
            self.caret = caret
            self.clipboard = clipboard
            self.halfPage = halfPage
            self.marks = marks
            self.visible = visible
        }
    }

    public internal(set) var mode: Mode = .normal
    /// Keys of the command being typed.
    public internal(set) var pending: [KeyChord] = []
    /// Named registers. Evil's are global: an editor with several engines shares them.
    public var registers: [Character: (text: String, linewise: Bool)] = [:]
    /// What the clipboard held when this engine last wrote it, and whether that was whole lines.
    public var clipboardRecord: (text: String, linewise: Bool)?
    var anchor = 0
    var goalColumn: Int?
    /// The last snipe: s, S, f, F, t or T. `consume` lands on the match (s, f, F) rather
    /// than next to it (t, T); `keys` repeat it right after it, forward and back.
    var lastSnipe: (forward: Bool, chars: String, count: Int, consume: Bool, keys: (forward: KeyChord, backward: KeyChord))?
    /// Set after a snipe: its keys repeat it as the next key, as evil-snipe's transient map has it.
    var snipeRepeatKeys: (forward: KeyChord, backward: KeyChord)?
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
    /// The context's half page and visible text for this key.
    var contextHalfPage = 15
    var contextVisible: Range<Int>?
    var contextOrg = false
    /// Keys are going into a macro register.
    public internal(set) var recording = false
    var lastMacro: Character?
    /// `$` in block visual state: every line to its end.
    var blockToEnd = false
    /// Replace state: each typed character's place, what it overwrote (nil past the line's
    /// end) and its length; the text typed, and the count to repeat it.
    var replaceStack: [(offset: Int, original: String?, length: Int)] = []
    var replaceTyped = ""
    var replaceCount = 1

    public init() {}

    // MARK: - Feeding keys

    public mutating func feed(_ key: KeyChord, _ context: Context) -> [Action] {
        switch mode {
        case .insert:
            return insertKey(key, context)
        case .replace:
            return replaceKey(key, context)
        case .normal, .visual, .visualLine, .visualBlock:
            var key = key
            if pending.isEmpty, let repeatKeys = snipeRepeatKeys {
                if key == repeatKeys.forward { key = KeyChord(";") } else if key == repeatKeys.backward { key = KeyChord(",") }
            }
            if pending.isEmpty { snipeRepeatKeys = nil }
            pending.append(key)
            let keys = pending
            caretForApply = context.caret
            contextMarks = context.marks
            contextHalfPage = context.halfPage
            contextVisible = context.visible
            contextOrg = context.org
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

}
