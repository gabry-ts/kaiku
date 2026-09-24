import AppKit
import AVFoundation
import Carbon.HIToolbox
import KaikuCore
import ServiceManagement
import UserNotifications

// MARK: - Global shortcuts

extension ShortcutAction {
    /// The preset setting this action used before shortcuts could be recorded.
    var legacyPresetKey: String? {
        switch self {
        case .record: return Keys.hotKey
        case .pause: return Keys.pauseHotKey
        case .bookmark: return Keys.bookmarkHotKey
        case .muteMicrophones, .openLibrary, .showPanel: return nil
        }
    }
}

/// User-assigned global shortcuts, stored as keyCode + modifiers.
enum Shortcuts {
    static func combo(for action: ShortcutAction) -> KeyCombo? {
        ShortcutRules.decode(AppSettings.defaults.object(forKey: action.settingsKey), default: action.defaultCombo)
    }

    /// nil stores "None".
    static func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        AppSettings.defaults.set(combo?.storage ?? [String: Int](), forKey: action.settingsKey)
    }

    static func reset(_ action: ShortcutAction) {
        AppSettings.defaults.removeObject(forKey: action.settingsKey)
    }

    static var assignments: [ShortcutAction: KeyCombo] {
        var out: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases { out[action] = combo(for: action) }
        return out
    }

    /// "⌃⌥⌘R", or "" when not assigned.
    static func display(_ action: ShortcutAction) -> String { combo(for: action)?.display ?? "" }

    /// Converts the previous preset choices once.
    static func migratePresets() {
        let defaults = AppSettings.defaults
        for action in ShortcutAction.allCases {
            guard let key = action.legacyPresetKey, defaults.object(forKey: action.settingsKey) == nil,
                  let preset = defaults.string(forKey: key),
                  let combo = ShortcutRules.legacyCombo(for: action, preset: preset) else { continue }
            set(combo, for: action)
            Log.app.info("Shortcut for \(action.rawValue, privacy: .public) migrated from preset \(preset, privacy: .public)")
        }
    }
}

/// Registers the global shortcuts with Carbon (no accessibility permission needed).
@MainActor
enum HotKeyManager {
    private static var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private static var handlerInstalled = false
    /// While a shortcut is being recorded nothing is registered.
    private static var suspended = false
    /// Actions whose shortcut could not be registered (taken by another app or the system).
    private(set) static var failed: Set<ShortcutAction> = []

    static func apply() {
        unregisterAll()
        guard !suspended else { return }
        installHandlerIfNeeded()
        for action in ShortcutAction.allCases {
            guard let combo = Shortcuts.combo(for: action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4B61_696B), id: action.hotKeyID) // "Kaik"
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.rawValue, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                failed.insert(action)
                Log.app.error("Could not register \(combo.display, privacy: .public) for \(action.rawValue, privacy: .public): \(status)")
            }
        }
    }

    static func suspend() {
        suspended = true
        unregisterAll()
    }

    static func resume() {
        suspended = false
        apply()
    }

    private static func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        failed = []
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch ShortcutAction(hotKeyID: id) {
                    case .record: AppState.shared.toggleRecording()
                    case .pause: AppState.shared.togglePause()
                    case .bookmark: AppState.shared.addBookmark()
                    case .muteMicrophones: MicMuter.shared.toggle()
                    case .openLibrary: WindowManager.shared.showLibrary()
                    case .showPanel: StatusBarController.shared.togglePanel()
                    case nil: break
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - Permissions

enum PermissionState: Equatable {
    case granted, denied, notAsked, unknown
}

@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var microphone: PermissionState = .unknown
    @Published private(set) var notifications: PermissionState = .unknown
    @Published private(set) var calendar: PermissionState = .unknown
    /// macOS has no API to query system audio recording permission. We know it
    /// works once a recording captured non-silent system audio.
    var systemAudioVerified: Bool { AppSettings.defaults.bool(forKey: Keys.systemAudioVerified) }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notAsked
        default: microphone = .denied
        }
        calendar = CalendarService.shared.state
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: PermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional: state = .granted
            case .notDetermined: state = .notAsked
            default: state = .denied
            }
            Task { @MainActor in Permissions.shared.notifications = state }
        }
        objectWillChange.send()
    }

    func requestMicrophone() {
        if microphone == .notAsked {
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in Permissions.shared.refresh() } }
        } else {
            Self.open(.microphone)
        }
    }

    func requestNotifications() {
        if notifications == .notAsked {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in Permissions.shared.refresh() }
            }
        } else {
            Self.open(.notifications)
        }
    }

    func requestCalendar() {
        if calendar == .notAsked {
            Task {
                _ = await CalendarService.shared.requestAccess()
                refresh()
            }
        } else {
            Self.open(.calendar)
        }
    }

    enum Pane { case microphone, systemAudio, notifications, calendar, loginItems }

    static func open(_ pane: Pane) {
        let url: String
        switch pane {
        case .microphone: url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .systemAudio: url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .notifications: url = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .calendar: url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .loginItems:
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
