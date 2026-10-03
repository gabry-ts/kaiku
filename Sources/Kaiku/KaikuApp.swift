import AppKit
import KaikuCore
import SwiftUI

@main
struct KaikuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-audio") {
            let seconds = args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 3 : 3
            exit(SelfTest.runAudio(seconds: seconds))
        }
        if args.contains("--selftest-detect") {
            exit(SelfTest.runDetect())
        }
        if args.contains("--selftest-mute") {
            exit(MainActor.assumeIsolated { SelfTest.runMute(force: args.contains("--force")) })
        }
        if args.contains("--selftest-devicechange") {
            exit(SelfTest.runDeviceChange())
        }
        if args.contains("--selftest-trim") {
            exit(SelfTest.runTrim())
        }
        if args.contains("--selftest-partial") {
            exit(SelfTest.runPartial())
        }
        if args.contains("--selftest-retry") {
            exit(SelfTest.runRetry())
        }
        if args.contains("--selftest-audiotools") {
            exit(SelfTest.runAudioTools())
        }
        if args.contains("--selftest-migration") {
            exit(SelfTest.runMigration())
        }
        if args.contains("--selftest-recovery") {
            exit(SelfTest.runRecovery())
        }
        if let i = args.firstIndex(of: "--selftest-write-caf"), args.indices.contains(i + 2) {
            exit(SelfTest.writeCAFForever(mic: URL(fileURLWithPath: args[i + 1]), system: URL(fileURLWithPath: args[i + 2])))
        }
        if let i = args.firstIndex(of: "--live-selftest"), args.indices.contains(i + 1) {
            let language = args.indices.contains(i + 2) && !args[i + 2].hasPrefix("--") ? args[i + 2] : "auto"
            let engine = args.firstIndex(of: "--engine").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            exit(SelfTest.runLive(file: URL(fileURLWithPath: args[i + 1]), language: language, engine: engine,
                                  download: args.contains("--download")))
        }
        if let i = args.firstIndex(of: "--transcribe-selftest"), args.indices.contains(i + 1) {
            let language = args.indices.contains(i + 2) && !args[i + 2].hasPrefix("--") ? args[i + 2] : "auto"
            let provider = args.firstIndex(of: "--provider").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            exit(SelfTest.runTranscribe(file: URL(fileURLWithPath: args[i + 1]), language: language, provider: provider,
                                        download: args.contains("--download")))
        }
        if let i = args.firstIndex(of: "--render-snapshots"), args.indices.contains(i + 1) {
            exit(MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: args[i + 1])) })
        }
        if let i = args.firstIndex(of: "--render-icon"), args.indices.contains(i + 1) {
            exit(MainActor.assumeIsolated { Snapshots.renderIconSet(to: URL(fileURLWithPath: args[i + 1])) })
        }
    }

    var body: some Scene {
        // The menu bar item is an NSStatusItem (StatusBarController), so Option-click can
        // mute the microphones; SwiftUI still needs one scene.
        Settings { EmptyView() }
            .commands {
                // Cmd+, would otherwise open this empty scene instead of Settings in the main window.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { WindowManager.shared.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                // Cmd+Q closes the key window instead of quitting, so the app stays in the menu
                // bar. Quit stays in the panel footer; the system, Sparkle and Apple Events
                // still terminate through NSApp.terminate.
                CommandGroup(replacing: .appTermination) {
                    Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Migration.runAtLaunch()
        Shortcuts.migratePresets()
        AppSettings.registerDefaults()
        Migration.migrateSourceRules()
        Migration.migrateAutoRecordMode()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.setUp()
        try? FileManager.default.createDirectory(at: AppSettings.baseFolder, withIntermediateDirectories: true)
        MainActor.assumeIsolated {
            _ = UpdaterManager.shared
            MicMuter.shared.restoreAfterCrash()
            MicMuter.shared.onChange = { muted in AppState.shared.microphonesMuted(muted) }
            StatusBarController.shared.install()
            HotKeyManager.apply()
            Permissions.shared.refresh()
            AppState.shared.recoverOnLaunch()
            AppState.shared.startAutoCleanup()
            MeetingMonitor.shared.apply()
            SpotlightIndexer.shared.start()
            // kaiku-mcp changed calls on disk.
            _ = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(KaikuAgents.libraryChangedNotification), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppState.shared.reloadLibrary() }
            }
            if !AppSettings.defaults.bool(forKey: Keys.onboardingDone) {
                WindowManager.shared.showOnboarding()
            } else if !AppSettings.defaults.bool(forKey: Keys.accessibilityAsked) && !Permissions.shared.accessibilityGranted {
                WindowManager.shared.showOnboarding(accessibilityOnly: true)
            }
        }
    }

    /// kaiku:// URLs opened by kaiku-mcp for agents.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppState.shared.handleAgentURL(url) }
        }
    }

    /// A Spotlight result for a call was opened.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard let folder = SpotlightIndexer.folder(for: userActivity) else { return false }
        MainActor.assumeIsolated { AppState.shared.openInLibrary(folder) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.finalizeOnQuit()
            MicMuter.shared.unmute()
        }
    }
}
