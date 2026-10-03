import PartitiUI
import SwiftUI
import KaikuCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, menuBar, recording, callDetection, transcription, dictation, ai, accounts, integrations, notifications, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar & Shortcuts"
        case .recording: return "Recording"
        case .callDetection: return "Call Detection"
        case .transcription: return "Transcription"
        case .dictation: return "Dictation"
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
        case .dictation: return "waveform.and.mic"
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
        case .dictation: return .pink
        case .ai: return .indigo
        case .accounts: return .yellow
        case .integrations: return .purple
        case .notifications: return .red
        case .permissions: return .green
        case .about: return .cyan
        }
    }

    /// The sidebar section the pane is listed in.
    enum Section: CaseIterable {
        case main, capture, intelligence, system

        var title: String? {
            switch self {
            case .main: return nil
            case .capture: return "Capture"
            case .intelligence: return "Intelligence"
            case .system: return "System"
            }
        }
    }

    var section: Section {
        switch self {
        case .general, .menuBar: return .main
        case .recording, .callDetection, .transcription, .dictation: return .capture
        case .ai, .accounts, .integrations: return .intelligence
        case .notifications, .permissions, .about: return .system
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(Keys.baseFolder) private var baseFolder = AppSettings.defaultBaseFolder.path
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    /// What was found in the folder just chosen, shown for a few seconds.
    @State private var folderResult: String?

    var body: some View {
        KaikuPane(pane: .general, subtitle: "Startup, where your calls are saved, and how the library reads.") {
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
            }
            .settingsAnchor("startup")

            SettingsGroup("Calls Folder", footer: "Each call gets its own folder with the audio, transcript and summary. Chats are saved in Chats inside it.") {
                SettingsRow(Text("Save calls in"),
                            subtitle: Text(AppSettings.displayBaseFolderOverride ?? (baseFolder as NSString).abbreviatingWithTildeInPath)) {
                    HStack(spacing: PUI.Space.s) {
                        Button("Show in Finder") { AppState.shared.openBaseFolder() }
                        Button("Choose…", action: chooseFolder)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
                .help(baseFolder)
                if let folderResult {
                    GroupRow { StatusDot(kind: .ok, text: folderResult) }
                }
            }
            .settingsAnchor("callsFolder")

            LibrarySection()
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
            let count = RecordingFolder.scan(base: url).count
            folderResult = count == 0 ? "No calls in this folder yet" : "Found \(count) call\(count == 1 ? "" : "s") in this folder"
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                folderResult = nil
            }
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

// MARK: - Library

/// How the library window searches the calls.
struct LibrarySection: View {
    @AppStorage(Keys.readingFullWidth) private var fullWidth = false
    @AppStorage(Keys.smartSearchUsed) private var smartSearch = false
    @ObservedObject private var semantic = AppState.shared.semantic

    private var status: String {
        guard smartSearch else { return "Off. New calls aren't indexed." }
        if semantic.unavailable { return "Not available on this Mac" }
        if let p = semantic.progress { return "\(min(p.done + 1, p.total)) of \(p.total) calls indexed…" }
        return "Up to date"
    }

    var body: some View {
        SettingsGroup("Library", footer: "Smart search finds passages by meaning, with a language model built into macOS. The index stays on this Mac.") {
            SwitchRow(Text("Smart search"), subtitle: Text(status), isOn: Binding(get: { smartSearch }, set: { on in
                if on { semantic.activate() } else { semantic.deactivate() }
            }))
            .settingsAnchor("smartSearch")
            SettingsRow(Text("Calls and chat"), subtitle: Text("A centered reading column, or the whole window width.")) {
                Picker("Calls and chat", selection: $fullWidth) {
                    Text("Centered").tag(false)
                    Text("Full width").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .settingsAnchor("readingWidth")
        }
        .settingsAnchor("library")
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
        SettingsGroup(Text("Storage"), footer: Text("Moves the audio of transcribed calls to the Trash. Transcripts, summaries and bookmarks stay.")) {
            SettingsRow("Space used") {
                if let usage {
                    ValueText("\(Storage.format(usage.total)) · \(usage.calls) calls · audio \(Storage.format(usage.audio))")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            SwitchRow("Delete old audio automatically", isOn: $autoCleanup)
            SettingsRow("Audio older than") {
                HStack(spacing: PUI.Space.s) {
                    ValueText("\(days) day\(days == 1 ? "" : "s")")
                    Stepper("Audio older than", value: $days, in: 1...365, step: days < 14 ? 1 : 7)
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
        .settingsAnchor("storage")
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
            ? "Only the call audio is recorded, so your voice won't be in the transcript."
            : microphone == AudioDevices.automatic && followCall ? "Follows the microphone your call uses. Without a call: \(resolved?.name ?? "the built-in microphone")."
            : microphone == AudioDevices.automatic ? "Uses \(resolved?.name ?? "the built-in microphone"), and a Bluetooth headset only when your call already does."
            : "Records from the microphone chosen above."
    }

    var body: some View {
        KaikuPane(pane: .recording, subtitle: "Your microphone, the call audio and muting.") {
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
                            StatusDot(kind: .warning, text: "A Bluetooth headset switches to call quality while recording.")
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
            .settingsAnchor("microphone")

            SettingsGroup("Call Audio", footer: "Captures what your Mac plays, without a bot in the call.") {
                SettingsRow("Call audio") {
                    HStack(spacing: PUI.Space.m) {
                        if systemAudioVerified {
                            StatusDot(kind: .ok, text: "Working")
                        } else {
                            StatusDot(kind: .neutral, text: "Checked on your first recording")
                            Button("Open Settings…") { Permissions.open(.systemAudio) }
                                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                                .help("If the other side is missing from transcripts, allow Kaiku under System Audio Recording.")
                        }
                    }
                }
                SwitchRow("Remove echo when using speakers", subtitle: "Hides your mic picking up the other people.", isOn: $removeEcho)
            }
            .settingsAnchor("callAudio")

            MuteSection()
                .settingsAnchor("mute")
            AutoStopSection()
                .settingsAnchor("forgotten")
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
    @State private var showTip = false

    var body: some View {
        SettingsGroup("Mute", footer: "Silences every microphone, including your call app's. Your settings come back when you unmute or quit.") {
            SwitchRow(Text("Mute all microphones"), subtitle: Text("Option-click the menu bar icon, or use your shortcut."),
                      isOn: Binding(get: { muter.isMuted }, set: { $0 ? muter.mute() : muter.unmute() }))
            SettingsRow("Mute by") {
                HStack(spacing: PUI.Space.s) {
                    SegmentedPill(MuteStyle.allCases.map { (value: $0.rawValue, title: $0.displayName) }, selection: $style)
                        .fixedSize()
                    Button { showTip.toggle() } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("About muting")
                        .popover(isPresented: $showTip, arrowEdge: .bottom) {
                            Text("Changes apply the next time you mute. In Zoom, turn off \"Automatically adjust microphone volume\" so it doesn't fight the mute.")
                                .font(PUI.Font.callout)
                                .frame(width: 260)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(PUI.Space.l)
                        }
                }
            }
            if style == MuteStyle.volume.rawValue {
                SettingsRow(Text("Volume while muted"), subtitle: Text("Teams drops a microphone that is fully silent; 1% keeps it.")) {
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
        case .volume: return "Volume down"
        }
    }
}

// MARK: - Automatic stop

/// Stops recordings left running by mistake, whether started by hand or by call detection.
struct AutoStopSection: View {
    @AppStorage(Keys.stopAfterSilenceSeconds) private var silence = 900
    @AppStorage(Keys.maxRecordingSeconds) private var maxLength = 14400

    var body: some View {
        SettingsGroup("Forgotten Recordings", footer: "Stops a recording left running. Pauses don't count as silence.") {
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
    @State private var reminders = RemindersService.shared.state

    var body: some View {
        KaikuPane(pane: .permissions, subtitle: "What Kaiku needs from macOS, and what each permission is for.") {
            SettingsGroup(footer: "Changes made in System Settings show up here when you come back.") {
                PermissionRow(
                    symbol: "mic.fill", tint: AppAccent.kaiku.color, title: "Microphone",
                    detail: "Records your side of the call.",
                    state: permissions.microphone,
                    action: permissions.microphone == .notAsked ? "Allow…" : "Open Settings…",
                    perform: { permissions.requestMicrophone() },
                    usedBy: ("Recording › Microphone", SettingsTarget(.recording, "microphone")))
                .settingsAnchor("microphone")
                PermissionRow(
                    symbol: "speaker.wave.2.fill", tint: .blue, title: "System Audio Recording",
                    detail: systemAudioVerified
                        ? "Captured call audio in a previous recording."
                        : "macOS asks the first time you record. It can't be checked in advance.",
                    state: systemAudioVerified ? .granted : .unknown,
                    action: "Open Settings…",
                    perform: { Permissions.open(.systemAudio) },
                    usedBy: ("Recording › Call Audio", SettingsTarget(.recording, "callAudio")))
                .settingsAnchor("systemAudio")
                PermissionRow(
                    symbol: "bell.badge.fill", tint: .red, title: "Notifications",
                    detail: "Tells you when a transcript is ready or a call starts.",
                    state: permissions.notifications,
                    action: permissions.notifications == .notAsked ? "Allow…" : "Open Settings…",
                    perform: { permissions.requestNotifications() },
                    usedBy: ("Notifications", SettingsTarget(.notifications)))
                .settingsAnchor("notifications")
                PermissionRow(
                    symbol: "calendar", tint: .red, title: "Calendar",
                    detail: "Optional. Names calls after the event happening now.",
                    state: permissions.calendar,
                    action: permissions.calendar == .notAsked ? "Allow…" : "Open Settings…",
                    perform: { permissions.requestCalendar() },
                    usedBy: ("Call Detection › Calendar", SettingsTarget(.callDetection, "calendar")))
                .settingsAnchor("calendar")
                PermissionRow(
                    symbol: "accessibility", tint: .purple, title: "Accessibility",
                    detail: "Optional. Reads the browser window title to tell web calls apart, like WhatsApp Web and Google Meet, and pastes dictations where the cursor is.",
                    state: permissions.accessibility,
                    action: permissions.accessibility == .notAsked ? "Allow…" : "Open Settings…",
                    perform: { permissions.requestAccessibility() },
                    usedBy: ("Call Detection › Sources", SettingsTarget(.callDetection, "sources")))
                .settingsAnchor("accessibility")
                PermissionRow(
                    symbol: "checklist", tint: .orange, title: "Reminders",
                    detail: "Optional. Adds the action items of a call to a Reminders list.",
                    state: reminders,
                    action: reminders == .notAsked ? "Allow…" : "Open Settings…",
                    perform: {
                        if reminders == .notAsked {
                            Task {
                                _ = await RemindersService.shared.requestAccess()
                                reminders = RemindersService.shared.state
                            }
                        } else {
                            RemindersService.openPrivacySettings()
                        }
                    },
                    usedBy: ("Integrations › Action Items", SettingsTarget(.integrations, "actionItems")))
                .settingsAnchor("reminders")
            }
        }
        .onAppear {
            permissions.refresh()
            reminders = RemindersService.shared.state
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            reminders = RemindersService.shared.state
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
    /// The setting that needs the permission, as a link to it.
    var usedBy: (title: String, target: SettingsTarget)?
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
                if let usedBy {
                    Button("Used by \(usedBy.title)") {
                        WindowManager.shared.showSettings(usedBy.target.pane, anchor: usedBy.target.anchor)
                    }
                    .buttonStyle(.link)
                    .font(PUI.Font.caption)
                }
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
                    .settingsAnchor("updates")

                SettingsGroup("Help") {
                    SettingsRow("Welcome guide") {
                        Button("Show Welcome Guide") { WindowManager.shared.showOnboarding() }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
                .frame(maxWidth: 420)
                .settingsAnchor("help")
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
