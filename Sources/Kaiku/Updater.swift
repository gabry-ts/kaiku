import Sparkle

/// Wraps Sparkle's standard updater. Sparkle asks the user on the second launch whether to
/// check for updates automatically, and remembers the answer itself; we only expose a manual
/// "Check for Updates…" action and a Settings toggle for that same preference.
@MainActor
final class UpdaterManager {
    static let shared = UpdaterManager()

    /// The offscreen render harness builds ordinary views, including the About pane,
    /// with sample data; starting Sparkle there would reach the network and could show
    /// its own permission alert, so it stays unstarted then.
    nonisolated private static var isRenderHarness: Bool {
        let args = CommandLine.arguments
        return args.contains("--render-snapshots") || args.contains("--render-icon")
    }

    private let controller = SPUStandardUpdaterController(startingUpdater: !UpdaterManager.isRenderHarness,
                                                          updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
