import PartitiUI
import SwiftUI
import KaikuCore

/// The menu bar panel.
struct MenuPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var muter = MicMuter.shared
    @State private var recent: [(folder: RecordingFolder, meta: RecordingMeta)] = []
    @State private var totalCalls = 0
    @AppStorage(Keys.popoverSections) private var layout = Data()
    @AppStorage(Keys.popoverRecentCount) private var recentCount = PopoverLayout.defaultRecentCount
    var closePanel: () -> Void = MenuPanel.closeMenuBarWindow

    var body: some View {
        PopoverScaffold {
            PopoverHeader(icon: AppIconView.image, name: "Kaiku") {
                GlassCircleButton("folder") {
                    closePanel()
                    state.openBaseFolder()
                }
                .help("Open recordings folder (\((AppSettings.baseFolder.path as NSString).abbreviatingWithTildeInPath))")
                .accessibilityLabel("Open recordings folder")
            }
        } content: {
            if muter.isMuted {
                MutedBanner(unsupported: muter.unsupported) { muter.unmute() }
            }

            let sections = PopoverLayout.visible(AppSettings.popoverItems(from: layout))
            ForEach(sections, id: \.self) { section in
                switch section {
                case .record:
                    recordSection
                    // A failed transcription shows even with the status section switched off.
                    if !sections.contains(.status) { errorCard }
                case .live:
                    if state.isRecording { LiveCard(live: state.live) }
                case .mute: MuteCard(muter: muter)
                case .status: statusSection
                case .recovered: recoveredSection
                case .recent: recentSection
                }
            }
        } footer: {
            PopoverFooter(
                actions: [.init("Recordings", symbol: "list.bullet.rectangle",
                                shortcut: KeyboardShortcut("l", modifiers: .command)) { openRecordings() }],
                onSettings: {
                    closePanel()
                    WindowManager.shared.showSettings()
                },
                onCheckForUpdates: { UpdaterManager.shared.checkForUpdates() },
                onBuyMeACoffee: { BuyMeACoffee.open() })
        }
        .puiAccent(.kaiku)
        .onAppear(perform: reload)
        .onChange(of: state.libraryVersion) { _, _ in reload() }
        .onChange(of: recentCount) { _, _ in reload() }
    }

    @ViewBuilder private var recordSection: some View {
        if case .recording(let title, _) = state.phase {
            RecordingCard(title: title, elapsed: state.elapsed, paused: state.isPaused, levels: state.levels) {
                state.stopRecording()
            }
        } else {
            Button {
                closePanel()
                state.requestStart()
            } label: {
                HStack(spacing: PUI.Space.s) {
                    Image(systemName: "record.circle.fill")
                    Text("Start Recording")
                    Spacer(minLength: PUI.Space.m)
                    Text(Shortcuts.display(.record))
                        .font(PUI.Font.callout.monospaced()).opacity(0.75)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var recoveredSection: some View {
        ForEach(state.recoveredFolders, id: \.key) { folder in
            RecoveredCard(folder: folder, busy: state.isBusy(folder)) {
                state.transcribe(folder: folder, provider: AppSettings.provider)
            } dismiss: {
                state.dismissRecovered(folder)
            }
        }
    }

    @ViewBuilder private var recentSection: some View {
        if !recent.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: PUI.Space.xs) {
                    SectionHeader("Recent") {
                        Text(totalCalls == 1 ? "1 call" : "\(totalCalls) calls")
                    }
                    VStack(spacing: 0) {
                        ForEach(recent, id: \.folder.id) { item in
                            RecentRow(folder: item.folder, meta: item.meta, busy: state.isBusy(item.folder)) {
                                closePanel()
                                state.openInLibrary(item.folder)
                            }
                        }
                    }
                    .padding(.horizontal, -PUI.Space.s)
                }
            }
        }
    }

    /// The failed transcription, with the ways out of it. Empty in any other state.
    @ViewBuilder private var errorCard: some View {
        if state.busyFolders.isEmpty, case .error(let message) = state.phase {
            Card(tint: AppAccent.kaiku.color) {
                VStack(alignment: .leading, spacing: PUI.Space.m) {
                    Inked { ink in
                        HStack(alignment: .firstTextBaseline, spacing: PUI.Space.m) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ink.orange)
                            Text(message).font(PUI.Font.callout).foregroundStyle(ink.primary).lineLimit(3)
                        }
                    }
                    HStack(spacing: PUI.Space.s) {
                        if state.lastFolder != nil {
                            Button("Try Again") { state.retryLast() }
                        }
                        Button("Details…") {
                            closePanel()
                            state.showErrorDetails()
                        }
                        if let last = state.lastFolder {
                            Button("Show Call") {
                                closePanel()
                                state.openInLibrary(last)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        if let key = state.busyFolders.first {
            Card {
                HStack(spacing: PUI.Space.m) {
                    ProgressView().controlSize(.small)
                    StatusText("Transcribing", detail: state.busyStage[key] ?? "Working…")
                    Spacer(minLength: 0)
                }
            }
            .transition(.opacity)
        } else if case .error = state.phase {
            errorCard
        } else if case .done(let title) = state.phase {
            Card {
                HStack(spacing: PUI.Space.m) {
                    Inked { ink in
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(ink.green)
                    }
                    StatusText("Transcript ready", detail: title)
                    Spacer(minLength: 0)
                    if let last = state.lastFolder, last.hasTranscript {
                        Button("Open") {
                            closePanel()
                            state.openInLibrary(last)
                        }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                }
            }
        }
    }

    private func openRecordings() {
        closePanel()
        state.openInLibrary(nil)
    }

    private func reload() {
        let all = RecordingFolder.scan(base: AppSettings.baseFolder)
            .compactMap { f in f.loadMeta().map { (f, $0) } }
            .sorted { $0.1.date > $1.1.date }
        totalCalls = all.count
        recent = Array(all.prefix(PopoverLayout.recentCount(recentCount)))
    }

    static func closeMenuBarWindow() {
        StatusBarController.shared.closePanel()
    }
}

/// A headline and a one-line caption, for the status cards of the panel.
private struct StatusText: View {
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        let ink = Ink(scheme)
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(PUI.Font.headline).foregroundStyle(ink.primary)
            Text(detail).font(PUI.Font.caption).foregroundStyle(ink.secondary).lineLimit(1)
        }
    }
}

private struct RecordingCard: View {
    @EnvironmentObject var state: AppState
    let title: String
    let elapsed: TimeInterval
    let paused: Bool
    @ObservedObject var levels: AppState.Levels
    let stop: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        let accent = AppAccent.kaiku
        Card(tint: paused ? nil : accent.color) {
            VStack(alignment: .leading, spacing: PUI.Space.l) {
                HStack(alignment: .top, spacing: PUI.Space.m) {
                    VStack(alignment: .leading, spacing: PUI.Space.xxs) {
                        HStack(spacing: PUI.Space.s) {
                            if paused {
                                Image(systemName: "pause.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(ink.secondary)
                                Text("Paused").font(PUI.Font.label).foregroundStyle(ink.secondary)
                            } else {
                                Circle().fill(accent.color).frame(width: 7, height: 7)
                                    .shadow(color: accent.color.opacity(0.6), radius: 3)
                                Text("Recording").font(PUI.Font.label).foregroundStyle(accent.legible(scheme))
                            }
                        }
                        Text(title).font(PUI.Font.headline).foregroundStyle(ink.primary).lineLimit(2)
                    }
                    Spacer(minLength: PUI.Space.m)
                    BigNumber(MenuBarGlyph.shortTime(elapsed))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.top, -3)
                        .accessibilityLabel("Recorded time")
                }

                VStack(spacing: PUI.Space.s) {
                    meterRow(symbol: "mic.fill", label: "Microphone", level: levels.mic, active: levels.hasMic, ink: ink)
                    meterRow(symbol: "speaker.wave.2.fill", label: "Call audio", level: levels.system, active: true, ink: ink)
                }
                .opacity(paused ? 0.45 : 1)

                if let mic = state.currentMic {
                    PopUpMenu(mic.name, symbol: "mic") {
                        ForEach(AudioDevices.inputs()) { d in
                            Button {
                                state.switchMicrophone(to: d)
                            } label: {
                                if d.uid == mic.uid {
                                    Label(d.name, systemImage: "checkmark")
                                } else {
                                    Text(d.canRecordWithoutHarm ? d.name : "\(d.name) (Bluetooth, lowers call quality)")
                                }
                            }
                        }
                    }
                    .help("Switch microphone without stopping")
                }

                LiveControls(live: state.live)

                HStack(spacing: PUI.Space.m) {
                    Button { state.togglePause() } label: {
                        Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                            .labelStyle(TightLabelStyle(spacing: PUI.Space.s))
                    }
                    .keyboardShortcut("p", modifiers: .command)
                    .help(shortcutHelp(paused ? "Resume" : "Pause", .pause, "⌘P"))
                    Button { state.addBookmark() } label: {
                        Label("Bookmark", systemImage: "bookmark.fill")
                            .labelStyle(TightLabelStyle(spacing: PUI.Space.s))
                    }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(paused)
                    .help(shortcutHelp("Add a bookmark at this moment", .bookmark, "⌘B"))
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))

                if !state.bookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        let shown = Array(state.bookmarks.suffix(3))
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, b in
                            if i > 0 { Hairline(leading: 24) }
                            BookmarkNoteRow(bookmark: b)
                        }
                        if state.bookmarks.count > 3 {
                            Text("+\(state.bookmarks.count - 3) more")
                                .font(PUI.Font.caption).foregroundStyle(ink.tertiary)
                                .padding(.leading, 24)
                        }
                    }
                }

                Button(action: stop) {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .labelStyle(TightLabelStyle(spacing: PUI.Space.s))
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private func shortcutHelp(_ text: String, _ action: ShortcutAction, _ local: String) -> String {
        let global = Shortcuts.display(action)
        return global.isEmpty ? "\(text) (\(local))" : "\(text) (\(local), or \(global) from any app)"
    }

    private func meterRow(symbol: String, label: String, level: Float, active: Bool, ink: Ink) -> some View {
        HStack(spacing: PUI.Space.m) {
            RowSymbol(symbol)
            Text(label).font(PUI.Font.callout).foregroundStyle(ink.primary)
            Spacer(minLength: PUI.Space.m)
            if active {
                LevelMeter(level: level)
            } else {
                Text("Off").font(PUI.Font.caption).foregroundStyle(ink.tertiary)
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) level")
    }
}

/// Shown while every microphone is muted.
private struct MutedBanner: View {
    let unsupported: [String]
    let unmute: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        Card(tint: ink.orange) {
            VStack(alignment: .leading, spacing: PUI.Space.s) {
                HStack(spacing: PUI.Space.m) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ink.orange)
                    StatusText("Microphones muted", detail: "Others hear silence, even if your call app shows you unmuted.")
                    Spacer(minLength: 0)
                    Button("Unmute", action: unmute)
                        .buttonStyle(PrimaryButtonStyle(height: PUI.Control.small, fullWidth: false))
                }
                if !unsupported.isEmpty {
                    Label("\(unsupported.count) microphone\(unsupported.count == 1 ? " can't" : "s can't") be muted: \(unsupported.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(PUI.Font.caption)
                        .foregroundStyle(ink.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The Mute all microphones switch at the bottom of the panel.
private struct MuteCard: View {
    @ObservedObject var muter: MicMuter
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Card(padding: PUI.Space.m + 2) {
            HStack(spacing: PUI.Space.m) {
                RowSymbol(muter.isMuted ? "mic.slash.fill" : "mic.slash")
                Text("Mute all microphones").font(PUI.Font.body).foregroundStyle(Ink(scheme).primary)
                Spacer(minLength: PUI.Space.m)
                Toggle("Mute all microphones",
                       isOn: Binding(get: { muter.isMuted }, set: { $0 ? muter.mute() : muter.unmute() }))
                    .toggleStyle(PUISwitchStyle(mini: true, showsLabel: false))
            }
            .padding(.horizontal, PUI.Space.xxs)
        }
        .help("Call apps still show you as unmuted but send silence. Option-click the menu bar icon to toggle.")
    }
}

/// A bookmark of the current recording with an optional note, typed without blocking.
private struct BookmarkNoteRow: View {
    @EnvironmentObject var state: AppState
    let bookmark: Bookmark
    @State private var note = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        HStack(spacing: PUI.Space.m) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundStyle(AppAccent.kaiku.legible(scheme))
                .frame(width: 16)
            Text(TranscriptFormatter.timestamp(bookmark.time))
                .font(PUI.Font.callout).monospacedDigit().foregroundStyle(ink.secondary)
                .frame(minWidth: 30, alignment: .leading)
            TextField("Add a note", text: $note)
                .textFieldStyle(.plain)
                .font(PUI.Font.callout)
                .foregroundStyle(ink.primary)
                .onSubmit { state.renameCurrentBookmark(bookmark.id, to: note) }
                .onChange(of: note) { _, v in state.renameCurrentBookmark(bookmark.id, to: v) }
        }
        .frame(height: PUI.Control.small + 2)
        .onAppear { note = bookmark.label }
    }
}

/// A call saved after an interruption, with a one-click Transcribe.
private struct RecoveredCard: View {
    let folder: RecordingFolder
    let busy: Bool
    let transcribe: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        Card {
            HStack(spacing: PUI.Space.m) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.blue)
                StatusText("Recovered call", detail: folder.loadMeta()?.title ?? folder.url.lastPathComponent)
                Spacer(minLength: 0)
                Button("Transcribe", action: transcribe)
                    .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    .disabled(busy)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ink.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
    }
}

private struct RecentRow: View {
    let folder: RecordingFolder
    let meta: RecordingMeta
    let busy: Bool
    let open: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    private var status: RecordingStatus { busy && meta.status != .recording ? .transcribing : meta.status }

    var body: some View {
        let ink = Ink(scheme)
        Button(action: open) {
            HStack(spacing: PUI.Space.m) {
                StatusIcon(status: status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meta.title).font(PUI.Font.body).foregroundStyle(ink.primary).lineLimit(1)
                    Text("\(meta.date.formatted(.relative(presentation: .named))) · \(TranscriptFormatter.timestamp(meta.durationSeconds))")
                        .font(PUI.Font.caption).monospacedDigit().foregroundStyle(ink.secondary).lineLimit(1)
                }
                Spacer(minLength: PUI.Space.m)
                if status == .transcribing {
                    HStack(spacing: PUI.Space.xs) {
                        ProgressView().controlSize(.mini)
                        Text("Transcribing").font(PUI.Font.caption)
                    }
                    .foregroundStyle(ink.secondary)
                } else if folder.hasTranscript {
                    CopyTranscriptButton(folder: folder, labeled: false)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, PUI.Space.s)
            .frame(height: 34)
            .puiHoverHighlight(hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(PUI.Motion.hover) { hover = inside } }
    }
}

/// Small status symbol shared by the panel and the library.
struct StatusIcon: View {
    let status: RecordingStatus
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        let accent = AppAccent.kaiku.legible(scheme)
        Group {
            switch status {
            case .recording: RowSymbol("record.circle.fill", color: accent)
            case .paused: RowSymbol("pause.circle.fill", color: ink.orange)
            case .recovered: RowSymbol("arrow.uturn.backward.circle.fill", color: .blue)
            case .transcribing: RowSymbol("waveform", color: accent).symbolEffect(.variableColor.iterative)
            case .done: RowSymbol("text.bubble")
            case .error: RowSymbol("exclamationmark.triangle.fill", color: ink.orange)
            }
        }
        .accessibilityLabel(status.rawValue.capitalized)
    }
}
