import SwiftUI
import KaikuCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, recording, transcription, webhook, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .transcription: return "Transcription"
        case .webhook: return "Webhook"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "mic"
        case .transcription: return "text.quote"
        case .webhook: return "paperplane"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .recording: return Brand.accent
        case .transcription: return .blue
        case .webhook: return .purple
        case .permissions: return .green
        case .about: return .secondary
        }
    }
}

/// Settings window: sidebar with panes, grouped forms on the right.
struct SettingsView: View {
    @State var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { p in
                Label {
                    Text(p.title)
                } icon: {
                    Image(systemName: p.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(p.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .tag(p)
            }
            .frame(minWidth: 220)
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .recording: RecordingSettings()
                case .transcription: TranscriptionSettings()
                case .webhook: WebhookSettings()
                case .permissions: PermissionsSettings()
                case .about: AboutSettings()
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 780, height: 600)
        .defaultAppStorage(AppSettings.defaults)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(Keys.baseFolder) private var baseFolder = AppSettings.defaultBaseFolder.path
    @AppStorage(Keys.language) private var language = "auto"
    @AppStorage(Keys.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(Keys.hotKey) private var hotKey = HotKeyPreset.ctrlOptCmdR.rawValue
    @AppStorage(Keys.bookmarkHotKey) private var bookmarkHotKey = ModifierPreset.ctrlOptCmd.rawValue
    @AppStorage(Keys.pauseHotKey) private var pauseHotKey = ModifierPreset.ctrlOptCmd.rawValue
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Save recordings in") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(AppSettings.displayBaseFolderOverride ?? (baseFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .help(baseFolder)
                    }
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { AppState.shared.openBaseFolder() }
                    Button("Choose…", action: chooseFolder)
                }
            } footer: {
                Text("Every call gets its own folder with the audio, transcript.md and meta.json.")
            }

            Section {
                Picker("Start or stop recording", selection: $hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.display).tag($0.rawValue) }
                }
                .onChange(of: hotKey) { _, _ in HotKeyManager.apply() }
                Picker("Pause or resume", selection: $pauseHotKey) {
                    ForEach(ModifierPreset.allCases) { Text(HotKeyAction.pause.display(for: $0)).tag($0.rawValue) }
                }
                .onChange(of: pauseHotKey) { _, _ in HotKeyManager.apply() }
                Picker("Add bookmark", selection: $bookmarkHotKey) {
                    ForEach(ModifierPreset.allCases) { Text(HotKeyAction.bookmark.display(for: $0)).tag($0.rawValue) }
                }
                .onChange(of: bookmarkHotKey) { _, _ in HotKeyManager.apply() }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Work from any app, even when Kaiku is in the background. A bookmark is added instantly; you can label it in the panel or later in the library.")
            }

            Section {
                LanguagePicker(language: $language, label: "Default for new calls")
            } header: {
                Text("Language")
            } footer: {
                Text("Auto-detect handles most calls, including mixed languages. Choosing one can improve accuracy. You can also change it per call.")
            }

            Section("Startup & Notifications") {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLogin))
                if LoginItem.needsApproval {
                    HStack {
                        StatusDot(kind: .warning, text: "Needs approval in System Settings")
                        Spacer()
                        Button("Open Login Items…") { Permissions.open(.loginItems) }
                    }
                }
                if let loginError {
                    StatusDot(kind: .error, text: loginError)
                }
                Toggle("Notify me when a transcript is ready", isOn: $notificationsEnabled)
            }

            StorageSection()
        }
        .formStyle(.grouped)
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

// MARK: - Storage

struct StorageSection: View {
    @AppStorage(Keys.autoCleanupEnabled) private var autoCleanup = false
    @AppStorage(Keys.autoCleanupDays) private var days = 30
    @State private var usage: (total: Int64, audio: Int64, calls: Int)?
    @State private var preview: [StorageCleanup.Candidate] = []
    @State private var confirming = false
    @State private var result: String?

