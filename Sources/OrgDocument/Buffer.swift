import Foundation

/// Where an open document's live state is kept: the editor while one shows it, a
/// `StateBuffer` before that.
@MainActor
public protocol DocumentBuffer: AnyObject {
    var document: DocumentState { get }
    /// Applies a change made outside typing (save, disk change, revert) and updates whatever
    /// shows the document.
    func update<T>(_ change: (inout DocumentState) throws -> T) rethrows -> T
}

@MainActor
public final class StateBuffer: DocumentBuffer {
    public private(set) var document: DocumentState

    public init(_ document: DocumentState) {
        self.document = document
    }

    public func update<T>(_ change: (inout DocumentState) throws -> T) rethrows -> T {
        try change(&document)
    }
}
