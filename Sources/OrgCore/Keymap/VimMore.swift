import Foundation

// Scrolling the caret's line (`zz`, `zt`, `zb`), numbers (`C-a`, and Doom's evil-numbers keys
// `g=` and `g-`), replace state (`R`) and the command-line window (`q:`).

extension Vim {
    /// Where `zz`, `zt` and `zb` put the caret's line in the window.
    public enum ScrollLine: Sendable, Equatable {
        case center, top, bottom
    }

    mutating func parseMore(_ rest: ArraySlice<KeyChord>, _ buffer: inout Buffer, _ context: Context, count: Int?, keys: [KeyChord]) -> Parse? {
        guard let first = rest.first else { return nil }
        let visual = mode == .visual || mode == .visualLine
        let second = rest.dropFirst().first
        let n = count ?? 1
        let caret = context.caret
        if first == KeyChord("a", .control) {
            return .done(visual ? incrementVisual(buffer, caret, by: n, incremental: false) : increment(buffer, caret, by: n, keys: keys))
        }
        guard first.modifiers.isEmpty else { return nil }
        switch first.key {
        case "z" where !visual:
            guard let second else { return .incomplete }
            guard second.modifiers.isEmpty else { return nil }
            let place: ScrollLine
            switch second.key {
            case "z", ".": place = .center
            case "t", "RET": place = .top
            case "b", "-": place = .bottom
            default: return nil
            }
            // A count names the line; `z.`, `z RET` and `z-` go to its first non-blank.
            var target = caret
            if let count {
                let line = buffer.lineOffset(count)
                target = buffer.clampNormal(min(line + (caret - buffer.lineStart(caret)), buffer.lineEnd(line)), in: line)
            }
            if [".", "RET", "-"].contains(second.key) { target = buffer.firstNonBlank(buffer.lineStart(target)) }
            return .done((target == caret ? [] : [.move(caret: target)]) + [.scroll(place)])
        case "g":
            guard let second else { return .incomplete }
            if second == KeyChord("a", .control), visual { return .done(incrementVisual(buffer, caret, by: n, incremental: true)) }
            guard second.modifiers.isEmpty else { return nil }
            switch (second.key, visual) {
            case ("=", false): return .done(increment(buffer, caret, by: n, keys: keys))
            case ("-", false): return .done(increment(buffer, caret, by: -n, keys: keys))
            case ("=", true): return .done(incrementVisual(buffer, caret, by: n, incremental: true))
            case ("-", true): return .done(incrementVisual(buffer, caret, by: -n, incremental: true))
            case ("+", true): return .done(incrementVisual(buffer, caret, by: n, incremental: false))
            default: return nil
            }
        case "R" where !visual:
            mode = .replace
            replaceStack = []
            replaceTyped = ""
            replaceCount = n
            changeKeys = keys
            return .done([])
        case "q" where !visual && !recording:
            guard let second else { return .incomplete }
            guard second.modifiers.isEmpty, [":", "/", "?"].contains(second.key) else { return nil }
            return .done([.commandWindow(second.key)])
        default:
            return nil
        }
    }

    // MARK: - Numbers

    /// The numbers of a line, as Vim reads them with `nrformats` `bin,hex`.
    static let numberPattern = try! NSRegularExpression(pattern: "0[xX][0-9a-fA-F]+|0[bB][01]+|-?[0-9]+")

