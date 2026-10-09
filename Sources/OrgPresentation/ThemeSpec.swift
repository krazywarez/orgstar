import OrgCore

/// A color as `#rrggbb` or `#rrggbbaa`.
public struct RGBA: Hashable, Sendable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        guard digits.first == "#" else { return nil }
        digits = digits.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? value << 8 | 0xFF : value
        red = Double(full >> 24 & 0xFF) / 255
        green = Double(full >> 16 & 0xFF) / 255
        blue = Double(full >> 8 & 0xFF) / 255
        alpha = Double(full & 0xFF) / 255
    }

    public var hex: String {
        func byte(_ d: Double) -> String {
            let s = String(Int((d * 255).rounded()), radix: 16)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }
}

/// The editor's look: colors for each kind of text in light and dark appearance, colors for
/// TODO keywords and categories, and type. Read from `[theme]`, `[theme.light]`, `[theme.dark]`,
/// `[theme.todo]` and `[theme.category]` in config.toml, on top of the default theme.
public struct ThemeSpec: Equatable, Sendable {
    /// A font family; empty for the system's monospaced font.
    public var font = ""
    public var fontSize = 13
    /// Points between lines.
    public var lineSpacing = 2
    /// Points a heading is larger than the next level down (level 4 and deeper are body size).
    public var headingSizeStep = 1
    public var light: [String: RGBA]
    public var dark: [String: RGBA]
    /// `org-todo-keyword-faces`: a color per keyword, the same in both appearances.
    public var todo: [String: RGBA] = [:]
    /// A color per agenda category, the same in both appearances, over `categoryColor`'s hue.
    public var category: [String: RGBA] = [:]

    public init(light: [String: RGBA], dark: [String: RGBA]) {
        self.light = light
        self.dark = dark
    }

    public func color(_ key: String, dark isDark: Bool) -> RGBA? {
        (isDark ? dark : light)[key]
    }

    // MARK: - Slots

    /// Every color key, with what it colors.
    public static let slots: [(key: String, description: String)] = [
        ("background", "the editor's background"),
        ("foreground", "body text"),
        ("cursor", "the caret"),
        ("selection", "selected text's background"),
        ("heading-1", "level 1 headings"), ("heading-2", "level 2 headings"), ("heading-3", "level 3 headings"),
        ("heading-4", "level 4 headings"), ("heading-5", "level 5 headings"), ("heading-6", "level 6 headings"),
        ("heading-7", "level 7 headings"), ("heading-8", "level 8 and deeper headings"),
        ("todo", "TODO keywords not yet done"),
        ("todo-next", "keywords of work under way: NEXT, STRT, STARTED, DOING, ACTIVE"),
        ("todo-waiting", "keywords of work on hold: WAIT, WAITING, HOLD, BLOCKED, DEFERRED, SOMEDAY, MAYBE"),
        ("done", "DONE keywords"),
        ("todo-cancelled", "done keywords that cancel: KILL, CANCELLED, CANCELED, CANCEL, SKIPPED, SKIP, ABORTED, NO, WONTFIX"),
        ("priority", "[#A] cookies"),
        ("priority-a", "agenda: priority A"),
        ("priority-b", "agenda: priority B"),
        ("priority-c", "agenda: priority C"),
        ("tags", ":tags:"),
        ("link", "links"),
        ("timestamp", "timestamps"),
        ("code", "~code~ and inline source"),
        ("verbatim", "=verbatim="),
        ("inline-background", "behind ~code~ and =verbatim="),
        ("markup", "link brackets and emphasis markers"),
        ("comment", "comments"),
        ("keyword", "#+KEYWORD lines"),
        ("metadata", "planning lines, drawers, properties and clocks"),
        ("special", "footnotes, statistics cookies, targets, macros and LaTeX"),
        ("block-background", "the band behind blocks"),
        ("block-delimiter", "#+begin_ and #+end_ lines"),
        ("table", "tables"),
        ("line-number", "line numbers"),
        ("line-number-current", "the caret's line number"),
        ("syntax-keyword", "code: keywords"),
        ("syntax-string", "code: strings"),
        ("syntax-comment", "code: comments"),
        ("syntax-function", "code: functions"),
        ("syntax-type", "code: types and modules"),
        ("syntax-number", "code: numbers, constants and escapes"),
        ("syntax-property", "code: properties, attributes and tags"),
        ("syntax-label", "code: labels"),
        ("sidebar-background", "the folder sidebar and the outline; unset: the system's"),
        ("sidebar-foreground", "file and heading names there; unset: the system's"),
        ("sidebar-header", "folder names there; unset: the system's"),
        ("modeline-background", "the modeline and message line; unset: the system's"),
        ("modeline-foreground", "modeline text; unset: the system's"),
        ("modeline-highlight", "the outline path and the clock in the modeline"),
        ("state-normal", "the NORMAL tag"),
        ("state-insert", "the INSERT tag"),
        ("state-visual", "the VISUAL and V-LINE tags"),
        ("agenda-background", "the agenda and board; unset: the system's"),
        ("agenda-date", "agenda day headers"),
        ("agenda-today", "today's header and the current time"),
        ("agenda-time", "times and the time grid"),
        ("agenda-category", "categories"),
        ("agenda-overdue", "agenda: the status of entries past their deadline or scheduled date"),
        ("agenda-due-soon", "agenda: the status of deadlines due today or coming up"),
        ("agenda-event", "agenda: calendar events whose calendar has no color"),
        ("habit-clear", "habit graph: not due yet"),
        ("habit-ready", "habit graph: due"),
        ("habit-alert", "habit graph: due today, last chance"),
        ("habit-overdue", "habit graph: overdue"),
    ]

