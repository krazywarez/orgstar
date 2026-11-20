import Testing
@testable import OrgCore

struct EmacsFallbackWordingTests {
    /// The Developer ID and iOS apps keep pointing at Emacs; the App Store app doesn't.
    @Test func wording() {
        #expect(EmacsFallback.offered)
        #expect(EmacsFallback.wording("needs Emacs", "isn't supported") == "needs Emacs")
        #expect(EmacsFallback.wording("needs Emacs", "isn't supported", offered: false) == "isn't supported")
        #expect(TableRecalculate.emacsMessage == "needs Emacs: ")
    }
}
