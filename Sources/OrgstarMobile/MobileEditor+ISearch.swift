#if os(iOS)
import OrgCore
import UIKit

// Incremental search: C-s and C-r with a hardware keyboard in the Emacs preset, or from
// Commands. While it runs, typed keys go to the search and the match is selected.
extension MobileEditor {
    func startISearch(forward: Bool, regexp: Bool = false) {
        isearch = ISearch(origin: textView.selectedRange.location, forward: forward, previous: Self.lastISearch, regexp: regexp)
        showISearch()
    }

    /// A key while searching: true when the search took it, false when the search ended and
    /// the key should run as usual.
    func isearchKey(_ chord: KeyChord) -> Bool {
        guard var search = isearch else { return false }
        let text = document.text
        switch (chord.key, chord.modifiers) {
        case ("s", [.control]), ("s", [.control, .meta]): search.again(forward: true, in: text)
        case ("r", [.control]), ("r", [.control, .meta]): search.again(forward: false, in: text)
        case ("DEL", []): search.delete()
        case ("g", [.control]):
            if search.abort() {
                isearch = search
                showISearch()
            } else {
                endISearch(caret: search.origin)
                onMessage?("Quit")
            }
            return true
        case ("RET", []):
            finishISearch(search)
            return true
        case ("SPC", []): search.add(" ", in: text)
        case (let key, let modifiers) where key.count == 1 && (modifiers.isEmpty || modifiers == [.shift]):
            search.add(key, in: text)
        default:
            finishISearch(search)
            return false
        }
        isearch = search
        showISearch()
        return true
    }

    /// Text from the on-screen keyboard while searching: it goes into the search string.
    func isearchTyped(_ typed: String) {
        guard var search = isearch else { return }
        if typed == "\n" { return finishISearch(search) }
        if typed.isEmpty {
            search.delete()
        } else {
            search.add(typed, in: document.text)
        }
        isearch = search
        showISearch()
    }

    func finishISearch(_ search: ISearch) {
        if !search.string.isEmpty { Self.lastISearch = search.string }
        endISearch(caret: search.point)
    }

    private func endISearch(caret: Int) {
        isearch = nil
        textView.selectedRange = NSRange(location: caret, length: 0)
    }

    private func showISearch() {
        guard let search = isearch else { return }
        if let match = search.match {
            reveal(match.lowerBound)
            textView.selectedRange = NSRange(location: match.lowerBound, length: match.count)
            textView.scrollRangeToVisible(textView.selectedRange)
        } else {
            textView.selectedRange = NSRange(location: search.point, length: 0)
        }
        onMessage?(search.message)
    }
}
#endif