    /// Keys the default theme leaves to the system, so windows keep the macOS look.
    public static let systemDefaults: Set<String> = [
        "sidebar-background", "sidebar-foreground", "sidebar-header", "modeline-background", "modeline-foreground", "agenda-background",
    ]

    // MARK: - The default theme

    private static func palette(_ pairs: [String: String]) -> [String: RGBA] {
        pairs.compactMapValues { RGBA(hex: $0) }
    }

    /// Calm colors after GitHub's light and dark themes for text and code: headings colored by
    /// level, code in the colors developers know. Keywords, priorities and the agenda's states
    /// use the system's accessible reds, oranges, blues and greens, so they match iOS and macOS.
    public static let `default` = ThemeSpec(
        light: palette([
            "background": "#ffffff", "foreground": "#1f2328", "cursor": "#0969da", "selection": "#0969da33",
            "heading-1": "#0550ae", "heading-2": "#8250df", "heading-3": "#116329", "heading-4": "#953800",
            "heading-5": "#0550ae", "heading-6": "#8250df", "heading-7": "#116329", "heading-8": "#953800",
            "todo": "#d70015", "done": "#248a3d", "priority": "#c93400", "tags": "#6e7781",
            "todo-next": "#0a66d8", "todo-waiting": "#b25000", "todo-cancelled": "#8e8e93",
            "priority-a": "#d70015", "priority-b": "#c93400", "priority-c": "#6c7a8c",
            "link": "#0969da", "timestamp": "#8250df", "code": "#953800", "verbatim": "#0a3069", "inline-background": "#afb8c133",
            "markup": "#8c959f", "comment": "#6e7781", "keyword": "#6e7781", "metadata": "#6e7781", "special": "#1b7c83",
            "block-background": "#f6f8fa", "block-delimiter": "#8c959f", "table": "#1f2328",
            "line-number": "#8c959f", "line-number-current": "#1f2328",
            "syntax-keyword": "#cf222e", "syntax-string": "#0a3069", "syntax-comment": "#6e7781", "syntax-function": "#8250df",
            "syntax-type": "#953800", "syntax-number": "#1b7c83", "syntax-property": "#0550ae", "syntax-label": "#8250df",
            "modeline-highlight": "#1f2328", "state-normal": "#0969da", "state-insert": "#1a7f37", "state-visual": "#bc4c00",
            "agenda-date": "#1f2328", "agenda-today": "#007aff", "agenda-time": "#6c6c70", "agenda-category": "#6c6c70",
            "agenda-overdue": "#d70015", "agenda-due-soon": "#c93400", "agenda-event": "#8944ab",
            "habit-clear": "#54aeff", "habit-ready": "#4ac26b", "habit-alert": "#d4a72c", "habit-overdue": "#ff8182",
        ]),
        dark: palette([
            "background": "#0d1117", "foreground": "#e6edf3", "cursor": "#58a6ff", "selection": "#388bfd66",
            "heading-1": "#79c0ff", "heading-2": "#d2a8ff", "heading-3": "#7ee787", "heading-4": "#ffa657",
            "heading-5": "#79c0ff", "heading-6": "#d2a8ff", "heading-7": "#7ee787", "heading-8": "#ffa657",
            "todo": "#ff6961", "done": "#30d158", "priority": "#ff9f0a", "tags": "#8b949e",
            "todo-next": "#409cff", "todo-waiting": "#ffd60a", "todo-cancelled": "#8e8e93",
            "priority-a": "#ff6961", "priority-b": "#ff9f0a", "priority-c": "#98a6b8",
            "link": "#58a6ff", "timestamp": "#d2a8ff", "code": "#ffa657", "verbatim": "#a5d6ff", "inline-background": "#6e768166",
            "markup": "#6e7681", "comment": "#8b949e", "keyword": "#8b949e", "metadata": "#8b949e", "special": "#56d4dd",
            "block-background": "#161b22", "block-delimiter": "#6e7681", "table": "#e6edf3",
            "line-number": "#6e7681", "line-number-current": "#e6edf3",
            "syntax-keyword": "#ff7b72", "syntax-string": "#a5d6ff", "syntax-comment": "#8b949e", "syntax-function": "#d2a8ff",
            "syntax-type": "#ffa657", "syntax-number": "#56d4dd", "syntax-property": "#79c0ff", "syntax-label": "#d2a8ff",
            "modeline-highlight": "#e6edf3", "state-normal": "#1f6feb", "state-insert": "#238636", "state-visual": "#9e6a03",
            "agenda-date": "#e6edf3", "agenda-today": "#0a84ff", "agenda-time": "#98989d", "agenda-category": "#98989d",
            "agenda-overdue": "#ff6961", "agenda-due-soon": "#ff9f0a", "agenda-event": "#da8fff",
            "habit-clear": "#1f6feb", "habit-ready": "#238636", "habit-alert": "#9e6a03", "habit-overdue": "#da3633",
        ])
    )

