import Foundation
import OrgCore

/// Where an open document's live state is kept: the editor while one shows it, a
/// `StateBuffer` before that.
@MainActor
public protocol DocumentBuffer: AnyObject {
    var document: DocumentState { get }
    /// Selected ranges; the first holds the caret.
    var selection: [Range<Int>] { get }
    /// Runs a command at the selection as one undoable change.
    func perform(_ command: any OrgCommand, now: Date, answers: [String: String]) -> CommandStep
    /// Applies a change made outside typing (save, disk change, revert) and updates whatever
    /// shows the document.
    func update<T>(_ change: (inout DocumentState) throws -> T) rethrows -> T
}

@MainActor
public final class StateBuffer: DocumentBuffer {
    public private(set) var document: DocumentState
    public var selection: [Range<Int>] = [0..<0]
    public var options: EditingOptions = .org

    public init(_ document: DocumentState) {
        self.document = document
    }

    public func perform(_ command: any OrgCommand, now: Date, answers: [String: String]) -> CommandStep {
        do {
            let step = try document.run(command, selection: selection, now: now, answers: answers, options: options)
            if case .commit(let result) = step, let new = result.selection { selection = new }
            return step
        } catch {
            return .failed("\(error)")
        }
    }

    public func update<T>(_ change: (inout DocumentState) throws -> T) rethrows -> T {
        try change(&document)
    }
}
