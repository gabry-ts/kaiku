import PartitiUI
import SwiftUI
import KaikuCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, popover, shortcuts, recording, sources, transcription, live, webhook, notifications, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .popover: return "Popover"
        case .shortcuts: return "Shortcuts"
        case .recording: return "Recording"
        case .sources: return "Sources"
        case .transcription: return "Transcription"
        case .live: return "Live"
        case .webhook: return "Webhook"
        case .notifications: return "Notifications"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .popover: return "menubar.rectangle"
        case .shortcuts: return "keyboard.fill"
        case .recording: return "mic.fill"
        case .sources: return "dot.radiowaves.left.and.right"
        case .transcription: return "text.quote"
        case .live: return "captions.bubble.fill"
        case .webhook: return "paperplane.fill"
        case .notifications: return "bell.badge.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .popover: return .orange
        case .shortcuts: return .indigo
        case .recording: return AppAccent.kaiku.color
        case .sources: return .teal
        case .transcription: return .blue
        case .live: return .pink
        case .webhook: return .purple
        case .notifications: return .red
        case .permissions: return .green
        case .about: return .teal
        }
    }

    /// The panes this Mac can show: Live only where an engine can run.
    static var available: [SettingsPane] { allCases.filter { $0 != .live || LiveTranscription.isSupported } }

    var sidebarItem: SidebarItem {
        SidebarItem(Text(title), id: rawValue, symbol: symbol, style: .tile(tint))
    }
}

/// Settings window: Partiti UI's floating sidebar with the panes, the selected pane on the right.
struct SettingsView: View {
    @State var pane: SettingsPane = .general

    private static let sections = [SidebarSection(nil, SettingsPane.available.map(\.sidebarItem))]

