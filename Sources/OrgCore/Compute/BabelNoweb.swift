import Foundation

extension Babel {
    // MARK: - Noweb

    /// `org-babel-noweb-p` in the `:eval` context.
    static func nowebEvaluates(_ value: String?) -> Bool {
        (value ?? "").split(whereSeparator: \.isWhitespace).contains { ["yes", "no-export", "strip-export", "eval", "strip-tangle"].contains(String($0)) }
    }

    /// `org-babel-noweb-p` for `:tangle`.
    static func nowebTangles(_ value: String?) -> Bool {
        (value ?? "").split(whereSeparator: \.isWhitespace).contains { ["yes", "tangle", "no-export", "strip-export", "strip-tangle"].contains(String($0)) }
    }

    /// `org-babel-expand-noweb-references` for evaluation: each `<<name>>` becomes the body of
    /// the block named so, or of every block with that `:noweb-ref`, joined by `:noweb-sep`, or
    /// the contents of the heading with that ID; the text before it on its line goes before
    /// each line it brings.
    /// `tangling` expands the blocks it brings in as tangling would (`:noweb tangle`), not as
    /// evaluation does.
    /// `links` gives a block's begin and end comments, for `:comments noweb` when tangling.
    static func expandNoweb(_ block: SrcBlockInfo, params: Params, model: DocumentModel, text: NSString, tangling: Bool = false, depth: Int = 0,
                            links: ((SrcBlockInfo, Params) throws -> (begin: String, end: String))? = nil) throws -> String {
        guard depth < 32 else { throw Failure.message("Noweb references nest too deeply") }
        let body = normalizedBody(block)
        let prefixing = params.single[":noweb-prefix"].map { $0 != "no" && $0 != "nil" } ?? true
        let commenting = tangling && links != nil && params.single[":comments"] == "noweb"
        func expand(_ other: SrcBlockInfo) throws -> String {
            let otherParams = try Params(block: other, model: model, text: text)
            let expands = tangling ? nowebTangles(otherParams.single[":noweb"]) : nowebEvaluates(otherParams.single[":noweb"])
            let b = expands
                ? try expandNoweb(other, params: otherParams, model: model, text: text, tangling: tangling, depth: depth + 1, links: links)
                : normalizedBody(other)
            guard commenting, let links else { return b }
            // `c-wrap`: commented in this block's language, trimmed.
            func wrap(_ s: String) throws -> String {
                try Tangle.commentRegion(s, language: block.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var (begin, end) = try links(other.name == nil ? block : other, other.name == nil ? params : otherParams)
            // A `:noweb-ref` block without a name: the link is the including block's, the name empty.
            if other.name == nil {
                if let split = begin.range(of: "][") { begin = begin[..<split.lowerBound] + "][]]" }
                end = " ends here"
            }
            return try wrap(begin) + "\n" + b + "\n" + (try wrap(end)) + "\n"
        }
        func inCommentedHeading(_ b: SrcBlockInfo) -> Bool {
            guard let h = b.heading else { return false }
            return ([h] + model.ancestors(of: h)).contains { model.headings[$0].title == "COMMENT" || model.headings[$0].title.hasPrefix("COMMENT ") }
        }
        let regex = try! NSRegularExpression(pattern: "(.*?)(<<([^ \\t\\n](?:.*?[^ \\t\\n])?)>>)")
        let ns = body as NSString
        var out = ""
        var at = 0
        for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let prefix = ns.substring(with: m.range(at: 1))
            let id = ns.substring(with: m.range(at: 3))
            out += ns.substring(with: NSRange(location: at, length: m.range(at: 2).location - at))
            at = NSMaxRange(m.range)
            var expansion = ""
            if id.range(of: "\\(.*\\)", options: .regularExpression) != nil {
                throw Failure.message("Noweb references that run a block (\(id)) aren't supported yet; nothing was run.")
            } else if let heading = model.headings.firstIndex(where: { h in
                h.properties.contains { ($0.key.uppercased() == "ID" && $0.value == id) || ($0.key.uppercased() == "CUSTOM_ID" && "#" + $0.value == id) }
            }) {
                expansion = headlineBody(heading, model: model, text: text)
            } else if let named = model.srcBlocks.first(where: { $0.name == id }), !inCommentedHeading(named) {
                expansion = try expand(named)
            } else {
                var parts: [String] = []
                var separators: [String] = []
                for other in model.srcBlocks where !inCommentedHeading(other) {
                    let p = try Params(block: other, model: model, text: text)
                    guard p.single[":noweb-ref"] == id else { continue }
                    parts.append(try expand(other))
                    separators.append(p.single[":noweb-sep"] ?? "\n")
                }
                for (i, part) in parts.enumerated() {
                    if i > 0 { expansion += separators[i - 1] }
                    expansion += part
                }
            }
            out += prefixing ? expansion.components(separatedBy: CharacterSet(charactersIn: "\n\r")).joined(separator: "\n" + prefix) : expansion
        }
        return out + ns.substring(from: at)
    }

    /// `org-babel-ref-headline-body`: the entry after its planning and drawers.
    static func headlineBody(_ index: Int, model: DocumentModel, text: NSString) -> String {
        let heading = model.headings[index]
        let buffer = EmacsBuffer(text as String, point: heading.headingRange.lowerBound)
        buffer.endOfMetaData()
        let start = buffer.point
        let end = model.headings[(index + 1)...].first.map { $0.headingRange.lowerBound } ?? text.length
        return start < end ? text.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// `org-babel--normalize-body`: without the final newline, and without the indentation
    /// common to its lines unless `-i` keeps it.
    static func normalizedBody(_ block: SrcBlockInfo) -> String {
        var lines = block.body.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // Org escapes lines starting with `*` or `#+` inside blocks with a comma.
        lines = lines.map { $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression) }
        if !block.switches.contains("-i") {
            let indents = lines.filter { $0.contains(where: { !$0.isWhitespace }) }.map { $0.prefix { $0 == " " || $0 == "\t" }.count }
            let common = indents.min() ?? 0
            lines = lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
        }
        return lines.joined(separator: "\n")
    }
}
