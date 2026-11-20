/// The names `NAME-mode` is a function for in `emacs -Q` (Emacs 31.1, Org 9.8.7, ox-odt
/// loaded): the source block languages ox-odt fontifies, after `org-src-lang-modes`.
enum ODTSourceModes {
    static func fontified(_ language: String) -> Bool {
        modes.contains(langModes[language] ?? language)
    }

    /// `org-src-lang-modes`.
    static let langModes: [String: String] = [
        "C": "c", "C++": "c++", "asymptote": "asy", "beamer": "latex", "calc": "fundamental", "cpp": "c++",
        "ditaa": "artist", "desktop": "conf-desktop", "dot": "graphviz-dot", "elisp": "emacs-lisp",
        "ocaml": "tuareg", "screen": "shell-script", "sqlite": "sql", "toml": "conf-toml", "shell": "sh",
        "ash": "sh", "sh": "sh", "bash": "sh", "jsh": "sh", "bash2": "sh", "dash": "sh", "dtksh": "sh",
        "ksh": "sh", "es": "sh", "rc": "sh", "itcsh": "sh", "tcsh": "sh", "jcsh": "sh", "csh": "sh",
        "ksh88": "sh", "oash": "sh", "pdksh": "sh", "mksh": "sh", "posix": "sh", "wksh": "sh", "wsh": "sh",
        "zsh": "sh", "rpm": "sh",
    ]

