#if os(iOS)
import OrgPresentation
import UIKit

extension NSAttributedString.Key {
    /// A word the editor's spell checker found misspelt.
    static let orgMisspelled = NSAttributedString.Key("OrgMisspelled")
}

/// Spell checking outside code, links, dates, tags and keywords, as the Mac's spell checker
/// is kept out of them (`SpellCheck.skipped`). UITextView can't leave ranges out of its own
/// checking, so with `spell-check` on the editor checks with UITextChecker itself, marks the
/// words, and offers guesses in the edit menu.
extension MobileEditor {
    /// The first preferred language the checker has, else US English.
    static let spellLanguage: String = {
        let available = UITextChecker.availableLanguages
        for preferred in Locale.preferredLanguages {
            let id = preferred.replacingOccurrences(of: "-", with: "_")
            if available.contains(id) { return id }
            let base = String(id.prefix { $0 != "_" })
            if let match = available.first(where: { $0 == base || $0.hasPrefix(base + "_") }) { return match }
        }
        return "en_US"
    }()

    static let spellChecker = UITextChecker()

    /// Marks the misspelt words in `range`, leaving out the word being typed at the caret.
    func markMisspellings(in range: Range<Int>, storage: NSTextStorage) {
        let string = storage.string
        let caret = textView.isFirstResponder && textView.selectedRange.length == 0 ? textView.selectedRange.location : nil
        let skipped = spellSkipped()
        for part in SpellCheck.checkable(range, skipped: skipped) {
            var start = part.lowerBound
            while start < part.upperBound {
                let found = Self.spellChecker.rangeOfMisspelledWord(
                    in: string, range: NSRange(part), startingAt: start, wrap: false, language: Self.spellLanguage
                )
                guard found.location != NSNotFound, found.location >= start else { break }
                start = NSMaxRange(found)
                if let caret, caret >= found.location, caret <= NSMaxRange(found) { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                    .underlineColor: UIColor.systemRed,
                    .orgMisspelled: true,
                ], range: found)
            }
        }
    }

    /// The skipped ranges for the buffer's current text, kept until it changes.
    func spellSkipped() -> [Range<Int>] {
        if let cached = spellSkipCache, cached.revision == document.revision { return cached.ranges }
        let ranges = SpellCheck.skipped(document.tree)
        spellSkipCache = (document.revision, ranges)
        return ranges
    }

    /// Guesses for the misspelt word at `range`, and Learn Spelling, above the system's actions.
    func spellingMenu(for range: NSRange, in view: UITextView, suggested: [UIMenuElement]) -> UIMenu? {
        let storage = view.textStorage
        let location = range.location < storage.length && storage.attribute(.orgMisspelled, at: range.location, effectiveRange: nil) != nil
            ? range.location : range.location - 1
        guard location >= 0, location < storage.length else { return nil }
        var word = NSRange()
        guard storage.attribute(.orgMisspelled, at: location, longestEffectiveRange: &word, in: NSRange(location: 0, length: storage.length)) != nil else { return nil }
        let text = (storage.string as NSString).substring(with: word)
        let guesses = Self.spellChecker.guesses(forWordRange: word, in: storage.string, language: Self.spellLanguage) ?? []
        var actions: [UIMenuElement] = guesses.prefix(5).map { guess in
            UIAction(title: guess) { [weak self, weak view] _ in
                guard let self, let view,
                      let start = view.position(from: view.beginningOfDocument, offset: word.location),
                      let end = view.position(from: start, offset: word.length),
                      let range = view.textRange(from: start, to: end) else { return }
                view.replace(range, withText: guess)
                self.restyle(word.location..<(word.location + (guess as NSString).length))
            }
        }
        actions.append(UIAction(title: "Learn Spelling", image: UIImage(systemName: "book")) { [weak self] _ in
            UITextChecker.learnWord(text)
            self?.restyle(word.location..<NSMaxRange(word))
        })
        return UIMenu(children: [UIMenu(options: .displayInline, children: actions)] + suggested)
    }
}
#endif
