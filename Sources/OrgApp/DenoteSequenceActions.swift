import Foundation
import OrgCore

/// denote-sequence's commands, `app.node.sequence-…`: notes numbered in a hierarchy through
/// their signatures.
extension RoamActions {
    private var sequences: DenoteSequence { DenoteSequence(scheme: OrgPreferences.denoteSequenceScheme()) }

    /// The notes with a sequence, in `denote-directory` order.
    private func sequenceFiles() -> [(path: String, sequence: String)] {
        DenoteSequence.files(Denote.files(in: DenoteNote.directories(roots: roots())))
    }

    /// The open file's sequence.
    private var currentSequence: (path: String, sequence: String)? {
        guard let path = session.path, let signature = Denote.name(ofFile: path).signature, DenoteSequence.isSequence(signature) else { return nil }
        return (path, signature)
    }

    /// `denote-sequence-file-prompt`: one of `files` by its name.
    private func chooseSequenceFile(_ message: String, _ files: [(path: String, sequence: String)], _ then: @escaping ((path: String, sequence: String)) -> Void) {
        guard !files.isEmpty else { return show("There are no sequence notes in the denote-directory") }
        let labels = files.map { ($0.path as NSString).lastPathComponent }
        ask(Prompt(key: "sequence", message: message + ": ", choices: labels)) { answer in
            guard let answer, let index = labels.firstIndex(of: answer) else { return }
            then(files[index])
        }
    }

    /// The current file's sequence, or one asked for, as `denote-sequence--get-current-sequence-or-prompt`.
    private func currentOrChosen(_ message: String, _ then: @escaping (String) -> Void) {
        if let current = currentSequence { return then(current.sequence) }
        chooseSequenceFile(message, sequenceFiles()) { then($0.sequence) }
    }

    /// `denote` with `denote-use-signature`: asks for the title, then `denote-prompts`.
    private func newNote(_ sequence: () throws -> String) {
        let signature: String
        do { signature = try sequence() } catch { return show("\(error)") }
        ask(Prompt(key: "title", message: "New file TITLE: ", requireMatch: false)) { title in
            guard let title else { return }
            createDenote(title.trimmingCharacters(in: .whitespaces), known: nodes(), signature: signature) { choice in
                if case .created(let path, _, _) = choice { open(path, (session.text(of: path).map { ($0 as NSString).length }) ?? 0) }
            }
        }
    }

    /// `denote-rename-file` keeping all but the signature: the file renamed with `sequence`
    /// and its front matter's `#+signature:` set.
    @discardableResult
    private func renameSequence(_ path: String, to sequence: String, reopen: Bool) -> String? {
        guard let text = session.text(of: path) ?? (try? String(contentsOfFile: path, encoding: .utf8)) else { show("Can't read \((path as NSString).lastPathComponent)"); return nil }
        let name = Denote.name(ofFile: path), front = Denote.frontMatter(of: text)
        let (target, rewritten) = DenoteNote.renaming(path, text: text, title: front.title ?? name.title?.replacingOccurrences(of: "-", with: " ") ?? "",
                                                      keywords: front.keywords ?? name.keywords, signature: sequence, date: nil, roots: DenoteNote.directories(roots: roots()))
        if rewritten != text {
            if session.openPaths.contains(path) {
                if case .failed(let message) = session.perform(ReplaceText(old: text, new: rewritten), path: path, at: 0, expect: nil) { show(message); return nil }
            } else {
                do { try rewritten.write(toFile: path, atomically: true, encoding: .utf8) } catch { show("Can't write: \(error)"); return nil }
            }
        }
        guard target != path else { return path }
        guard !FileManager.default.fileExists(atPath: target) else { show("\((target as NSString).lastPathComponent) is already there"); return nil }
        do {
            try move(path, to: target)
            if reopen { open(target, 0) }
            return target
        } catch {
            show("Can't rename: \(error)")
            return nil
        }
    }

    /// `denote-sequence-find-next-sibling` and `-previous-sibling`: the nearest sibling that
    /// exists in that direction.
    private func findSibling(of sequence: String, next: Bool, among relatives: [(path: String, sequence: String)]) {
        let model = sequences
        guard let inLine = try? model.neighbor(of: sequence, next: next) else {
            return show("No `\(next ? "next" : "previous")' sibling for sequence `\(sequence)'")
        }
        if !relatives.isEmpty, let path = DenoteSequence.path(of: inLine, in: relatives) { return open(path, 0) }
        // `denote-sequence--keep-sibling-files`: those past where the missing one would sort.
        let phony = "\u{0}"
        let all = relatives + [(phony, inLine)]
        let sorted = all.indices.sorted {
            let a = model.sortKey(all[$0].sequence), b = model.sortKey(all[$1].sequence)
            return a == b ? $0 < $1 : a < b
        }.map { all[$0] }
        guard let position = sorted.firstIndex(where: { $0.path == phony }) else { return }
        let remaining = Array(next ? sorted[(position + 1)...] : sorted[..<position])
        guard !remaining.isEmpty else { return show("No `\(next ? "next" : "previous")' sibling for sequence `\(sequence)'") }
        findSibling(of: inLine, next: next, among: remaining)
    }