    var body: some View {
        SettingsWindow(sections: Self.sections, selection: selection) {
            switch pane {
            case .general: GeneralSettings()
            case .popover: PopoverSettings()
            case .shortcuts: ShortcutSettings()
            case .recording: RecordingSettings()
            case .sources: SourcesSettings()
            case .transcription: TranscriptionSettings()
            case .live: LiveSettings()
            case .webhook: WebhookSettings()
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
        Binding(get: { pane.rawValue }, set: { id in if let p = SettingsPane(rawValue: id) { pane = p } })
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(Keys.baseFolder) private var baseFolder = AppSettings.defaultBaseFolder.path
    @AppStorage(Keys.language) private var language = "auto"
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

            SettingsGroup("Language", footer: "Auto-detect handles most calls, including mixed languages. Choosing one can improve accuracy. You can also change it per call.") {
                LanguagePicker(language: $language, label: "Default for new calls")
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
        if panel.runModal() == .OK, let url = panel.url { baseFolder = url.path }
    }
}

// MARK: - Popover

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
        case .recent: return "Your latest calls, one click from the library."
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

struct PopoverSettings: View {
    @State private var items = AppSettings.popoverItems
    @AppStorage(Keys.popoverRecentCount) private var recentCount = PopoverLayout.defaultRecentCount

    var body: some View {
        KaikuPane(pane: .popover, subtitle: "What the menu bar popover shows, and in which order.") {
            ReorderableGroup("Sections", footer: "Drag to reorder. Switch off what you don't need.",
                             items: $items, isOn: \.isOn, isLocked: { $0.section.isLocked }) { item in
                ReorderableLabel(item.section.title, subtitle: item.section.detail, symbol: item.section.symbol)
            }

            SettingsGroup("Recent Calls", footer: "Problems, like a failed transcription or muted microphones, always show in the popover.") {
                SettingsRow("Calls to show") {
                    SegmentedPill(PopoverLayout.recentCounts.map { (value: $0, title: "\($0)") },
                                  selection: Binding(get: { PopoverLayout.recentCount(recentCount) }, set: { recentCount = $0 }))
                }
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
    @AppStorage(Keys.meLabel) private var meLabel = "Me"
    @AppStorage(Keys.othersLabel) private var othersLabel = "Others"
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
            : "Automatic uses \(resolved?.name ?? "the built-in microphone"). It never picks a Bluetooth headset, because that lowers call quality."
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
            CallDetectionSection()
            AutoStopSection()
            CalendarSection()

            SettingsGroup("Speaker Names", footer: "Providers that tell voices apart label people Speaker 1, Speaker 2… Rename them for each call in the library.") {
                SettingsRow("Your microphone") {
                    TextField("Your microphone", text: $meLabel, prompt: Text("Me"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                }
                SettingsRow("Call audio") {
                    TextField("Call audio", text: $othersLabel, prompt: Text("Others"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
        }
        .onAppear { devices = AudioDevices.inputs() }
        .onDisappear { monitor.stop() }
    }
}

// MARK: - Mute

struct MuteSection: View {
    @ObservedObject private var muter = MicMuter.shared

    var body: some View {
        SettingsGroup("Mute", footer: "Silences every microphone on this Mac, including the one your call app uses, while the app still shows you as unmuted. Option-click the menu bar icon to toggle it. Your previous settings come back when you unmute or quit. Tip: turn off \"Automatically adjust microphone volume\" in Zoom, so it doesn't fight the mute.") {
            SwitchRow("Mute all microphones", isOn: Binding(get: { muter.isMuted }, set: { $0 ? muter.mute() : muter.unmute() }))
            if !muter.unsupported.isEmpty {
                GroupRow { StatusDot(kind: .warning, text: "Can't be muted: \(muter.unsupported.joined(separator: ", "))") }
            }
        }
    }
}

// MARK: - Call detection

struct CallDetectionSection: View {
    @AppStorage(Keys.detectCalls) private var detect = true
    @AppStorage(Keys.detectAutoStart) private var autoStart = false
    @AppStorage(Keys.detectAutoStopSeconds) private var autoStop = 120
    @AppStorage(Keys.detectCallEndMode) private var callEnd = CallEndMode.standard.rawValue
    @AppStorage(NotificationKind.callEnded.showKey) private var callEndedShown = true
    @ObservedObject private var permissions = Permissions.shared

    private var mode: CallEndMode { CallEndMode(saved: callEnd) }
    private var behavior: CallEndBehavior {
        mode.behavior(notificationsAllowed: permissions.notificationsAllowed, callEndedNotificationEnabled: callEndedShown)
    }
    /// Ask every time was chosen, but the question can't be shown.
    private var fallsBack: Bool { mode == .ask && behavior != .ask }

    private var fallbackNote: String {
        let why = permissions.notificationsAllowed
            ? "The Call ended notification is switched off in Notifications"
            : "macOS doesn't allow notifications from Kaiku"
        let then = autoStop > 0
            ? "the recording stops after the delay below instead."
            : "the recording goes on until you stop it. Choose a delay below to have it stop by itself."
        return "\(why), so Kaiku can't ask: \(then)"
    }

    private var modeDetail: String {
        switch mode {
        case .stopAfterDelay: return "A notification lets you stop right away; otherwise the recording stops after the delay."
        case .ask: return "A notification asks whether to stop. The recording goes on until you answer."
        case .nothing: return "No notification. The recording goes on until you stop it."
        }
    }

    var body: some View {
        SettingsGroup("Call Detection", footer: "Kaiku watches which apps use a microphone, without opening any microphone itself. When Zoom, Teams, Meet and others start a call, you get a notification to record it. Choose which apps and websites can start a recording in Sources, and which notifications you get in Notifications.") {
            SwitchRow("Notice when a call starts", isOn: $detect)
            if detect {
                SwitchRow("Start recording automatically", isOn: $autoStart)
                SettingsRow(Text("When a call ends"), subtitle: Text(modeDetail)) {
                    Picker("When a call ends", selection: $callEnd) {
                        ForEach(CallEndMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if fallsBack {
                    GroupRow { StatusDot(kind: .warning, text: fallbackNote) }
                }
                if behavior == .stopAfterDelay {
                    SettingsRow("Stop automatically after the call ends") {
                        Picker("Stop automatically after the call ends", selection: $autoStop) {
                            Text("Never").tag(0)
                            Text("After 30 seconds").tag(30)
                            Text("After 1 minute").tag(60)
                            Text("After 2 minutes").tag(120)
                            Text("After 5 minutes").tag(300)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
        .onChange(of: detect) { _, _ in MeetingMonitor.shared.apply() }
        .onAppear { permissions.refreshNotifications() }
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

// MARK: - Calendar

struct CalendarSection: View {
    @AppStorage(Keys.calendarEnabled) private var enabled = true
    @ObservedObject private var permissions = Permissions.shared
    @State private var chosen: Set<String> = []
    @State private var calendars: [(id: String, title: String, account: String)] = []
    @State private var expanded = false

    var body: some View {
        SettingsGroup("Calendar", footer: "When a recording starts during an event (or up to 10 minutes before or after), its title is used and the attendees are suggested in Rename Speakers. Google and Outlook calendars must be added in System Settings > Internet Accounts.") {
            SwitchRow("Name recordings after calendar events", isOn: $enabled)
            if enabled {
                if permissions.calendar == .granted {
                    GroupRow {
                        DisclosureGroup("Calendars (\(chosen.isEmpty ? "all" : "\(chosen.count)"))", isExpanded: $expanded) {
                            VStack(alignment: .leading, spacing: PUI.Space.s) {
                                ForEach(calendars, id: \.id) { cal in
                                    Toggle(isOn: Binding(
                                        get: { chosen.isEmpty || chosen.contains(cal.id) },
                                        set: { on in
                                            var set = chosen.isEmpty ? Set(calendars.map(\.id)) : chosen
                                            if on { set.insert(cal.id) } else { set.remove(cal.id) }
                                            chosen = set.count == calendars.count ? [] : set
                                            AppSettings.defaults.set(Array(chosen).sorted(), forKey: Keys.calendarIDs)
                                        })) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(cal.title).font(PUI.Font.body)
                                            Text(cal.account).font(PUI.Font.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.top, PUI.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(PUI.Font.body)
                    }
                } else {
                    SettingsRow(Text(permissions.calendar == .denied ? "Calendar access denied" : "Needs calendar access")) {
                        Button(permissions.calendar == .notAsked ? "Allow…" : "Open Settings…") { permissions.requestCalendar() }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: permissions.calendar) { _, _ in load() }
    }

    private func load() {
        chosen = Set(AppSettings.calendarIDs)
        calendars = CalendarService.shared.calendars().map { ($0.calendarIdentifier, $0.title, $0.source.title) }
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