    // MARK: - Reading

    /// Keys of `[theme]` that aren't colors; config.toml's settings handle them.
    public static let typeKeys: Set<String> = ["font", "font-size", "line-spacing", "heading-size-step", "theme-file"]

    /// Whether a table holds theme colors.
    public static func isThemeTable(_ name: String) -> Bool {
        name == "theme" || name.hasPrefix("theme.")
    }

    /// `base` with the colors of `tables` laid over it, in order; problems for keys and
    /// values it can't use.
    public static func reading(_ tables: [TOML.Table], over base: ThemeSpec = .default, file: String = "config.toml") -> (ThemeSpec, [String]) {
        var spec = base
        var problems: [String] = []
        let known = Set(slots.map(\.key))
        for table in tables where isThemeTable(table.name) {
            for (key, value) in table.values.sorted(by: { $0.key < $1.key }) {
                if table.name == "theme", typeKeys.contains(key) { continue }
                guard let text = value.string, let color = RGBA(hex: text) else {
                    problems.append("\(file): \(table.name).\(key) must be a color such as \"#1f2328\"")
                    continue
                }
                switch table.name {
                case "theme.todo":
                    spec.todo[key] = color
                case "theme.category":
                    spec.category[key] = color
                case "theme", "theme.light", "theme.dark":
                    guard known.contains(key) else {
                        problems.append("\(file): unknown theme color \(key)")
                        continue
                    }
                    if table.name != "theme.dark" { spec.light[key] = color }
                    if table.name != "theme.light" { spec.dark[key] = color }
                default:
                    problems.append("\(file): unknown table [\(table.name)]")
                }
            }
        }
        return (spec, problems)
    }

    /// The default theme written out, to copy colors from.
    public static func defaultThemeFile() -> String {
        var out = """
            # Orgstar's default theme, for reference: Orgstar writes this file again each time it
            # starts, so change colors in config.toml. A key set under [theme] colors both
            # appearances; [theme.light] and [theme.dark] set one. Colors are "#rrggbb" or
            # "#rrggbbaa". [theme.todo] colors TODO keywords by name, as org-todo-keyword-faces:
            #
            #   [theme.todo]
            #   WAIT = "#bf8700"
            #
            # Otherwise a keyword takes its class's color: todo, todo-next, todo-waiting, done or
            # todo-cancelled. [theme.category] colors agenda categories by name the same way;
            # categories without one get a hue of their own from their name.
            #
            # A theme kept in its own file (with the same tables) is used with
            # `theme-file = "name.toml"` under [theme] in config.toml.

            """
        for (name, colors) in [("theme.light", ThemeSpec.default.light), ("theme.dark", ThemeSpec.default.dark)] {
            out += "\n[\(name)]\n"
            for slot in slots {
                guard let color = colors[slot.key] else {
                    let line = "# \(slot.key) = \"#rrggbb\""
                    out += line + String(repeating: " ", count: max(2, 36 - line.count)) + "# \(slot.description)\n"
                    continue
                }
                let line = "\(slot.key) = \"\(color.hex)\""
                out += line + String(repeating: " ", count: max(2, 36 - line.count)) + "# \(slot.description)\n"
            }
        }
        return out
    }
}