    static let modes: Set<String> = Set("""
        *table--cell-describe Buffer-menu Buffer-menu-group-by Info LaTeX TeX abbrev add-minor allout
        allout-widgets antlr antlr-v4 archive array artist asm authinfo auto-composition auto-compression
        auto-encryption auto-fill auto-image-file auto-insert auto-lower auto-raise auto-revert
        auto-revert-tail auto-save auto-save-visited autoconf awk bash-ts bat bibtex bibtex-style
        binary-overwrite blink-cursor bovine-grammar buffer-face bug-reference bug-reference-prog button c
        c++ c++-ts c-initialize-cc c-or-c++ c-or-c++-ts c-ts calendar capitalized-words center-line
        cfengine-auto cfengine2 cfengine3 change-log checkdoc-minor cl-font-lock-built-in
        cl-old-struct-compat clean cmake-ts column-number comint comint-fontify-input common-lisp compilation
        compilation-minor compilation-shell-minor completion-in-region completion-list completion-preview
        conf conf-colon conf-desktop conf-javaprop conf-npmrc conf-ppd conf-space conf-toml conf-unix
        conf-windows conf-xdefaults context-menu cperl csharp csharp-ts css css-ts cua cua-rectangle-mark
        cua-selection current-input cursor-face-highlight cursor-intangible cursor-sensor custom-group-of
        custom-set-minor customize cvs-status cwarn dcl decipher delete-selection delete-selection-local
        delete-trailing-whitespace delphi describe describe-minor desktop-save diary dictionary
        dictionary-tooltip diff diff-minor dired dirtrack display-battery display-fill-column-indicator
        display-line-numbers display-time dns doc-view doc-view-minor dockerfile-ts doctex double dsssl
        dynamic-completion ebrowse-member ebrowse-tree edit-abbrevs editorconfig editorconfig-conf eldoc
        electric-indent electric-indent-local electric-layout electric-layout-local electric-pair
        electric-pair-local electric-quote electric-quote-local elide-head elisp-byte-code elixir-ts
        emacs-authors emacs-lisp emacs-lock emacs-news emacs-news-view enriched epa-global-mail epa-mail erts
        eshell etags-regen etc-authors eww f90 fido fido-vertical file-name-shadow find-function flymake
        flyspell flyspell-prog follow font-lock font-lock-change font-lock-value-in-major footnote forms
        fortran frame--current-background frame--current-backround frame-set-background
        frame-terminal-default-bg fundamental gdb-script generic glasses global-auto-composition
        global-auto-revert global-completion-preview global-cwarn global-dictionary-tooltip
        global-display-fill-column-indicator global-display-line-numbers global-ede global-eldoc
        global-font-lock global-goto-address global-hi-lock global-highlight-changes global-hl-line
        global-prettify-symbols global-reveal global-so-long global-subword global-superword global-tab-line
        global-visual-line global-visual-wrap-prefix global-whitespace global-whitespace-newline
        global-window-tool-bar global-word-wrap-whitespace global-xref-mouse glyphless-display
        gnus-mailing-list gnus-score go-mod-ts go-ts go-work-ts goto-address goto-address-prog gpm-mouse grep
        gud-tooltip header-line-indent heex-ts help hexl hi-lock hide-ifdef highlight-changes
        highlight-changes-visible hl-line hs-indentation hs-minor html html-ts icalendar icomplete
        icomplete-vertical icon idl ido iimage image image-dired-minor image-minor indent-according-to
        indent-tabs indented-text isearch isearch--describe-regexp isearch--describe-word isearch-describe
        isearch-fold-quotes ispell-minor iswitchb java java-ts javascript jit-lock jit-lock-debug js js-base
        js-json js-jsx js-ts json-ts kill-ring-deindent latex ld-script less-css line-number lisp lisp-data
        lisp-interaction lock-file log-view lost-selection lua lua-ts m2 m4 mail mail-abbrevs makefile
        makefile-automake makefile-bsdmake makefile-gmake makefile-imake makefile-makepp master menu-bar
        menu-bar-display-line-numbers mercury message messages-buffer metafont metapost mh-folder mhtml
        mhtml-ts midnight minibuffer minibuffer-depth-indicate minibuffer-electric-default
        minibuffer-inactive minibuffer-nonselected minibuffer-regexp mixal mode-line-invisible modula-2
        mouse-avoidance mouse-shift-adjust mouse-wheel msb next-error-follow-minor normal
        normal-erase-is-backspace nroff nxml objc occur occur-edit octave octave-maybe opascal org org-agenda
        org-agenda-archives org-agenda-clockreport org-agenda-entry-text org-agenda-follow org-agenda-log
        org-babel-interpret-file org-beamer org-cdlatex org-check-for-org org-element--next org-export-stack
        org-fontify-like-in-org org-indent org-list-checkbox-radio org-num org-run-like-in-org org-src
        org-src-get-lang org-table-follow-field org-table-header-line orgtbl outline outline-minor overwrite
        package-autosuggest paragraph-indent-minor paragraph-indent-text pascal pending-delete perl php-ts
        picture pike pixel-scroll pixel-scroll-precision plain-TeX plain-tex plstore pr-toggle pr-txt
        prettify-special-glyphs prettify-symbols process-menu prog prolog ps python python-base python-ts
        rcirc-track-minor read-extended-command read-only recentf rectangle-mark refill reftex
        reftex-index-phrases reftex-isearch-minor repeat reveal rmail rng-validate rst rst-minor ruby
        ruby-base ruby-ts ruler rust-ts save-place save-place-local savehist scheme scroll-all scroll-lock
        scss semantic server ses set-auto set-binary set-buffer-major set-input set-input-interrupt
        set-input-meta sgml sh sh--redirect-bash-ts sh-base sh-electric-here-document shell-script show-paren
        show-paren-local sieve simula size-indication slitex smerge snmp snmpv2 so-long so-long-minor special
        speedbar-frame speedbar-window sql srecode-template srt strokes subword superword system-taskbar
        tab-bar tab-bar-history tab-line tab-switcher table-fixed-width tabulated-list tags-table tar tcl
        temp-buffer-resize tex texinfo text tildify todo todo-archive todo-filtered-items toggle-rot13
        toggle-viper toml-ts tooltip tooltip-show-help-non transient-mark treesit--explorer-tree
        treesit--read-major treesit-explore treesit-inspect tsx-ts tty-tip turn-off-follow
        turn-on-auto-revert turn-on-auto-revert-tail turn-on-eldoc turn-on-follow turn-on-gnus-dired
        turn-on-gnus-mailing-list turn-on-prettify-symbols turn-on-visual-line type-break typescript-ts
        typescript-ts-base undelete-frame universal-argument- url-handler variable-pitch vc vc-auto-revert
        vera verilog vhdl view viper visible visual-line visual-wrap-prefix wdired-change-to-wdired
        which-function which-key which-key-show-full-major which-key-show-major whitespace whitespace-newline
        whitespace-page-delimiters widget-minor windmove window-divider window-tool-bar winner wisent-grammar
        word-wrap-whitespace xml xref-mouse xterm-mouse yaml-ts zone
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
