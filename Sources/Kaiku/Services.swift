import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

// MARK: - Global hotkey

/// Preset global shortcuts for start/stop recording.
enum HotKeyPreset: String, CaseIterable, Identifiable {
    case off, ctrlOptCmdR, optCmdR, ctrlCmdR, ctrlOptCmdM

    var id: String { rawValue }

    var display: String {
        switch self {
        case .off: return "None"
        case .ctrlOptCmdR: return "⌃⌥⌘R"
        case .optCmdR: return "⌥⌘R"
        case .ctrlCmdR: return "⌃⌘R"
        case .ctrlOptCmdM: return "⌃⌥⌘M"
        }
    }

    fileprivate var carbon: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .off: return nil
        case .ctrlOptCmdR: return (UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey))
        case .optCmdR: return (UInt32(kVK_ANSI_R), UInt32(optionKey | cmdKey))
        case .ctrlCmdR: return (UInt32(kVK_ANSI_R), UInt32(controlKey | cmdKey))
        case .ctrlOptCmdM: return (UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey | cmdKey))
        }
    }

    static var current: HotKeyPreset {
        HotKeyPreset(rawValue: AppSettings.defaults.string(forKey: Keys.hotKey) ?? "") ?? .ctrlOptCmdR
    }
}

/// Modifier choices for the bookmark and pause shortcuts (the letter is fixed per action).
enum ModifierPreset: String, CaseIterable, Identifiable {
    case off, ctrlOptCmd, optCmd, ctrlCmd

    var id: String { rawValue }

    var symbols: String {
        switch self {
        case .off: return ""
        case .ctrlOptCmd: return "⌃⌥⌘"
        case .optCmd: return "⌥⌘"
        case .ctrlCmd: return "⌃⌘"
        }
    }

    fileprivate var carbon: UInt32? {
        switch self {
        case .off: return nil
        case .ctrlOptCmd: return UInt32(controlKey | optionKey | cmdKey)
        case .optCmd: return UInt32(optionKey | cmdKey)
        case .ctrlCmd: return UInt32(controlKey | cmdKey)
        }
    }
}

/// Global shortcuts besides start/stop.
enum HotKeyAction: UInt32, CaseIterable {
    case record = 1, bookmark = 2, pause = 3

    var letter: String { self == .bookmark ? "B" : "P" }
    fileprivate var keyCode: UInt32 { UInt32(self == .bookmark ? kVK_ANSI_B : kVK_ANSI_P) }
    var settingsKey: String { self == .bookmark ? Keys.bookmarkHotKey : Keys.pauseHotKey }

    var modifiers: ModifierPreset {
        ModifierPreset(rawValue: AppSettings.defaults.string(forKey: settingsKey) ?? "") ?? .ctrlOptCmd
    }

    /// "⌃⌥⌘B", or "" when off.
    var display: String {
        switch self {
        case .record: return HotKeyPreset.current == .off ? "" : HotKeyPreset.current.display
        default: return modifiers == .off ? "" : modifiers.symbols + letter
        }
    }

    func display(for preset: ModifierPreset) -> String { preset == .off ? "None" : preset.symbols + letter }

    fileprivate var combo: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .record: return HotKeyPreset.current.carbon
        default: return modifiers.carbon.map { (keyCode, $0) }
        }
    }
}

/// Registers the global hotkeys with Carbon (no accessibility permission needed).
@MainActor
enum HotKeyManager {
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var handlerInstalled = false

    static func apply() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        installHandlerIfNeeded()
        for action in HotKeyAction.allCases {
            guard let combo = action.combo else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4B61_696B), id: action.rawValue) // "Kaik"
            let status = RegisterEventHotKey(combo.key, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[action.rawValue] = ref }
            else { Log.app.error("Could not register hotkey \(action.rawValue): \(status)") }
        }
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
                    switch HotKeyAction(rawValue: id) {
                    case .bookmark: AppState.shared.addBookmark()
                    case .pause: AppState.shared.togglePause()
                    default: AppState.shared.toggleRecording()
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
