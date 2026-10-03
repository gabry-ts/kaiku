import PartitiUI
import SwiftUI
import KaikuCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, menuBar, recording, callDetection, transcription, ai, accounts, integrations, notifications, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar & Shortcuts"
        case .recording: return "Recording"
        case .callDetection: return "Call Detection"
        case .transcription: return "Transcription"
        case .ai: return "AI"
        case .accounts: return "Accounts"
        case .integrations: return "Integrations"
        case .notifications: return "Notifications"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .menuBar: return "menubar.rectangle"
        case .recording: return "mic.fill"
        case .callDetection: return "phone.and.waveform.fill"
        case .transcription: return "text.quote"
        case .ai: return "sparkles"
        case .accounts: return "key.fill"
        case .integrations: return "point.3.connected.trianglepath.dotted"
        case .notifications: return "bell.badge.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .menuBar: return .orange
        case .recording: return AppAccent.kaiku.color
        case .callDetection: return .teal
        case .transcription: return .blue
        case .ai: return .indigo
        case .accounts: return .yellow
        case .integrations: return .purple
        case .notifications: return .red
        case .permissions: return .green
        case .about: return .teal
        }
    }

    static var available: [SettingsPane] { allCases }

    var sidebarItem: SidebarItem {
        SidebarItem(Text(title), id: rawValue, symbol: symbol, style: .tile(tint))
    }
}

/// Settings window: Partiti UI's floating sidebar with the panes, the selected pane on the right.
struct SettingsView: View {
    @ObservedObject private var nav = AppNavigation.shared

    private static let sections = [SidebarSection(nil, SettingsPane.available.map(\.sidebarItem))]

    var body: some View {
        SettingsWindow(sections: Self.sections, selection: selection) {
            switch nav.pane {
            case .general: GeneralSettings()
            case .menuBar: MenuBarSettings()
            case .recording: RecordingSettings()
            case .callDetection: CallDetectionSettings()
            case .transcription: TranscriptionSettings()
            case .ai: AISettings()
            case .accounts: AccountsSettings()
            case .integrations: IntegrationsSettings()
            case .notifications: NotificationSettings()
            case .permissions: PermissionsSettings()
            case .about: AboutSettings()
            }
        }
        .frame(minWidth: PUI.Window.settingsMin.width, minHeight: PUI.Window.settingsMin.height)
        .defaultAppStorage(AppSettings.defaults)
        .puiAccent(.kaiku)
    }

