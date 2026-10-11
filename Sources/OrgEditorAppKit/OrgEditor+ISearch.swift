#if os(macOS)
import AppKit
import OrgCore

// Incremental search: C-s and C-r in the Emacs preset, `/` and `?` in the Doom preset. While
// it runs, keys go to the search; the match is selected and the other matches highlighted.
extension OrgEditor {
    /// Starts searching from the caret. `vim`: `/` or `?`, which end with Vim's search, so `n`
    /// and `N` repeat it.
    func startISearch(forward: Bool, vim: Bool = false, regexp: Bool = false) {
        isearch = ISearch(origin: textView.selectedRange().location, forward: forward, previous: Self.lastISearch, regexp: regexp || vim)
        isearchVim = vim
        showISearch()
    }

    /// A key while searching: true when the search took it, false when the search ended
    /// and the key should run as usual.
    func isearchKey(_ chord: KeyChord) -> Bool {
        guard var search = isearch else { return false }
        let text = document.text
        switch (chord.key, chord.modifiers) {
        case ("s", [.control]) where !isearchVim, ("s", [.control, .meta]) where !isearchVim:
            search.again(forward: true, in: text)
        case ("r", [.control]) where !isearchVim, ("r", [.control, .meta]) where !isearchVim:
            search.again(forward: false, in: text)
        case ("DEL", []):
            if isearchVim, search.string.isEmpty {
                endISearch(caret: search.origin)
                return true
            }
            search.delete()
        case ("g", [.control]):
            if search.abort() {
                isearch = search
                showISearch()
            } else {
                endISearch(caret: search.origin)
                onMessage?("Quit")
            }
            return true
        case ("ESC", []) where isearchVim:
            endISearch(caret: search.origin)
            return true
        case ("RET", []):
            finishISearch(search)
            return true
        case ("SPC", []):
            search.add(" ", in: text)
        case (let key, let modifiers) where key.count == 1 && (modifiers.isEmpty || modifiers == [.shift]):
            search.add(key, in: text)
        default:
            // Any other key ends the search where it is, then runs.
            finishISearch(search)
            return false
        }
        isearch = search
        showISearch()
        return true
    }

    private func finishISearch(_ search: ISearch) {
        if !search.string.isEmpty { Self.lastISearch = search.string }
        if isearchVim, !search.string.isEmpty {
            endISearch(caret: search.origin)
            let context = Vim.Context(text: document.text, caret: search.origin)
            apply(vim.search(search.string, forward: search.state.forward, context))
            updateCursor()
        } else {
            endISearch(caret: search.point)
        }
    }

    private func endISearch(caret: Int) {
        isearch = nil
        setISearchHighlights([])
        setCaret(caret)
    }

    /// The match selected, the others highlighted, and the prompt in the echo area.
    private func showISearch() {
        guard let search = isearch else { return }
        if let match = search.match {
            // Folded text around the match opens, as `isearch-open-invisible` opens it.
            reveal(match.lowerBound)
            textView.setSelectedRange(NSRange(location: match.lowerBound, length: match.count))
            textView.scrollRangeToVisible(NSRange(location: match.lowerBound, length: match.count))
        } else {
            textView.setSelectedRange(NSRange(location: search.point, length: 0))
        }
        var others: [Range<Int>] = []
        if !search.string.isEmpty, let regex = ISearch.pattern(search.string, regexp: search.regexp) {
            for m in regex.matches(in: document.text, range: NSRange(location: 0, length: utf16Length)).prefix(1000) where m.range.length > 0 {
                let range = m.range.location..<NSMaxRange(m.range)
                if range != search.match { others.append(range) }
            }
        }
        setISearchHighlights(others)
        onMessage?(isearchVim ? (search.state.forward ? "/" : "?") + search.string : search.message)
    }

    private func setISearchHighlights(_ ranges: [Range<Int>]) {
        let old = highlights
        highlights = ranges
        for range in old + ranges where range.upperBound <= utf16Length { restyleOutsideEditing(range) }
        redrawViews()
    }
}
#endif
