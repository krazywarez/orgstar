import Foundation

/// How wide each character of a line is as Emacs displays Org text: bracket links show only
/// their description (or path), and with the options, emphasis markers are hidden and entities
/// and sub/superscripts show as their characters. Emacs's `current-column` counts only what is
/// visible, so tag alignment, filling and table widths all depend on this.
struct VisibleLine {
    /// Display width of the character starting at each UTF-16 offset; -1 for a tab.
    private var widths: [Int]
    /// Whether a character starts at each offset (false for the second half of a pair).
    private var starts: [Bool]
    private var hidden: [Bool]

    /// The line at `range` (UTF-16) inside `context`, which holds the lines around it so that
    /// links spanning lines are seen whole.
    init(_ context: String, line range: Range<Int>, options: EditingOptions, settings: OrgSettings = .default) {
        let whole = VisibleLine(context, options: options, settings: settings)
        widths = Array(whole.widths[range])
        starts = Array(whole.starts[range])
        hidden = Array(whole.hidden[range])
    }

    init(_ line: String, options: EditingOptions, settings: OrgSettings = .default) {
        let count = line.utf16.count
        widths = [Int](repeating: 0, count: count)
        starts = [Bool](repeating: false, count: count)
        hidden = [Bool](repeating: false, count: count)
        var index = 0
        for character in line {
            widths[index] = character == "\t" ? -1 : displayWidth(of: character)
            starts[index] = true
            index += String(character).utf16.count
        }
        let needsLinks = line.contains("[[")
        let needsEmphasis = options.hideEmphasisMarkers && line.contains(where: { "*/_+=~".contains($0) })
        if needsLinks || needsEmphasis {
            let tree = OrgParser.parse(line + "\n", defaults: settings)
            for node in tree.root.descendants() {
                switch node.kind {
                case .link where node.text.hasPrefix("[["):
                    if let description = node.firstChild(.linkDescription) {
                        hide(node.range.lowerBound..<description.range.lowerBound)
                        hide(description.range.upperBound..<node.range.upperBound)
                    } else {
                        hide(node.range.lowerBound..<(node.range.lowerBound + 2))
                        hide((node.range.upperBound - 2)..<node.range.upperBound)
                    }
                case .bold, .italic, .underline, .strikeThrough, .verbatim, .code:
                    guard options.hideEmphasisMarkers else { break }
                    hide(node.range.lowerBound..<(node.range.lowerBound + 1))
                    hide((node.range.upperBound - 1)..<node.range.upperBound)
                default:
                    break
                }
            }
        }
        if options.prettyEntities, line.contains(where: { $0 == "\\" || $0 == "_" || $0 == "^" }) {
            let ns = line as NSString
            let all = NSRange(location: 0, length: ns.length)
            // `org-fontify-entities`: a single-character entity is composed into one glyph.
            // Positions inside it stay at its starting column; its width counts at its end.
            let entity = try! NSRegularExpression(pattern: "\\\\(there4|sup[123]|frac[13][24]|[a-zA-Z]+)($|\\{\\}|[^\\p{L}\\n])")
            for match in entity.matches(in: line, range: all) {
                guard let display = OrgEntities.display[ns.substring(with: match.range(at: 1))], display.count == 1 else { continue }
                let end = ns.substring(with: match.range(at: 2)) == "{}" ? NSMaxRange(match.range(at: 2)) : NSMaxRange(match.range(at: 1))
                for i in match.range.location..<end where i < widths.count { widths[i] = 0 }
                widths[end - 1] = displayWidth(display)
            }
            let pattern = options.subSuperscriptsNeedBraces
                ? "\\S([_^])(\\{)[^{}\\n]*(\\})"
                : "\\S([_^])(?:(\\{)[^{}\\n]*(\\})|[*]|[-+]?[^-+*!@#$%^_ \\t\\r\\n,:\"?<>~;./{}=()]+)"
            for match in try! NSRegularExpression(pattern: pattern).matches(in: line, range: all) {
                for group in 1...3 where match.range(at: group).location != NSNotFound {
                    hide(match.range(at: group).location..<NSMaxRange(match.range(at: group)))
                }
            }
        }
    }

    private mutating func hide(_ range: Range<Int>) {
        for i in range where i >= 0 && i < hidden.count { hidden[i] = true }
    }

    private func advance(_ column: Int, _ i: Int) -> Int {
        widths[i] < 0 ? (column / 8 + 1) * 8 : column + widths[i]
    }

    /// Display column at UTF-16 `offset`.
    func column(at offset: Int) -> Int {
        var column = 0
        for i in 0..<min(offset, widths.count) where starts[i] && !hidden[i] {
            column = advance(column, i)
        }
        return column
    }

    var width: Int { column(at: widths.count) }

    /// `move-to-column`: hidden text is skipped before the goal test, so point ends past
    /// markup that sits at the goal column.
    func offset(ofColumn target: Int) -> Int {
        var column = 0
        var i = 0
        while true {
            while i < widths.count, hidden[i] || !starts[i] { i += 1 }
            if column >= target || i >= widths.count { break }
            column = advance(column, i)
            i += 1
        }
        return i
    }
}