    var body: some View {
        Section {
            LabeledContent("Space used") {
                if let usage {
                    Text("\(Storage.format(usage.total)) · \(usage.calls) calls · audio \(Storage.format(usage.audio))")
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Toggle("Delete old audio automatically", isOn: $autoCleanup)
            Stepper(value: $days, in: 1...365, step: days < 14 ? 1 : 7) {
                LabeledContent("Keep audio for", value: "\(days) day\(days == 1 ? "" : "s")")
            }
            HStack {
                if let result { StatusDot(kind: .ok, text: result) }
                Spacer()
                Button("Clean Up Now…") {
                    preview = AppState.shared.cleanupTargets(days: days)
                    result = nil
                    confirming = true
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Audio of calls older than \(days) days goes to the Trash; transcripts, summaries and bookmarks stay. Calls that aren't transcribed yet keep their audio. Automatic cleanup runs at launch and once a day.")
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

    var body: some View {
        Form {
            Section {
                Toggle("Record my microphone", isOn: recordMic)
                if microphone != AudioDevices.none {
                    Picker("Input device", selection: $microphone) {
                        Text("Automatic").tag(AudioDevices.automatic)
                        Divider()
                        ForEach(devices) { d in
                            Text(d.isBluetooth ? "\(d.name) (Bluetooth)" : d.name).tag(d.uid)
                        }
                    }
                    .onChange(of: microphone) { _, _ in monitor.stop() }

                    if selectedIsBluetooth {
                        Label {
                            Text("Recording from a Bluetooth headset switches it to call mode. You and the other people will sound worse for the whole call.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.callout)
                    }

                    HStack(spacing: 12) {
                        Button(monitor.running ? "Stop Test" : "Test Microphone") {
                            if monitor.running { monitor.stop() } else if let d = resolved { monitor.start(device: d) }
                        }
                        .disabled(resolved == nil)
                        LevelMeter(level: monitor.level, tint: Brand.accent)
                            .opacity(monitor.running ? 1 : 0.4)
                    }
                    if let error = monitor.error {
                        StatusDot(kind: .error, text: error)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                if microphone == AudioDevices.none {
                    Text("Only the call audio is recorded, so your own voice won't be in the transcript.")
                } else {
                    Text("Automatic uses \(resolved?.name ?? "the built-in microphone"). It never picks a Bluetooth headset, because that lowers call quality.")
                }
            }

            Section {
                LabeledContent("Status") {
                    if systemAudioVerified {
                        StatusDot(kind: .ok, text: "Working")
                    } else {
                        StatusDot(kind: .neutral, text: "Checked on your first recording")
                    }
                }
                HStack {
                    Text("macOS asks for permission the first time you record. If the other side is missing from transcripts, allow Kaiku under System Audio Recording.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("Open Settings…") { Permissions.open(.systemAudio) }
                }
                Toggle("Remove echo when using speakers", isOn: $removeEcho)
            } header: {
                Text("Call Audio")
            } footer: {
                Text("Everything your Mac plays is captured, without a bot joining the call, and recording continues if you switch between headphones and speakers. On speakers your mic also hears the other people: with echo removal, those repeated lines are hidden from your side of the transcript (they stay in segments.json).")
            }

            MuteSection()
            CallDetectionSection()
            CalendarSection()

            Section {
                TextField("Your microphone", text: $meLabel, prompt: Text("Me"))
                TextField("Call audio", text: $othersLabel, prompt: Text("Others"))
            } header: {
                Text("Speaker Names")
            } footer: {
                Text("Providers that tell voices apart label people Speaker 1, Speaker 2… Rename them for each call in the library.")
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputs() }
        .onDisappear { monitor.stop() }
    }
}

// MARK: - Mute

struct MuteSection: View {
    @ObservedObject private var muter = MicMuter.shared

    var body: some View {
        Section {
            Toggle("Mute all microphones", isOn: Binding(get: { muter.isMuted }, set: { $0 ? muter.mute() : muter.unmute() }))
            if !muter.unsupported.isEmpty {
                StatusDot(kind: .warning, text: "Can't be muted: \(muter.unsupported.joined(separator: ", "))")
            }
        } header: {
            Text("Mute")
        } footer: {
            Text("Silences every microphone on this Mac, including the one your call app uses, while the app still shows you as unmuted. Option-click the menu bar icon to toggle it. Your previous settings come back when you unmute or quit. Tip: turn off \"Automatically adjust microphone volume\" in Zoom, so it doesn't fight the mute.")
        }
    }
}

// MARK: - Call detection

struct CallDetectionSection: View {
    @AppStorage(Keys.detectCalls) private var detect = true
    @AppStorage(Keys.detectAutoStart) private var autoStart = false
    @AppStorage(Keys.detectEndNotify) private var endNotify = true
    @AppStorage(Keys.detectAutoStopSeconds) private var autoStop = 0
    @State private var disabled: Set<String> = []

    var body: some View {
        Section {
            Toggle("Notice when a call starts", isOn: $detect)
                .onChange(of: detect) { _, _ in MeetingMonitor.shared.apply() }
            if detect {
                Toggle("Start recording automatically", isOn: $autoStart)
                Toggle("Ask to stop when the call ends", isOn: $endNotify)
                Picker("Stop automatically after the call ends", selection: $autoStop) {
                    Text("Never").tag(0)
                    Text("After 30 seconds").tag(30)
                    Text("After 1 minute").tag(60)
                    Text("After 2 minutes").tag(120)
                    Text("After 5 minutes").tag(300)
                }
                DisclosureGroup("Apps") {
                    ForEach(MeetingApp.known) { app in
                        Toggle(app.name + (app.isBrowser ? " (Google Meet and web calls)" : ""), isOn: Binding(
                            get: { !disabled.contains(app.id) },
                            set: { on in
                                if on { disabled.remove(app.id) } else { disabled.insert(app.id) }
                                AppSettings.defaults.set(Array(disabled).sorted(), forKey: Keys.detectDisabledApps)
                            }))
                    }
                }
            }
        } header: {
            Text("Call Detection")
        } footer: {
            Text("Kaiku watches which apps use a microphone, without opening any microphone itself. When Zoom, Teams, Meet and others start a call, you get a notification to record it.")
        }
        .onAppear { disabled = Set(AppSettings.detectDisabledApps) }
    }
}

// MARK: - Calendar

struct CalendarSection: View {
    @AppStorage(Keys.calendarEnabled) private var enabled = true
    @ObservedObject private var permissions = Permissions.shared
    @State private var chosen: Set<String> = []
    @State private var calendars: [(id: String, title: String, account: String)] = []

    var body: some View {
        Section {
            Toggle("Name recordings after calendar events", isOn: $enabled)
            if enabled {
                if permissions.calendar == .granted {
                    DisclosureGroup("Calendars (\(chosen.isEmpty ? "all" : "\(chosen.count)"))") {
                        ForEach(calendars, id: \.id) { cal in
                            Toggle(isOn: Binding(
                                get: { chosen.isEmpty || chosen.contains(cal.id) },
                                set: { on in
                                    var set = chosen.isEmpty ? Set(calendars.map(\.id)) : chosen
                                    if on { set.insert(cal.id) } else { set.remove(cal.id) }
                                    chosen = set.count == calendars.count ? [] : set
                                    AppSettings.defaults.set(Array(chosen).sorted(), forKey: Keys.calendarIDs)
                                })) {
                                Text(cal.title)
                                Text(cal.account).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    HStack {
                        StatusDot(kind: permissions.calendar == .denied ? .error : .warning,
                                  text: permissions.calendar == .denied ? "Calendar access denied" : "Needs calendar access")
                        Spacer()
                        Button(permissions.calendar == .notAsked ? "Allow…" : "Open Settings…") { permissions.requestCalendar() }
                    }
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("When a recording starts during an event (or up to 10 minutes before or after), its title is used and the attendees are suggested in Rename Speakers. Google and Outlook calendars must be added in System Settings > Internet Accounts.")
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
        Form {
            Section {
                PermissionRow(
                    symbol: "mic.fill", tint: Brand.accent, title: "Microphone",
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
                    symbol: "bell.badge.fill", tint: .orange, title: "Notifications",
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
            } footer: {
                Text("Changes made in System Settings show up here when you come back.")
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: PermissionState
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    badge
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if state != .granted {
                Button(action, action: perform)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Granted")
        case .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Denied")
        case .notAsked: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Not granted yet")
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary).accessibilityLabel("Unknown")
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            AppIconView().frame(width: 112, height: 112)
            VStack(spacing: 4) {
                Text("Kaiku").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(version).font(.callout).foregroundStyle(.secondary)
            }
            Text("Records your calls without a meeting bot, transcribes them with the provider you choose and keeps everything in a folder you own.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button {
                AppState.shared.openBaseFolder()
            } label: {
                Label(AppSettings.baseFolderDisplayPath, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
            .frame(maxWidth: 420)
            Spacer()
            HStack {
                Button("Show Welcome Guide") { WindowManager.shared.showOnboarding() }
                Button("Open Recordings Folder") { AppState.shared.openBaseFolder() }
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
