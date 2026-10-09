import Foundation
import Testing
@testable import OrgCore

/// `org-search-view` against Emacs.
struct AgendaSearchTests {
    static let first = """
    #+TODO: TODO NEXT | DONE
    Rent before the first heading.
    * TODO [#A] Pay rent :home:
    SCHEDULED: <2026-10-01 Thu>
    Ask the landlord about the boiler.
    * Meeting 10:00 with Bob
    Notes about the end of
    the line, and Bob's plan.
    * DONE Paid the rent
    * NEXT Report :work:
    ** Section with alpha and beta
    Alpha only here, and a boilerplate.
    ** Section with alpha
    Gamma.
    * todo list of chores
    Water the plants, alpha.
    * Archived :ARCHIVE:
    The rent is here too.
    ** TODO Under archived rent
    * COMMENT Commented rent
    * Two words
    The phrase two   words
    spans here; foo_bar and foo-bar.
    * The last
    word ends this entry with last
    * word starts the next heading
    * Ünïcode tïtle :tag:
    Straße and STRASSE.
    """

    static let second = """
    #+CATEGORY: other
    * WAIT Second file rent
    * Plans
    alpha, beta, gamma in the body.
    ** HOLD Nested beta
    * Headline alpha
    """

    static let strings = [
        // Phrases.
        "rent", "RENT", "pay rent", "end of the line", "end of\nthe", "two words", "last word",
        // A match ending in the next heading's line selects that entry.
        "last * word","Bob's", "boiler",
        "straße", "foo_bar", "10:00", "nothing at all", "alpha, beta",
        // Boolean.
        "+alpha", "+alpha -beta", "+alpha +gamma", "-alpha", "+beta -nested", "{alph?a}", "+{^Gam}", "-{b[eo]}",
        "+{\\<rent\\>}", "+\"two words\"", "+\"two   words\"", "+\"the line\"", "{boiler\\b}", "+alpha +\"in the body\"",
        "+{foo\\s-bar}", "+boiler -plate", "+{a b}", "+{alpha} -{x y}",
        // Headlines only.
        "*rent", "*alpha", "*+alpha -beta", "*+section", "*-alpha", "*pay rent", "*with alpha and",
        // TODO only and whole words.
        "!rent", "!+alpha", "*!section", ":+boiler", ":+alpha", "+:boiler", ":boiler", "*!:+rent",
    ]

    static func lisp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static let files = [("a.org", first), ("b.org", second)]
    static let today = Days.absolute(year: 2026, month: 10, day: 5)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func searchMatchesEmacs() throws {
        for string in Self.strings {
            for todoOnly in [false, true] {
                try AgendaOracle.compareList(files: Self.files, form: "(org-search-view \(todoOnly ? "t" : "nil") \(Self.lisp(string)))", today: Self.today) {
                    Agenda.textSearch($0, string: string, todoOnly: todoOnly)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func searchOptionsMatchEmacs() throws {
        for string in ["boiler", "+boiler", "alpha beta", "+alpha -beta", "{^Gam}", "two words", "*rent", "rent -paid", "+\"two words\""] {
            for (boolean, full) in [(true, false), (false, true), (true, true)] {
                var options = AgendaOptions()
                options.searchAlwaysBoolean = boolean
                options.searchForceFullWords = full
                let form = "(let ((org-agenda-search-view-always-boolean \(boolean ? "t" : "nil")) (org-agenda-search-view-force-full-words \(full ? "t" : "nil"))) (org-search-view nil \(Self.lisp(string))))"
                try AgendaOracle.compareList(files: Self.files, form: form, today: Self.today) {
                    Agenda.textSearch($0, string: string, options: options)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func searchPrefixMatchesEmacs() throws {
        let formats = ["search": "%c %?-5:l %b", "agenda": " %i %-12:c%?-12t% s", "todo": " %i %-12:c", "tags": " %i %-12:c"]
        var options = AgendaOptions()
        options.prefixFormat = formats
        let form = "(let ((org-agenda-prefix-format \(AgendaOracle.prefixLisp(formats)))) (org-search-view nil \"alpha\"))"
        try AgendaOracle.compareList(files: Self.files, form: form, today: Self.today) {
            Agenda.textSearch($0, string: "alpha", options: options)
        }
    }

    @Test func parsesSnippets() {
        let query = Agenda.SearchQuery("*!:+alpha -\"two words\" {a b} back\\ slash", todoOnly: false, options: AgendaOptions())
        #expect(query.headlinesOnly && query.todoOnly && query.boolean)
        #expect(query.positive.map(\.emacs) == ["\\<back slash\\>","\\<alpha\\>", "a b"])
        #expect(query.negative.map(\.emacs) == ["\\<two words\\>"])
        let phrase = Agenda.SearchQuery("pay  rent.", todoOnly: false, options: AgendaOptions())
        #expect(!phrase.boolean && phrase.positive.map(\.emacs) == ["pay\\s-+rent\\."])
    }
}