    /// The sidebar selects by the pane's raw value, the id of its item.
    private var selection: Binding<String> {
        Binding(get: { nav.pane.rawValue }, set: { id in if let p = SettingsPane(rawValue: id) { nav.open(p) } })
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(Keys.baseFolder) private var baseFolder = AppSettings.defaultBaseFolder.path
    @AppStorage(Keys.showInDock) private var showInDock = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        KaikuPane(pane: .general, subtitle: "Where calls are saved, their language, startup and storage.") {
            SettingsGroup("Recordings", footer: "Every call gets its own folder with the audio, transcript.md and meta.json.") {
                SettingsRow(Text("Save recordings in"),
                            subtitle: Text(AppSettings.displayBaseFolderOverride ?? (baseFolder as NSString).abbreviatingWithTildeInPath)) {
                    HStack(spacing: PUI.Space.s) {
                        Button("Show in Finder") { AppState.shared.openBaseFolder() }
                        Button("Choose…", action: chooseFolder)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
                .help(baseFolder)
            }

            SettingsGroup("Startup") {
                SwitchRow("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLogin))
                if LoginItem.needsApproval {
                    SettingsRow(Text("Needs approval in System Settings")) {
                        Button("Open Login Items…") { Permissions.open(.loginItems) }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
                if let loginError {
                    GroupRow { StatusDot(kind: .error, text: loginError) }
                }
                SwitchRow("Show in the Dock while Settings or the library is open", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in WindowManager.shared.updateDockPresence() }
            }

            StorageSection()
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginError = nil
        } catch {
            loginError = on ? "Couldn't enable: \(error.localizedDescription)" : error.localizedDescription
        }
        launchAtLogin = LoginItem.isEnabled
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: baseFolder)
        if panel.runModal() == .OK, let url = panel.url {
            baseFolder = url.path
            // Show the calls of the new folder, and recover any left unfinished there.
            AppState.shared.baseFolderChanged()
        }
    }
}

// MARK: - Menu bar panel

extension PopoverSection {
    var title: String {
        switch self {
        case .record: return "Record button"
        case .live: return "Live transcript"
        case .mute: return "Mute all microphones"
        case .status: return "Transcription status"
        case .recovered: return "Recovered calls"
        case .recent: return "Recent calls"
        }
    }

    var detail: String {
        switch self {
        case .record: return "Always shown, at the top."
        case .live: return "What is being said, while recording with live transcription on."
        case .mute: return "The switch that silences every microphone."
        case .status: return "Progress and result of the latest transcription."
        case .recovered: return "Calls saved after an interruption."
        case .recent: return "Your latest calls, one click from the window."
        }
    }

    var symbol: String {
        switch self {
        case .record: return "record.circle"
        case .live: return "captions.bubble"
        case .mute: return "mic.slash"
        case .status: return "waveform"
        case .recovered: return "arrow.uturn.backward.circle"
        case .recent: return "clock"
        }
    }
}

/// What the menu bar panel shows and in which order; the number of recent calls when they show.
struct PanelSettings: View {
    @State private var items = AppSettings.popoverItems
    @AppStorage(Keys.popoverRecentCount) private var recentCount = PopoverLayout.defaultRecentCount

    private var showsRecent: Bool { items.contains { $0.section == .recent && $0.isOn } }

    var body: some View {
        Group {
            ReorderableGroup("Panel", footer: "Drag to reorder. Problems, like a failed transcription, always show.",
                             items: $items, isOn: \.isOn, isLocked: { $0.section.isLocked }) { item in
                ReorderableLabel(item.section.title, subtitle: item.section.detail, symbol: item.section.symbol)
            }
            .settingsAnchor("panel")

            if showsRecent {
                SettingsGroup {
                    SettingsRow("Recent calls to show") {
                        SegmentedPill(PopoverLayout.recentCounts.map { (value: $0, title: "\($0)") },
                                      selection: Binding(get: { PopoverLayout.recentCount(recentCount) }, set: { recentCount = $0 }))
                    }
                }
                .settingsAnchor("recentCount")
            }
        }
        .onChange(of: items) { _, new in AppSettings.popoverItems = new }
    }
}

// MARK: - Storage

struct StorageSection: View {
    @AppStorage(Keys.autoCleanupEnabled) private var autoCleanup = false
    @AppStorage(Keys.autoCleanupDays) private var days = 30
    @State private var usage: (total: Int64, audio: Int64, calls: Int)?
    @State private var preview: [StorageCleanup.Candidate] = []
    @State private var confirming = false
    @State private var result: String?

    var body: some View {
        SettingsGroup(Text("Storage"), footer: Text("Audio of calls older than \(days) days goes to the Trash; transcripts, summaries and bookmarks stay. Calls that aren't transcribed yet keep their audio. Automatic cleanup runs at launch and once a day.")) {
            SettingsRow("Space used") {
                if let usage {
                    ValueText("\(Storage.format(usage.total)) · \(usage.calls) calls · audio \(Storage.format(usage.audio))")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            SwitchRow("Delete old audio automatically", isOn: $autoCleanup)
            SettingsRow("Keep audio for") {
                HStack(spacing: PUI.Space.s) {
                    ValueText("\(days) day\(days == 1 ? "" : "s")")
                    Stepper("Keep audio for", value: $days, in: 1...365, step: days < 14 ? 1 : 7)
                        .labelsHidden()
                }
            }
            GroupRow {
                HStack {
                    if let result { StatusDot(kind: .ok, text: result) }
                    Spacer(minLength: PUI.Space.m)
                    Button("Clean Up Now…") {
                        preview = AppState.shared.cleanupTargets(days: days)
                        result = nil
                        confirming = true
                    }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        }
        .task { await refresh() }
        .confirmationDialog(preview.isEmpty ? "Nothing to clean up" : "Move the audio of \(preview.count) call\(preview.count == 1 ? "" : "s") to the Trash?",
                            isPresented: $confirming) {
            if !preview.isEmpty {
                Button("Move \(Storage.format(preview.reduce(0) { $0 + $1.audioBytes })) to Trash", role: .destructive) {
                    let (count, bytes) = AppState.shared.cleanUpAudio(preview)
                    result = "Moved \(Storage.format(bytes)) from \(count) call\(count == 1 ? "" : "s") to the Trash"
                    Task { await refresh() }
                }
            }
        } message: {
            Text(preview.isEmpty
                 ? "No transcribed call older than \(days) days still has audio."
                 : "Frees about \(Storage.format(preview.reduce(0) { $0 + $1.audioBytes })). Transcripts are kept.")
        }
    }

    private func refresh() async {
        let base = AppSettings.baseFolder
        let value = await Task.detached { Storage.totalBytes(base: base) }.value
        usage = value
    }
}

// MARK: - Recording

struct RecordingSettings: View {
    @AppStorage(Keys.microphone) private var microphone = AudioDevices.automatic
    @AppStorage(Keys.followCallMicrophone) private var followCall = true
    @AppStorage(Keys.systemAudioVerified) private var systemAudioVerified = false
    @AppStorage(Keys.removeEcho) private var removeEcho = true
    @State private var devices: [AudioDevice] = []
    @StateObject private var monitor = MicLevelMonitor()

    private var recordMic: Binding<Bool> {
        Binding(get: { microphone != AudioDevices.none },
                set: { microphone = $0 ? AudioDevices.automatic : AudioDevices.none; monitor.stop() })
    }

    private var resolved: AudioDevice? { AudioDevices.resolveMicrophone(setting: microphone) }
    private var selectedIsBluetooth: Bool { devices.first { $0.uid == microphone }?.isBluetooth == true }

    private var microphoneFooter: String {
        microphone == AudioDevices.none
            ? "Only the call audio is recorded, so your own voice won't be in the transcript."
            : microphone == AudioDevices.automatic && followCall ? "Automatic records from the microphone your call uses, and switches when the call does. Without a call, it uses \(resolved?.name ?? "the built-in microphone"). Picking a microphone in the panel stops following for that recording."
            : "Automatic uses \(resolved?.name ?? "the built-in microphone"). It picks a Bluetooth headset only when your call already uses its microphone, since otherwise that lowers call quality."
    }

    var body: some View {
        KaikuPane(pane: .recording, subtitle: "Your microphone, the call audio, muting and call detection.") {
            SettingsGroup(Text("Microphone"), footer: Text(microphoneFooter)) {
                SwitchRow("Record my microphone", isOn: recordMic)
                if microphone != AudioDevices.none {
                    SettingsRow("Input device") {
                        Picker("Input device", selection: $microphone) {
                            Text("Automatic").tag(AudioDevices.automatic)
                            Divider()
                            ForEach(devices) { d in
                                Text(d.isBluetooth ? "\(d.name) (Bluetooth)" : d.name).tag(d.uid)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: microphone) { _, _ in monitor.stop() }
                    }
                    if microphone == AudioDevices.automatic {
                        SwitchRow("Use the same microphone as the call", isOn: $followCall)
                    }

                    if selectedIsBluetooth {
                        GroupRow {
                            StatusDot(kind: .warning, text: "Recording from a Bluetooth headset switches it to call mode. You and the other people will sound worse for the whole call.")
                        }
                    }

                    GroupRow {
                        HStack(spacing: PUI.Space.l) {
                            Button(monitor.running ? "Stop Test" : "Test Microphone") {
                                if monitor.running { monitor.stop() } else if let d = resolved { monitor.start(device: d) }
                            }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                            .disabled(resolved == nil)
                            Spacer(minLength: 0)
                            LevelMeter(level: monitor.level)
                                .opacity(monitor.running ? 1 : 0.4)
                        }
                    }
                    if let error = monitor.error {
                        GroupRow { StatusDot(kind: .error, text: error) }
                    }
                }
            }

            SettingsGroup("Call Audio", footer: "Everything your Mac plays is captured, without a bot joining the call, and recording continues if you switch between headphones and speakers. On speakers your mic also hears the other people: with echo removal, those repeated lines are hidden from your side of the transcript (they stay in segments.json).") {
                SettingsRow("Status") {
                    if systemAudioVerified {
                        StatusDot(kind: .ok, text: "Working")
                    } else {
                        StatusDot(kind: .neutral, text: "Checked on your first recording")
                    }
                }
                SettingsRow(Text("System Audio Recording"),
                            subtitle: Text("macOS asks for permission the first time you record. If the other side is missing from transcripts, allow Kaiku under System Audio Recording.")) {
                    Button("Open Settings…") { Permissions.open(.systemAudio) }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
                SwitchRow("Remove echo when using speakers", isOn: $removeEcho)
            }

            MuteSection()
            AutoStopSection()
        }
        .onAppear { devices = AudioDevices.inputs() }
        .onDisappear { monitor.stop() }
    }
}

// MARK: - Mute

struct MuteSection: View {
    @ObservedObject private var muter = MicMuter.shared
    @AppStorage(Keys.muteStyle) private var style = MuteStyle.volume.rawValue
    @AppStorage(Keys.muteVolumePercent) private var percent = 1

    var body: some View {
        SettingsGroup("Mute", footer: "Silences every microphone on this Mac, including the one your call app uses, while the app still shows you as unmuted. Option-click the menu bar icon to toggle it. Your previous settings come back when you unmute or quit. Teams can drop a microphone that is hardware-muted or fully silent: turning the volume down to 1% keeps it working. Changes apply the next time you mute. Tip: turn off \"Automatically adjust microphone volume\" in Zoom, so it doesn't fight the mute.") {
            SwitchRow("Mute all microphones", isOn: Binding(get: { muter.isMuted }, set: { $0 ? muter.mute() : muter.unmute() }))
            SettingsRow("Mute by") {
                Picker("Mute by", selection: $style) {
                    ForEach(MuteStyle.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if style == MuteStyle.volume.rawValue {
                SettingsRow("Volume while muted") {
                    HStack(spacing: PUI.Space.s) {
                        ValueText("\(percent)%")
                        Stepper("Volume while muted", value: $percent, in: 0...10).labelsHidden()
                    }
                }
            }
            if !muter.unsupported.isEmpty {
                GroupRow { StatusDot(kind: .warning, text: "Can't be muted: \(muter.unsupported.joined(separator: ", "))") }
            }
        }
    }
}

extension MuteStyle {
    var displayName: String {
        switch self {
        case .hardware: return "Mute switch"
        case .volume: return "Turning the volume down"
        }
    }
}

// MARK: - Automatic stop

/// Stops recordings left running by mistake, whether started by hand or by call detection.
struct AutoStopSection: View {
    @AppStorage(Keys.stopAfterSilenceSeconds) private var silence = 900
    @AppStorage(Keys.maxRecordingSeconds) private var maxLength = 14400

    var body: some View {
        SettingsGroup("Forgotten Recordings", footer: "Stops a recording that was left running, even when the call app keeps the microphone open after the call. Silence means no sound from your microphone or from the call. Pauses don't count.") {
            SettingsRow("Stop after a silence of") {
                Picker("Stop after a silence of", selection: $silence) {
                    Text("Never").tag(0)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                    Text("1 hour").tag(3600)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Stop recordings longer than") {
                Picker("Stop recordings longer than", selection: $maxLength) {
                    Text("Never").tag(0)
                    Text("2 hours").tag(7200)
                    Text("3 hours").tag(10800)
                    Text("4 hours").tag(14400)
                    Text("6 hours").tag(21600)
                    Text("8 hours").tag(28800)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(Keys.systemAudioVerified) private var systemAudioVerified = false

    var body: some View {
        KaikuPane(pane: .permissions, subtitle: "What Kaiku needs from macOS, and what each permission is for.") {
            SettingsGroup(footer: "Changes made in System Settings show up here when you come back.") {
                PermissionRow(
                    symbol: "mic.fill", tint: AppAccent.kaiku.color, title: "Microphone",
                    detail: "Records your side of the call.",
                    state: permissions.microphone,
                    action: permissions.microphone == .notAsked ? "Allow…" : "Open Settings…",
                    perform: { permissions.requestMicrophone() })
                PermissionRow(
                    symbol: "speaker.wave.2.fill", tint: .blue, title: "System Audio Recording",
                    detail: systemAudioVerified
                        ? "Captured call audio in a previous recording."
                        : "macOS asks the first time you record. It can't be checked in advance.",
                    state: systemAudioVerified ? .granted : .unknown,
                    action: "Open Settings…",
                    perform: { Permissions.open(.systemAudio) })
                PermissionRow(
                    symbol: "bell.badge.fill", tint: .red, title: "Notifications",
                    detail: "Tells you when a transcript is ready or a call starts.",
                    state: permissions.notifications,
                    action: permissions.notifications == .notAsked ? "Allow…" : "Open Settings…",
                    perform: { permissions.requestNotifications() })
                PermissionRow(
                    symbol: "calendar", tint: .red, title: "Calendar",
                    detail: "Optional. Names recordings after the event happening now.",
                    state: permissions.calendar,
                    action: permissions.calendar == .notAsked ? "Allow…" : "Open Settings…",
                    perform: { permissions.requestCalendar() })
                PermissionRow(
                    symbol: "accessibility", tint: .purple, title: "Accessibility",
                    detail: "Optional. Reads the browser window title to tell web calls apart, like WhatsApp Web and Google Meet.",
                    state: permissions.accessibility,
                    action: permissions.accessibility == .notAsked ? "Allow…" : "Open Settings…",
                    perform: { permissions.requestAccessibility() })
            }
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

/// One permission: tile, name with its state, what it's for, and the button that asks for it.
struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: PermissionState
    let action: String
    let perform: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        HStack(spacing: PUI.Space.m + 2) {
            IconTile(symbol, color: tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: PUI.Space.s) {
                    Text(title).font(PUI.Font.body).foregroundStyle(ink.primary)
                    badge(ink)
                }
                Text(detail).font(PUI.Font.caption).foregroundStyle(ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PUI.Space.l)
            if state != .granted {
                Button(action, action: perform)
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
            }
        }
        .padding(.horizontal, PUI.Space.l)
        .padding(.vertical, PUI.Space.m)
        .frame(minHeight: 44)
    }

    @ViewBuilder private func badge(_ ink: Ink) -> some View {
        Group {
            switch state {
            case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(ink.green).accessibilityLabel("Granted")
            case .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(ink.red).accessibilityLabel("Denied")
            case .notAsked: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ink.orange).accessibilityLabel("Not granted yet")
            case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(ink.tertiary).accessibilityLabel("Unknown")
            }
        }
        .font(.system(size: 12))
    }
}

// MARK: - About

struct AboutSettings: View {
    @State private var checksAutomatically = UpdaterManager.shared.automaticallyChecksForUpdates

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PUI.Space.xxl) {
                AboutPane(
                    brand: PartitiBrand(
                        accent: .kaiku,
                        tagline: "Record and transcribe your calls, without a meeting bot",
                        coffeeLine: "Kaiku is free. If it saves you some notes, you can buy me a coffee.",
                        icon: AppIconView.image),
                    version: version,
                    checksAutomatically: $checksAutomatically,
                    onCheckForUpdates: { UpdaterManager.shared.checkForUpdates() },
                    onBuyMeACoffee: { BuyMeACoffee.open() })

                SettingsGroup("Recordings") {
                    SettingsRow(Text("Recordings folder"), subtitle: Text(AppSettings.baseFolderDisplayPath)) {
                        Button("Open Recordings Folder") { AppState.shared.openBaseFolder() }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                    SettingsRow("Welcome guide") {
                        Button("Show Welcome Guide") { WindowManager.shared.showOnboarding() }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
                .frame(maxWidth: 420)
            }
            .padding(.top, 44)
            .padding(.horizontal, PUI.Space.xxl)
            .padding(.bottom, PUI.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: checksAutomatically) { _, v in UpdaterManager.shared.automaticallyChecksForUpdates = v }
    }
}
