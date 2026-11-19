import Foundation
import OrgCore

/// `denote-org-capture`: a capture template with `denote = true` first asks for a new note's
/// title and the questions `denote-prompts` lists, then files the entry in that note.
public struct DenoteCapture: Sendable {
    /// The questions, in order: `title`, then `keywords`, `subdirectory`, `date`, `template`
    /// and `signature` as `denote-prompts` orders them.
    public let questions: [Capture.Question]
    let steps: [String]
    let roots: [String]
    let folders: [(label: String, path: String)]
    let templates: [(key: String, text: String)]

    /// With `paths`, the files whose keywords are offered.
    public init(roots: [String], paths: [String], defaults: UserDefaults = .standard) {
        let folders = DenoteNote.directories(roots: roots, defaults: defaults)
        let choices = DenoteNote.folderChoices(folders)
        let templates = UserConfig.denoteTemplates(defaults)
        let keywords = Denote.keywords(paths.flatMap { Denote.name(ofFile: $0).keywords })
        var steps = ["title"], questions = [Capture.Question(prompt: "New file TITLE", defaultValue: "", choices: [])]
        for prompt in OrgPreferences.denotePrompts(defaults) where !steps.contains(prompt) {
            switch prompt {
            case "keywords": questions.append(Capture.Question(prompt: "New file KEYWORDS", defaultValue: "", choices: keywords))
            case "subdirectory" where choices.count > 1: questions.append(Capture.Question(prompt: "Select SUBDIRECTORY", defaultValue: ".", choices: choices.map(\.label)))
            case "date": questions.append(Capture.Question(prompt: "DATE and TIME for note", defaultValue: "", choices: [], kind: .date(withTime: true, inactive: false)))
            case "template" where !templates.isEmpty: questions.append(Capture.Question(prompt: "Select TEMPLATE key", defaultValue: templates[0].key, choices: templates.map(\.key)))
            case "signature": questions.append(Capture.Question(prompt: "New file SIGNATURE", defaultValue: "", choices: []))
            default: continue
            }
            steps.append(prompt)
        }
        self.steps = steps
        self.questions = questions
        self.roots = folders
        self.folders = choices
        self.templates = templates
    }

    /// Makes the note from the first `questions.count` answers and returns its path.
    public func create(_ answers: [String], now: Date = Date()) throws -> String {
        guard let root = roots.first else { throw Dailies.Failure("No folder for new notes") }
        var title = "", keywords: [String] = [], folder = root, date = now, template = "", signature = ""
        for (step, answer) in zip(steps, answers) {
            switch step {
            case "title": title = answer.trimmingCharacters(in: .whitespaces)
            case "keywords": keywords = answer.split(whereSeparator: { $0 == "," || $0 == ":" || $0.isWhitespace }).map(String.init)
            case "subdirectory": folder = folders.first { $0.label == answer }?.path ?? root
            case "date": date = answer.isEmpty ? now : RoamActions.date(answer, now: now) ?? now
            case "template": template = templates.first { $0.key == answer }?.text ?? ""
            default: signature = answer
            }
        }
        return try DenoteNote.create(title: title, keywords: keywords, in: folder, roots: roots, now: date, signature: signature, template: template).path
    }
}
