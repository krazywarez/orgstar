import Foundation
import Testing
@testable import OrgCore

/// `org-export-translate`, against Emacs, for the words the exporters write.
struct ExportDictionaryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func translatesLikeOrgExportTranslate() throws {
        let terms = ["Table of Contents", "Figure %d:", "Footnotes"]
        let languages = ["en", "de", "fr", "es", "ja", "ru", "pt_BR", "zh-CN", "ca", "xx"]
        let encodings: [ExportDictionary.Encoding] = [.html, .utf8, .ascii]
        var keys: [(String, String, ExportDictionary.Encoding)] = []
        var forms: [String] = []
        for term in terms {
            for language in languages {
                for encoding in encodings {
                    keys.append((term, language, encoding))
                    forms.append("(org-export-translate \(term.debugDescription) :\(encoding.rawValue) (list :language \(language.debugDescription)))")
                }
            }
        }
        let form = "(progn (require 'ox) (erase-buffer) (insert (mapconcat #'identity (list \(forms.joined(separator: " "))) \"\\n\")))"
        let theirs = try EmacsOracle.run([EmacsOracle.Case(text: "", point: 1, form: form)])[0].text.components(separatedBy: "\n")
        #expect(theirs.count == keys.count)
        for (key, value) in zip(keys, theirs) {
            #expect(ExportDictionary.translate(key.0, language: key.1, encoding: key.2) == value, "\(key)")
        }
    }

    @Test func htmlExportUsesTheLanguage() {
        let text = "#+LANGUAGE: de\n#+OPTIONS: toc:t\n* Eins\nText[fn:1]\n\n#+CAPTION: Bild\n[[file:a.png]]\n\n[fn:1] Note.\n"
        let html = HTMLExport.page(text, fallbackTitle: "t")
        #expect(html.contains("<html lang=\"de\">"))
        #expect(html.contains("<h2>Inhaltsverzeichnis</h2>"))
        #expect(html.contains("aria-label=\"Fu&szlig;noten\""))
        #expect(html.contains("<figcaption>Abbildung 1: Bild</figcaption>"))
        let fallback = HTMLExport.page("#+OPTIONS: toc:t\n* One\n", fallbackTitle: "t", language: "fr")
        #expect(fallback.contains("<html lang=\"fr\">") && fallback.contains("<h2>Table des matières</h2>"))
    }
}
