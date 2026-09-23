import AppKit
import SwiftUI

@main
struct McRofoneApp: App {
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
        if args.contains("--selftest-recovery") {
            exit(SelfTest.runRecovery())
        }
        if let i = args.firstIndex(of: "--selftest-write-caf"), args.indices.contains(i + 2) {
            exit(SelfTest.writeCAFForever(mic: URL(fileURLWithPath: args[i + 1]), system: URL(fileURLWithPath: args[i + 2])))
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.setUp()
        try? FileManager.default.createDirectory(at: AppSettings.baseFolder, withIntermediateDirectories: true)
        MainActor.assumeIsolated {
            MicMuter.shared.restoreAfterCrash()
            MicMuter.shared.onChange = { muted in AppState.shared.microphonesMuted(muted) }
            StatusBarController.shared.install()
            HotKeyManager.apply()
            Permissions.shared.refresh()
            AppState.shared.recoverOnLaunch()
            AppState.shared.startAutoCleanup()
            MeetingMonitor.shared.apply()
            if !AppSettings.defaults.bool(forKey: Keys.onboardingDone) {
                WindowManager.shared.showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.finalizeOnQuit()
            MicMuter.shared.unmute()
        }
    }
}