// MARK: - Agenda colors

extension ThemeSpec {
    /// The color classes of TODO keywords, by name: keywords of work under way and on hold,
    /// and done keywords that cancel; the others are `todo` or `done`.
    public enum TodoClass: String, Sendable {
        case todo, next, waiting, done, cancelled

        /// The theme key.
        public var key: String {
            switch self {
            case .todo: "todo"
            case .next: "todo-next"
            case .waiting: "todo-waiting"
            case .done: "done"
            case .cancelled: "todo-cancelled"
            }
        }

        static let nextWords: Set<String> = ["NEXT", "STRT", "STARTED", "START", "DOING", "ACTIVE", "INPROGRESS", "IN-PROGRESS"]
        static let waitingWords: Set<String> = ["WAIT", "WAITING", "HOLD", "ONHOLD", "BLOCKED", "DEFERRED", "SOMEDAY", "MAYBE"]
        static let cancelledWords: Set<String> = ["KILL", "KILLED", "CANCELLED", "CANCELED", "CANCEL", "SKIPPED", "SKIP", "ABORTED", "NO", "WONTFIX"]

        public static func of(_ keyword: String, isDone: Bool) -> TodoClass {
            let word = keyword.uppercased()
            if isDone { return cancelledWords.contains(word) ? .cancelled : .done }
            if nextWords.contains(word) { return .next }
            if waitingWords.contains(word) { return .waiting }
            return .todo
        }
    }

    /// `[theme.todo]`'s color for the keyword, else its class's.
    public func todoColor(_ keyword: String, isDone: Bool, dark isDark: Bool) -> RGBA? {
        todo[keyword] ?? color(TodoClass.of(keyword, isDone: isDone).key, dark: isDark)
    }

    /// `priority-a`, `-b`, `-c`; `priority` for the others.
    public func priorityColor(_ priority: String, dark isDark: Bool) -> RGBA? {
        let key = ["A": "priority-a", "B": "priority-b", "C": "priority-c"][priority] ?? "priority"
        return color(key, dark: isDark) ?? color("priority", dark: isDark)
    }

    /// The gutter's color: `agenda-overdue`, `agenda-due-soon`, `done`, else `agenda-time`.
    public func statusColor(_ status: AgendaRow.Status, dark isDark: Bool) -> RGBA? {
        switch status {
        case .overdue: color("agenda-overdue", dark: isDark)
        case .dueSoon: color("agenda-due-soon", dark: isDark)
        case .done: color("done", dark: isDark)
        case .normal: color("agenda-time", dark: isDark)
        }
    }

    /// An event's calendar color, else `agenda-event`.
    public func eventColor(_ event: AgendaEvent, dark isDark: Bool) -> RGBA? {
        event.color ?? color("agenda-event", dark: isDark)
    }

    /// `[theme.category]`'s color for the category, else its hue (`categoryHue`) at a
    /// saturation and lightness that read on the appearance's background.
    public func categoryColor(_ name: String, dark isDark: Bool) -> RGBA {
        if let set = category[name] { return set }
        let hue = Self.categoryHue(name)
        return isDark ? RGBA(hue: hue, saturation: 0.65, lightness: 0.70) : RGBA(hue: hue, saturation: 0.60, lightness: 0.40)
    }

    /// A hue in degrees from the category's name (FNV-1a of its UTF-8), the same on every run
    /// and device.
    public static func categoryHue(_ name: String) -> Double {
        var hash: UInt32 = 2166136261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return Double(hash % 360)
    }
}

extension RGBA {
    /// From HSL: hue in degrees, saturation and lightness 0 to 1.
    public init(hue: Double, saturation s: Double, lightness l: Double, alpha: Double = 1) {
        let c = (1 - abs(2 * l - 1)) * s
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }
}
