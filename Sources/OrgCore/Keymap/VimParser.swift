import Foundation

extension Vim {
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
            if ["~", "u", "U", "c", "q", "w"].contains(second.key), second.modifiers.isEmpty {
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
                case "Z": return .done([.ex("wq")])
                case "Q": return .done([.ex("q!")])
                default: return .invalid
                }
            default:
                break
            }
        }

        if mode == .normal, !contextOrg, rest.count == 2, first == KeyChord("g"), rest.last == KeyChord("j") || rest.last == KeyChord("k") {
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
}