    /// The number on `line` that ends after `from`, as Vim's `C-a` finds it.
    static func number(in buffer: Buffer, line: Int, from: Int, to: Int? = nil) -> NSRange? {
        let end = to ?? buffer.lineEnd(line)
        guard end > line else { return nil }
        let text = buffer.substring(line..<end)
        for m in numberPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) where line + NSMaxRange(m.range) > from {
            return NSRange(location: line + m.range.location, length: m.range.length)
        }
        return nil
    }

    /// `number` plus `amount`, in its own base, width and case.
    static func adding(_ amount: Int, to number: String) -> String {
        let lower = number.lowercased()
        if lower.hasPrefix("0x") || lower.hasPrefix("0b") {
            let radix = lower.hasPrefix("0x") ? 16 : 2
            let digits = String(number.dropFirst(2))
            let value = (Int(digits, radix: radix) ?? 0) &+ amount
            var out = String(UInt(bitPattern: value), radix: radix)
            if digits.contains(where: \.isUppercase) { out = out.uppercased() }
            if out.count < digits.count { out = String(repeating: "0", count: digits.count - out.count) + out }
            return String(number.prefix(2)) + out
        }
        let negative = number.hasPrefix("-")
        let digits = negative ? String(number.dropFirst()) : number
        let value = (Int(number) ?? 0) &+ amount
        var out = String(abs(value))
        // Leading zeros keep the width.
        if digits.count > 1, digits.hasPrefix("0"), out.count < digits.count { out = String(repeating: "0", count: digits.count - out.count) + out }
        return (value < 0 ? "-" : "") + out
    }

    /// `C-a` with a negative `amount` for `g-`: the number at or after the caret on its line;
    /// the caret ends on its last character.
    mutating func increment(_ buffer: Buffer, _ caret: Int, by amount: Int, keys: [KeyChord]) -> [Action] {
        guard let range = Self.number(in: buffer, line: buffer.lineStart(caret), from: caret) else { return [] }
        let replacement = Self.adding(amount, to: buffer.ns.substring(with: range))
        lastChange = (keys, nil)
        return [.edit([TextEdit(range: range.location..<NSMaxRange(range), replacement: replacement)], caret: range.location + replacement.utf16.count - 1)]
    }

    /// Visual `C-a` and Doom's `g=`, as evil-numbers does: every number in the selection by
    /// `amount`, or with `incremental` the nth by n times `amount`.
    mutating func incrementVisual(_ buffer: Buffer, _ caret: Int, by amount: Int, incremental: Bool) -> [Action] {
        let (range, linewise) = visualRange(buffer, caret)
        lastVisual = (anchor, caret, mode)
        mode = .normal
        let text = buffer.substring(range)
        var edits: [TextEdit] = []
        for (k, m) in Self.numberPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).enumerated() {
            let number = (text as NSString).substring(with: m.range)
            edits.append(TextEdit(range: (range.lowerBound + m.range.location)..<(range.lowerBound + NSMaxRange(m.range)),
                                  replacement: Self.adding(incremental ? amount * (k + 1) : amount, to: number)))
        }
        let start = linewise ? buffer.lineStart(range.lowerBound) : range.lowerBound
        return edits.isEmpty ? [.move(caret: buffer.clampNormal(start))] : [.edit(edits, caret: start)]
    }

    // MARK: - Replace state

    /// A key in replace state: characters overwrite the line's, past its end they add to it,
    /// RET breaks the line, backspace gives back what was overwritten, and ESC repeats the
    /// typed text for the count.
    mutating func replaceKey(_ key: KeyChord, _ context: Context) -> [Action] {
        changeKeys?.append(key)
        let buffer = Buffer(context)
        let caret = context.caret
        if key == KeyChord("ESC") || key == KeyChord("[", .control) || key == KeyChord("g", .control) {
            var actions: [Action] = []
            var text = context.text
            var at = caret
            for _ in 1..<max(1, replaceCount) {
                for character in replaceTyped {
                    let edit = Self.replacement(String(character), Buffer(text), at)
                    text = edit.edit.apply(to: text)
                    at = edit.caret
                    actions.append(.edit([edit.edit], caret: at))
                }
            }
            mode = .normal
            if let keys = changeKeys {
                lastChange = (keys, nil)
                changeKeys = nil
            }
            let lineStart = Buffer(text).lineStart(at)
            actions.append(.move(caret: at > lineStart ? at - 1 : at))
            return actions
        }
        if key == KeyChord("DEL") || key == KeyChord("h", .control) {
            guard let last = replaceStack.popLast() else {
                return caret > buffer.lineStart(caret) ? [.move(caret: caret - 1)] : []
            }
            if !replaceTyped.isEmpty { replaceTyped.removeLast() }
            let edit = TextEdit(range: last.offset..<(last.offset + last.length), replacement: last.original ?? "")
            return [.edit([edit], caret: last.offset)]
        }
        let typed: String
        switch key.key {
        case "SPC": typed = " "
        case "TAB": typed = "\t"
        case "RET": typed = "\n"
        default:
            guard key.modifiers.isEmpty || key.modifiers == [.shift], key.key.count == 1 else { return [] }
            typed = key.key
        }
        let result = Self.replacement(typed, buffer, caret)
        replaceStack.append((caret, result.original, typed.utf16.count))
        replaceTyped += typed
        return [.edit([result.edit], caret: result.caret)]
    }

    /// `typed` over the character at `caret`, or after the line's end (and for a line break)
    /// added there.
    static func replacement(_ typed: String, _ buffer: Buffer, _ caret: Int) -> (edit: TextEdit, caret: Int, original: String?) {
        let length = typed.utf16.count
        guard typed != "\n", caret < buffer.lineEnd(caret) else {
            return (TextEdit(range: caret..<caret, replacement: typed), caret + length, nil)
        }
        let characterEnd = NSMaxRange(buffer.ns.rangeOfComposedCharacterSequence(at: caret))
        let original = buffer.substring(caret..<characterEnd)
        return (TextEdit(range: caret..<characterEnd, replacement: typed), caret + length, original)
    }
}
