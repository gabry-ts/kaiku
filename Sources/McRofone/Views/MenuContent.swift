import SwiftUI
import McRofoneCore

/// Menu bar icon: template glyph when idle, red pill with elapsed time while recording,
/// animated bars while transcribing, crossed-out mic when all microphones are muted.
/// Shown by StatusBarController.
struct MenuLabel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var muter = MicMuter.shared

    var body: some View {
        Image(nsImage: MenuBarGlyph.current(state, muted: muter.isMuted))
    }
}

/// The menu bar panel.
struct MenuPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var muter = MicMuter.shared
    @State private var recent: [(folder: RecordingFolder, meta: RecordingMeta)] = []
    var closePanel: () -> Void = MenuPanel.closeMenuBarWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            if muter.isMuted {
                MutedBanner(unsupported: muter.unsupported) { muter.unmute() }
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }

            Group {
                if case .recording(let title, _) = state.phase {
                    RecordingCard(title: title, elapsed: state.elapsed, paused: state.isPaused, levels: state.levels) {
                        state.stopRecording()
                    }
                } else {
                    Button {
                        closePanel()
                        state.requestStart()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle.fill")
                            Text("Start Recording")
                            Spacer()
                            Text(HotKeyPreset.current == .off ? "" : HotKeyPreset.current.display)
                                .font(.callout.monospaced()).opacity(0.75)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primaryLarge)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .padding(.horizontal, 14)

            statusSection
                .padding(.horizontal, 14).padding(.top, 10)

            ForEach(state.recoveredFolders, id: \.key) { folder in
                RecoveredCard(folder: folder, busy: state.isBusy(folder)) {
                    state.transcribe(folder: folder, provider: AppSettings.provider)
                } dismiss: {
                    state.dismissRecovered(folder)
                }
                .padding(.horizontal, 14).padding(.top, 10)
            }

            if !recent.isEmpty {
                Divider().padding(.top, 12)
                Text("Recent")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(recent, id: \.folder.id) { item in
                        RecentRow(folder: item.folder, meta: item.meta, busy: state.isBusy(item.folder)) {
                            closePanel()
                            state.openInLibrary(item.folder)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider().padding(.top, 8)
            Toggle(isOn: Binding(get: { muter.isMuted }, set: { $0 ? muter.mute() : muter.unmute() })) {
                Label("Mute all microphones", systemImage: muter.isMuted ? "mic.slash.fill" : "mic.slash")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Call apps still show you as unmuted but send silence. Option-click the menu bar icon to toggle.")
            .padding(.horizontal, 16).padding(.vertical, 7)
            Divider()
            footer.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 320)
        .onAppear(perform: reload)
        .onChange(of: state.libraryVersion) { _, _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView().frame(width: 22, height: 22)
            Text("mc.Rofone").font(.headline)
            Spacer()
            Button {
                closePanel()
                state.openBaseFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open recordings folder (\((AppSettings.baseFolder.path as NSString).abbreviatingWithTildeInPath))")
            .accessibilityLabel("Open recordings folder")
        }
    }

    @ViewBuilder private var statusSection: some View {
        if let key = state.busyFolders.first {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transcribing").font(.callout.weight(.medium))
                    Text(state.busyStage[key] ?? "Working…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .transition(.opacity)
        } else if case .error(let message) = state.phase {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(message).lineLimit(3).font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
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
                    Spacer()
                }
                .controlSize(.small)
            }
            .card()
        } else if case .done(let title) = state.phase {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transcript ready").font(.callout.weight(.medium))
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let last = state.lastFolder, last.hasTranscript {
                    Button("Open") {
                        closePanel()
                        state.openInLibrary(last)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "All Recordings", symbol: "list.bullet.rectangle", shortcut: "l") {
                closePanel()
                state.openInLibrary(nil)
            }
            FooterButton(title: "Settings", symbol: "gearshape", shortcut: ",") {
                closePanel()
                WindowManager.shared.showSettings()
            }
            Spacer()
            FooterButton(title: "Quit", symbol: "power", shortcut: "q") { NSApp.terminate(nil) }
        }
    }

    private func reload() {
        recent = RecordingFolder.scan(base: AppSettings.baseFolder)
            .compactMap { f in f.loadMeta().map { (f, $0) } }
            .sorted { $0.1.date > $1.1.date }
            .prefix(5)
            .map { $0 }
    }

    static func closeMenuBarWindow() {
        StatusBarController.shared.closePanel()
    }
}

private struct RecordingCard: View {
    @EnvironmentObject var state: AppState
    let title: String
    let elapsed: TimeInterval
    let paused: Bool
    @ObservedObject var levels: AppState.Levels
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("Paused").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Brand.accent)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Recording").font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                }
                Spacer()
                Text(TranscriptFormatter.timestamp(elapsed))
                    .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }
            Text(title).font(.body.weight(.medium)).lineLimit(2)
            VStack(spacing: 6) {
                meterRow(symbol: "mic.fill", label: "Microphone", level: levels.mic, active: levels.hasMic)
                meterRow(symbol: "speaker.wave.2.fill", label: "Call audio", level: levels.system, active: true)
            }
            .opacity(paused ? 0.45 : 1)

            if let mic = state.currentMic {
                Menu {
                    ForEach(AudioDevices.inputs()) { d in
                        Button {
                            state.switchMicrophone(to: d)
                        } label: {
                            if d.uid == mic.uid {
                                Label(d.name, systemImage: "checkmark")
                            } else {
                                Text(d.isBluetooth ? "\(d.name) (Bluetooth, lowers call quality)" : d.name)
                            }
                        }
                    }
                } label: {
                    Label(mic.name, systemImage: "mic")
                        .font(.caption)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Switch microphone without stopping")
            }

            HStack(spacing: 8) {
                Button { state.togglePause() } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("p", modifiers: .command)
                .help(shortcutHelp(paused ? "Resume" : "Pause", .pause, "⌘P"))
                Button { state.addBookmark() } label: {
                    Label("Bookmark", systemImage: "bookmark.fill")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(paused)
                .help(shortcutHelp("Add a bookmark at this moment", .bookmark, "⌘B"))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if !state.bookmarks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.bookmarks.suffix(3)) { b in
                        BookmarkNoteRow(bookmark: b)
                    }
                    if state.bookmarks.count > 3 {
                        Text("+\(state.bookmarks.count - 3) more").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }

            Button(action: stop) {
                Label("Stop Recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryLarge)
            .keyboardShortcut("s", modifiers: .command)
        }
        .card()
    }

    private func shortcutHelp(_ text: String, _ action: HotKeyAction, _ local: String) -> String {
        let global = action.display
        return global.isEmpty ? "\(text) (\(local))" : "\(text) (\(local), or \(global) from any app)"
    }

    private func meterRow(symbol: String, label: String, level: Float, active: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            if active {
                LevelMeter(level: level, tint: .green)
            } else {
                Text("Off").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) level")
    }
}

/// Shown while every microphone is muted.
private struct MutedBanner: View {
    let unsupported: [String]
    let unmute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "mic.slash.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphones muted").font(.callout.weight(.semibold))
                    Text("Others hear silence, even if your call app shows you unmuted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Unmute", action: unmute)
                    .buttonStyle(.primary)
                    .controlSize(.small)
            }
            if !unsupported.isEmpty {
                Label("\(unsupported.count) microphone\(unsupported.count == 1 ? " can't" : "s can't") be muted: \(unsupported.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

/// A bookmark of the current recording with an optional note, typed without blocking.
private struct BookmarkNoteRow: View {
    @EnvironmentObject var state: AppState
    let bookmark: Bookmark
    @State private var note = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Brand.accent)
            Text(TranscriptFormatter.timestamp(bookmark.time))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            TextField("Add a note", text: $note)
                .textFieldStyle(.plain)
                .font(.caption)
                .onSubmit { state.renameCurrentBookmark(bookmark.id, to: note) }
                .onChange(of: note) { _, v in state.renameCurrentBookmark(bookmark.id, to: v) }
        }
        .onAppear { note = bookmark.label }
    }
}

/// A call saved after an interruption, with a one-click Transcribe.
private struct RecoveredCard: View {
    let folder: RecordingFolder
    let busy: Bool
    let transcribe: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.blue).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recovered call").font(.callout.weight(.medium))
                Text(folder.loadMeta()?.title ?? folder.url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Transcribe", action: transcribe).disabled(busy)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .controlSize(.small)
        .card()
    }
}

private struct RecentRow: View {
    let folder: RecordingFolder
    let meta: RecordingMeta
    let busy: Bool
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                StatusIcon(status: busy && meta.status != .recording ? .transcribing : meta.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meta.title).lineLimit(1)
                    Text("\(meta.date.formatted(.relative(presentation: .named))) · \(TranscriptFormatter.timestamp(meta.durationSeconds))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if folder.hasTranscript {
                    CopyTranscriptButton(folder: folder, labeled: false)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Small status symbol shared by the panel and the library.
struct StatusIcon: View {
    let status: RecordingStatus

    var body: some View {
        Group {
            switch status {
            case .recording: Image(systemName: "record.circle.fill").foregroundStyle(Brand.accent)
            case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            case .recovered: Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.blue)
            case .transcribing: Image(systemName: "waveform").foregroundStyle(.blue).symbolEffect(.variableColor.iterative)
            case .done: Image(systemName: "text.bubble").foregroundStyle(.secondary)
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 13))
        .frame(width: 18)
        .accessibilityLabel(status.rawValue.capitalized)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let shortcut: KeyEquivalent
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .onHover { hover = $0 }
    }
}
