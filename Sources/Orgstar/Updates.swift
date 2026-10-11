import Combine
import Sparkle
import SwiftUI

/// Sparkle, for the signed builds: the Info.plist names the appcast and the key the DMGs are
/// signed with. A dev build has neither, so the updater doesn't start and the menu item stays
/// disabled. Whether to check automatically is Sparkle's own setting, asked once on the
/// second launch.
@MainActor
@Observable
final class Updates {
    private(set) var canCheck = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?

    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] can in
            MainActor.assumeIsolated { self?.canCheck = can }
        }
    }

    func check() {
        controller?.updater.checkForUpdates()
    }

    var automatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

struct CheckForUpdatesItem: View {
    let updates: Updates

    var body: some View {
        Button("Check for Updates…") { updates.check() }
            .disabled(!updates.canCheck)
    }
}
