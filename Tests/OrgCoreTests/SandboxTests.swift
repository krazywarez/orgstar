import Foundation
import Testing
@testable import OrgCore

struct SandboxTests {
    /// Tests run unsandboxed, so every switch keeps the Developer ID build's behaviour.
    @Test func inactiveInTests() {
        #expect(!Sandbox.isActive)
        #expect(Sandbox.bookmarkCreationOptions() == [])
        #expect(Sandbox.bookmarkResolutionOptions() == [])
    }

    @Test func detectedFromTheContainerVariable() {
        #expect(!Sandbox.isActive(environment: [:]))
        #if os(macOS)
        #expect(Sandbox.isActive(environment: ["APP_SANDBOX_CONTAINER_ID": "sh.krz.orgstar"]))
        #else
        #expect(!Sandbox.isActive(environment: ["APP_SANDBOX_CONTAINER_ID": "sh.krz.orgstar"]))
        #endif
    }

    @Test func bookmarksAreSecurityScopedInTheMacSandbox() {
        #if os(macOS)
        #expect(Sandbox.bookmarkCreationOptions(sandboxed: true) == .withSecurityScope)
        #expect(Sandbox.bookmarkResolutionOptions(sandboxed: true) == .withSecurityScope)
        #else
        #expect(Sandbox.bookmarkCreationOptions(sandboxed: true) == [])
        #expect(Sandbox.bookmarkResolutionOptions(sandboxed: true) == [])
        #endif
        #expect(Sandbox.bookmarkCreationOptions(sandboxed: false) == [])
        #expect(Sandbox.bookmarkResolutionOptions(sandboxed: false) == [])
    }
}
