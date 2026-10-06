// From Org 9.8.7 with the default export back-ends (ascii, html, icalendar, latex, odt).

extension OrgCompletion {
    /// `org-options-keywords`, affiliated keywords, `org-block-keywords` and the back-ends'
    /// keywords, as `pcomplete/org-mode/file-option` offers them.
    static let fileOptions: [String] = {
        let options = ["ARCHIVE:", "AUTHOR:", "BIBLIOGRAPHY:", "BIND:", "CATEGORY:", "CITE_EXPORT:", "COLUMNS:", "CREATOR:", "DATE:", "DESCRIPTION:",
                       "DRAWERS:", "EMAIL:", "EXCLUDE_TAGS:", "FILETAGS:", "INCLUDE:", "INDEX:", "KEYWORDS:", "LANGUAGE:", "MACRO:", "OPTIONS:",
                       "PROPERTY:", "PRINT_BIBLIOGRAPHY:", "PRIORITIES:", "SELECT_TAGS:", "SEQ_TODO:", "SETUPFILE:", "STARTUP:", "TAGS:", "TITLE:",
                       "TODO:", "TYP_TODO:", "EXPORT_FILE_NAME:"]
        let affiliated = ["CAPTION", "DATA", "HEADER", "HEADERS", "LABEL", "NAME", "PLOT", "RESNAME", "RESULT", "RESULTS", "SOURCE", "SRCNAME", "TBLNAME"]
        let blocks = ["CENTER", "COMMENT", "EXAMPLE", "EXPORT", "QUOTE", "SRC", "VERSE"].flatMap { name in
            ["ATTR_\(name): ", "BEGIN_\(name)" + (name == "EXPORT" || name == "SRC" ? " " : ""), "END_\(name)"]
        }
        let export = ["SUBTITLE", "ATTR_ASCII", "ASCII", "LATEX_HEADER", "CREATOR", "INFOJS_OPT", "HTML_HEAD_EXTRA", "HTML_HEAD",
                      "HTML_EQUATION_REFERENCE_FORMAT", "HTML_MATHJAX", "HTML_LINK_UP", "HTML_LINK_HOME", "KEYWORDS", "DESCRIPTION",
                      "HTML_CONTENT_CLASS", "HTML_CONTAINER", "HTML_DOCTYPE", "ATTR_HTML", "HTML", "ICAL-TTL", "ICALENDAR_EXCLUDE_TAGS",
                      "ATTR_ICALENDAR", "ICALENDAR", "DATE", "LATEX_COMPILER", "LATEX_ENGRAVED_THEME", "LATEX_FOOTNOTE_COMMAND",
                      "LATEX_CLASS_PRE", "LATEX_HEADER_EXTRA", "LATEX_CLASS_OPTIONS", "LATEX_CLASS", "ATTR_LATEX", "LATEX", "ODT_STYLES_FILE",
                      "ATTR_ODT", "ODT"]
        return options.map { $0 + " " } + affiliated.map { $0 + ": " } + blocks + export.map { $0 + ": " }
    }()

    /// `org-startup-options`.
    static let startupOptions = [
        "align", "beamer", "constSI", "constcgs", "content", "customtime", "descriptivelinks", "entitiesplain", "entitiespretty", "fnadjust",
        "fnanon", "fnauto", "fnconfirm", "fninline", "fnlocal", "fnplain", "fnprompt", "fold", "hideblocks", "hidedrawers", "hidestars", "indent",
        "inlineimages", "latexpreview", "linkpreviews", "literallinks", "logdone", "logdrawer", "lognoteclock-out", "lognotedone",
        "lognoteredeadline", "lognoterefile", "lognoterepeat", "lognotereschedule", "logredeadline", "logrefile", "logrepeat", "logreschedule",
        "logstatesreversed", "noalign", "nofnadjust", "nofninline", "nofold", "nohideblocks", "nohidedrawers", "noindent", "noinlineimages",
        "nolatexpreview", "nolinkpreviews", "nologdone", "nologdrawer", "nolognoteclock-out", "nologredeadline", "nologrefile", "nologrepeat",
        "nologreschedule", "nologstatesreversed", "nonum", "noptag", "num", "odd", "oddeven", "overview", "show2levels", "show3levels",
        "show4levels", "show5levels", "showall", "showeverything", "showstars", "shrink",
    ]

    /// `#+OPTIONS` items.
    static let exportOptions = [
        "H:", "\\n:", "num:", "timestamp:", "arch:", "author:", "c:", "creator:", "date:", "d:", "email:", "*:", "e:", "::", "f:", "inline:",
        "tex:", "p:", "pri:", "':", "-:", "stat:", "^:", "toc:", "|:", "tags:", "tasks:", "<:", "todo:",
        "html-self-link-headlines:", "html-scripts:", "html-style:", "html-preamble:", "html-postamble:", "html-link-use-abs-url:",
        "html5-fancy:", "latex-use-sans:",
    ]

    /// The languages of `org-babel-load-languages`'s customization type.
    static let languages = [
        "awk", "C", "R", "calc", "clojure", "css", "ditaa", "dot", "emacs-lisp", "eshell", "forth", "fortran", "gnuplot", "groovy", "haskell",
        "java", "js", "julia", "latex", "lilypond", "lisp", "lua", "makefile", "maxima", "ocaml", "octave", "org", "perl", "processing",
        "plantuml", "python", "ruby", "sass", "scheme", "screen", "sed", "shell", "sql", "sqlite",
    ]

    /// `org-babel-common-header-args-w-values` and switches.
    static let srcHeaders = [
        ":cache", ":cmdline", ":colnames", ":comments", ":dir", ":eval", ":exports", ":epilogue", ":file", ":file-desc", ":file-ext",
        ":file-mode", ":hlines", ":mkdirp", ":no-expand", ":noeval", ":noweb", ":noweb-ref", ":noweb-sep", ":noweb-prefix", ":output-dir",
        ":padline", ":post", ":prologue", ":results", ":rownames", ":sep", ":session", ":shebang", ":tangle", ":tangle-mode", ":var", ":wrap",
        "-n", "-r", "-l",
    ]

    static let clocktableOptions = [
        ":maxlevel", ":scope", ":lang", ":tstart", ":tend", ":block", ":step", ":stepskip0", ":fileskip0", ":emphasize", ":link", ":narrow",
        ":indent", ":hidefiles", ":tcolumns", ":level", ":compact", ":timestamp", ":formula", ":formatter", ":wstart", ":mstart",
    ]

    /// `org-default-properties`.
    static let defaultProperties = [
        "ARCHIVE", "CATEGORY", "SUMMARY", "DESCRIPTION", "CUSTOM_ID", "LOCATION", "LOGGING", "COLUMNS", "VISIBILITY", "TABLE_EXPORT_FORMAT",
        "TABLE_EXPORT_FILE", "EXPORT_OPTIONS", "EXPORT_TEXT", "EXPORT_FILE_NAME", "EXPORT_TITLE", "EXPORT_AUTHOR", "EXPORT_DATE", "UNNUMBERED",
        "ORDERED", "NOBLOCKING", "COOKIE_DATA", "LOG_INTO_DRAWER", "REPEAT_TO_STATE", "CLOCK_MODELINE_TOTAL", "STYLE", "HTML_CONTAINER_CLASS",
        "ORG-IMAGE-ACTUAL-WIDTH",
    ]

    /// Link types offered after `[[` besides `#+LINK` abbreviations.
    static let linkTypes = ["attachment", "doi", "file", "http", "https", "id", "mailto"]
}