    func runSequence(_ command: String) {
        let model = sequences
        let files = sequenceFiles()
        let all = files.map(\.sequence)
        switch command {
        case "new-parent":
            newNote { try model.newParent(among: all) }
        case "new-child", "new-sibling":
            chooseSequenceFile("Make a new \(command == "new-child" ? "child" : "sibling") of SEQUENCE", files) { file in
                newNote { command == "new-child" ? try model.newChild(of: file.sequence, among: all) : try model.newSibling(of: file.sequence, among: all) }
            }
        case "new-child-of-current", "new-sibling-of-current":
            let child = command == "new-child-of-current"
            currentOrChosen("Make a new \(child ? "child" : "sibling") of SEQUENCE") { sequence in
                newNote { child ? try model.newChild(of: sequence, among: all) : try model.newSibling(of: sequence, among: all) }
            }
        case "find":
            guard let current = currentSequence else { return show("The current file has no sequence") }
            let relations = DenoteSequence.Relation.allCases
            ask(Prompt(key: "relation", message: "Find relatives of TYPE: ", choices: relations.map(\.rawValue))) { answer in
                guard let answer, let relation = DenoteSequence.Relation(rawValue: answer) else { return }
                let found = ((try? model.relatives(of: current.sequence, relation, in: files)) ?? [])
                guard !found.isEmpty else { return show("The sequence `\(current.sequence)' has no relatives of type `\(answer)'") }
                if relation == .parent { return open(found[0], 0) }
                chooseSequenceFile("Select a relative", files.filter { found.contains($0.path) }) { open($0.path, 0) }
            }
        case "next-sibling", "previous-sibling":
            currentOrChosen("Find the \(command == "next-sibling" ? "next" : "previous") sibling of SEQUENCE") { sequence in
                let siblings = ((try? model.relatives(of: sequence, .siblings, in: files)) ?? [])
                findSibling(of: sequence, next: command == "next-sibling", among: files.filter { siblings.contains($0.path) })
            }
        case "reparent", "reparent-recursive":
            guard let path = session.path else { return show("No file is open") }
            let file = (path as NSString).lastPathComponent
            chooseSequenceFile("Reparent `\(file)'\(command == "reparent" ? "" : " (recursively)") to be a child of", files) { target in
                let root = currentSequence?.sequence
                let newSequence: String
                do { newSequence = try model.newChild(of: target.sequence, among: all) } catch { return show("\(error)") }
                let descendants = command == "reparent-recursive" ? root.flatMap { try? model.relatives(of: $0, .allChildren, in: files) } ?? [] : []
                guard renameSequence(path, to: newSequence, reopen: true) != nil else { return }
                for child in descendants {
                    guard let root, let sequence = Denote.name(ofFile: child).signature else { continue }
                    let suffix = sequence.hasPrefix(root) ? String(sequence.dropFirst(root.count)) : sequence
                    renameSequence(child, to: newSequence + suffix, reopen: false)
                }
                refresh()
                show("Renamed to \(Denote.signature(newSequence))")
            }
        case "rename-as-parent":
            guard let path = session.path else { return show("No file is open") }
            guard currentSequence == nil else { return show("The `\((path as NSString).lastPathComponent)' already has a sequence; aborting") }
            do {
                if renameSequence(path, to: try model.newParent(among: all), reopen: true) != nil { refresh() }
            } catch {
                show("\(error)")
            }
        case "convert":
            guard let current = currentSequence else { return show("The current file has no sequence") }
            guard let converted = try? model.converted(current.sequence, to: model.scheme), converted != current.sequence else {
                return show("The sequence already is \(model.scheme.rawValue)")
            }
            if renameSequence(current.path, to: converted, reopen: true) != nil { refresh() }
        case "link":
            chooseSequenceFile("Link to file with sequence", files) { file in
                guard let id = Denote.identifier(ofFile: file.path) else { return }
                let text = (try? String(contentsOfFile: file.path, encoding: .utf8)) ?? ""
                let title = Denote.frontMatter(of: text).title ?? Denote.name(ofFile: file.path).title ?? ""
                insertLink("denote:" + id, title.isEmpty ? file.sequence : file.sequence + "  " + title)
            }
        case "hierarchy":
            // `denote-sequence-view-hierarchy` as a list: each note under its parent.
            let ordered = model.sorted(all).compactMap { sequence in files.first { $0.sequence == sequence } }
            guard !ordered.isEmpty else { return show("There are no sequence notes in the denote-directory") }
            let labels = ordered.map { file -> String in
                let depth = (try? model.depth(file.sequence)) ?? 1
                let text = (try? String(contentsOfFile: file.path, encoding: .utf8)) ?? ""
                let title = Denote.frontMatter(of: text).title ?? Denote.name(ofFile: file.path).title ?? ""
                let keywords = Denote.name(ofFile: file.path).keywords.joined(separator: "_")
                return String(repeating: "  ", count: depth - 1) + file.sequence + (title.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " " + title)
                    + (keywords.isEmpty ? "" : " _" + keywords)
            }
            ask(Prompt(key: "sequence", message: "Sequence hierarchy: ", choices: labels)) { answer in
                guard let answer, let index = labels.firstIndex(of: answer) else { return }
                open(ordered[index].path, 0)
            }
        default:
            show("Unknown command app.node.sequence-\(command)")
        }
    }
}
