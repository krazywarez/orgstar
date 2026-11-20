import Foundation

/// Whether messages may send the user to Emacs for what orgstar can't do itself. The Mac App
/// Store build, which can't run Emacs, turns it off at launch.
public enum EmacsFallback {
    nonisolated(unsafe) public static var offered = true

    /// `emacs` while Emacs is offered, else `other`.
    public static func wording(_ emacs: String, _ other: String, offered: Bool = offered) -> String {
        offered ? emacs : other
    }
}
