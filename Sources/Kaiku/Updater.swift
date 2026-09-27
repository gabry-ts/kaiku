import Sparkle

/// Wraps Sparkle's standard updater. Sparkle asks the user on the second launch whether to
/// check for updates automatically, and remembers the answer itself; we only expose a manual
/// "Check for Updates…" action and a Settings toggle for that same preference.
@MainActor
final class UpdaterManager {
    static let shared = UpdaterManager()

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
