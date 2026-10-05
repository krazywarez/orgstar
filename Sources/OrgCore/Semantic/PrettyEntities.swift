import Foundation

/// What `org-pretty-entities` changes on a line (`org-fontify-entities`, `org-raise-scripts`):
/// single-character entities show as that character, and sub/superscripts lose their `_`, `^`
/// and braces.
public enum PrettyEntities {
    public enum Run: Equatable, Sendable {
        /// `\alpha` or `\alpha{}`, shown as `display`. Offsets are UTF-16, within the line.
        case entity(range: Range<Int>, display: String)
        /// A sub/superscript: `markers` (`_` or `^`, and braces) are hidden and `body` raised
        /// or lowered.
        case script(markers: [Range<Int>], body: Range<Int>, superscript: Bool)
    }

    static let entity = try! NSRegularExpression(pattern: "\\\\(there4|sup[123]|frac[13][24]|[a-zA-Z]+)($|\\{\\}|[^\\p{L}\\n])")
    static let scriptsWithBraces = try! NSRegularExpression(pattern: "\\S([_^])(\\{)[^{}\\n]*(\\})")
    static let scripts = try! NSRegularExpression(pattern: "\\S([_^])(?:(\\{)[^{}\\n]*(\\})|[*]|[-+]?[^-+*!@#$%^_ \\t\\r\\n,:\"?<>~;./{}=()]+)")

    public static func runs(in line: String, subSuperscriptsNeedBraces: Bool) -> [Run] {
        guard line.contains(where: { $0 == "\\" || $0 == "_" || $0 == "^" }) else { return [] }
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        var runs: [Run] = []
        for match in entity.matches(in: line, range: all) {
            guard let display = OrgEntities.display[ns.substring(with: match.range(at: 1))], display.count == 1 else { continue }
            let end = ns.substring(with: match.range(at: 2)) == "{}" ? NSMaxRange(match.range(at: 2)) : NSMaxRange(match.range(at: 1))
            runs.append(.entity(range: match.range.location..<end, display: display))
        }
        // `org-raise-scripts` searches again from the last character of a match that a `_` or
        // `^` follows, so `a_b^c` raises both.
        let regex = subSuperscriptsNeedBraces ? scriptsWithBraces : scripts
        var matches: [NSTextCheckingResult] = []
        var from = 0
        while from < ns.length, let match = regex.firstMatch(in: line, range: NSRange(location: from, length: ns.length - from)) {
            matches.append(match)
            let end = NSMaxRange(match.range)
            from = end < ns.length && (ns.character(at: end) == 95 || ns.character(at: end) == 94) ? end - 1 : end
            if from <= match.range.location { from = match.range.location + 1 }
        }
        for match in matches {
            let markers = (1...3).compactMap { group -> Range<Int>? in
                let r = match.range(at: group)
                return r.location == NSNotFound ? nil : r.location..<NSMaxRange(r)
            }
            let marker = match.range(at: 1)
            let hasBraces = match.range(at: 2).location != NSNotFound
            let body = hasBraces
                ? NSMaxRange(match.range(at: 2))..<match.range(at: 3).location
                : NSMaxRange(marker)..<NSMaxRange(match.range)
            runs.append(.script(markers: markers, body: body, superscript: ns.substring(with: marker) == "^"))
        }
        return runs
    }
}
