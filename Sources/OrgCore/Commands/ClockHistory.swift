import Foundation

// Clock history and task selection (`org-clock-history`, `org-clock-history-push`,
// `org-clock-select-task`, Org 9.8.7). Org keeps markers, which follow edits; a task here is
// found again by its ID, else by its heading's position among the file's headings and its
// title, else by its title.

/// A clocked entry, as `org-clock-history` and `org-clock-default-task` remember it.
public struct ClockTask: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let title: String
    /// The heading's index among the file's headings.
    public let ordinal: Int
    public let id: String?

    public init(path: String, title: String, ordinal: Int, id: String?) {
        self.path = path
        self.title = title
        self.ordinal = ordinal
        self.id = id
    }

    /// The entry containing `offset`; nil before the first heading.
    public static func at(_ offset: Int, in text: String, path: String) -> ClockTask? {
        let model = DocumentModel(tree: OrgParser.parse(text))
        guard let index = model.headings.lastIndex(where: { $0.headingRange.lowerBound <= offset }) else { return nil }
        let heading = model.headings[index]
        return ClockTask(path: path, title: heading.title, ordinal: index, id: heading.id)
    }

    /// The heading's index in `model`, or nil when the entry is gone.
    public func index(in model: DocumentModel) -> Int? {
        if let id, let index = model.headings.firstIndex(where: { $0.id == id }) { return index }
        if ordinal < model.headings.count, model.headings[ordinal].title == title { return ordinal }
        return model.headings.firstIndex { $0.title == title }
    }

    /// Where the heading starts in `text`, or nil when the entry is gone.
    public func locate(in text: String) -> Int? {
        let model = DocumentModel(tree: OrgParser.parse(text))
        return index(in: model).map { model.headings[$0].headingRange.lowerBound }
    }

    /// The task as found in `text`, with its current position; nil when the entry is gone.
    public func refreshed(in text: String) -> ClockTask? {
        let model = DocumentModel(tree: OrgParser.parse(text))
        guard let index = index(in: model) else { return nil }
        return ClockTask(path: path, title: model.headings[index].title, ordinal: index, id: model.headings[index].id)
    }
}

public enum ClockHistory {
    /// `org-clock-history-length`.
    public static let defaultLength = 5

    /// `org-clock-history-push`: `task` goes first, other entries for the same heading and
    /// entries that are gone leave, and the oldest go past `length`. `text` reads a file.
    public static func push(_ task: ClockTask, onto history: [ClockTask], length: Int, text: (String) -> String?) -> [ClockTask] {
        let length = max(1, length)
        var texts: [String: String?] = [:]
        func read(_ path: String) -> String? {
            if let cached = texts[path] { return cached }
            let value = text(path)
            texts[path] = value
            return value
        }
        let target = read(task.path).flatMap { task.locate(in: $0) }
        var kept: [ClockTask] = []
        for entry in history {
            guard let contents = read(entry.path), let current = entry.refreshed(in: contents) else { continue }
            if entry.path == task.path, let target, current.locate(in: contents) == target { continue }
            kept.append(current)
        }
        if kept.count >= length { kept = Array(kept.prefix(length - 1)) }
        return [task] + kept
    }

    /// One line of the selection: its key, the section it is under and `[k] category  task`.
    public struct Choice: Equatable, Sendable {
        public let key: Character
        public let section: String
        public let task: ClockTask
        /// `%-12s  %s` of the category and the heading without tags.
        public let line: String
    }

    /// `org-clock-select-task`'s entries: the default task (`d`), the interrupted one (`i`),
    /// the clocking one (`c`), then recent tasks `1`–`9`, `A`… Nil when there is no recent
    /// clock. Entries that are gone are left out.
    public static func selection(
        defaultTask: ClockTask?, interrupted: ClockTask?, current: ClockTask?, history: [ClockTask], text: (String) -> String?
    ) -> [Choice]? {
        // Successive duplicates go.
        var recent: [ClockTask] = []
        for task in history where task != recent.last { recent.append(task) }
        guard !recent.isEmpty else { return nil }
        var choices: [Choice] = []
        func add(_ key: Character, _ section: String, _ task: ClockTask?) -> Bool {
            guard let task, let contents = text(task.path), let line = line(task, in: contents) else { return false }
            choices.append(Choice(key: key, section: section, task: task, line: line))
            return true
        }
        _ = add("d", "Default Task", defaultTask)
        _ = add("i", "The task interrupted by starting the last one", interrupted)
        _ = add("c", "Current Clocking Task", current)
        var i = 0
        for task in recent {
            guard let contents = text(task.path), line(task, in: contents) != nil else { continue }
            i += 1
            let scalar = i < 10 ? 48 + i : 65 + i - 10
            _ = add(Character(UnicodeScalar(UInt8(clamping: scalar))), "Recent Tasks", task)
        }
        return choices
    }

    /// The prompt's keys and lines, under their section titles.
    public static func fastSelection(_ choices: [Choice]) -> FastSelection {
        var items: [FastSelection.Item] = []
        var section: String?
        for choice in choices {
            if choice.section != section {
                section = choice.section
                items.append(.label(choice.section))
            }
            items.append(.option(key: choice.key, name: choice.line))
            items.append(.newline)
        }
        return FastSelection(items: items, multiple: false)
    }

    /// `org-clock-insert-selection-line`'s text for a task, nil when it is gone.
    public static func line(_ task: ClockTask, in text: String) -> String? {
        let model = DocumentModel(tree: OrgParser.parse(text))
        guard let index = task.index(in: model) else { return nil }
        let heading = model.headings[index]
        let category = category(of: index, in: model, text: text, path: task.path)
        let words = [heading.todo, heading.priority.map { "[#\($0)]" }, heading.title].compactMap { $0 }.filter { !$0.isEmpty }
        let padded = category.count >= 12 ? category : category + String(repeating: " ", count: 12 - category.count)
        return padded + "  " + words.joined(separator: " ")
    }

    /// `org-get-category`: the entry's or an ancestor's CATEGORY, `#+CATEGORY`, or the file
    /// name without its extension.
    static func category(of index: Int, in model: DocumentModel, text: String, path: String) -> String {
        for layer in [index] + model.ancestors(of: index).reversed() {
            if let value = model.headings[layer].properties.last(where: { $0.key.uppercased() == "CATEGORY" && !$0.additive })?.value {
                return value
            }
        }
        let keyword = text.components(separatedBy: "\n").last { $0.uppercased().hasPrefix("#+CATEGORY:") }
            .map { String($0.dropFirst("#+CATEGORY:".count)).trimmingCharacters(in: .whitespaces) }
        return keyword ?? model.property("CATEGORY", of: nil)?.value ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
