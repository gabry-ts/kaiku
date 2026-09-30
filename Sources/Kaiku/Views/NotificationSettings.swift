import KaikuCore
import PartitiUI
import SwiftUI

/// Settings > Notifications: whether macOS lets Kaiku notify, then every notification
/// with a switch for showing it and one for its sound.
struct NotificationSettings: View {
    @ObservedObject private var permissions = Permissions.shared

    private static let calls: [NotificationKind] = [.callDetected, .newSource, .recordingStarted, .callEnded, .recordingStopped]
    private static let transcripts: [NotificationKind] = [.transcriptReady, .recovered, .cleanup]
    private static let problems: [NotificationKind] = [.deviceChanged, .problem]

    var body: some View {
        KaikuPane(pane: .notifications, subtitle: "Which notifications Kaiku shows, and which play a sound.") {
            SettingsGroup(footer: "The switches below only apply while macOS allows notifications from Kaiku.") {
                SettingsRow(Text("Notifications from Kaiku"), subtitle: Text(systemDetail)) {
                    HStack(spacing: PUI.Space.m) {
                        systemStatus
                        if permissions.notifications == .denied || permissions.notifications == .notAsked {
                            Button("Open Settings…") { Permissions.open(.notifications) }
                                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        }
                    }
                }
            }

            SettingsGroup("Calls", footer: "With Call detected off, a call that needs your answer isn't recorded, as if you had dismissed the notification. With New source off, the recording goes on and the source is asked about again next time.") {
                ForEach(Self.calls) { NotificationRow(kind: $0) }
            }

            SettingsGroup("Transcripts and Recordings", footer: "With Recovered recording off, saved recordings still show in the popover, where you can transcribe them.") {
                ForEach(Self.transcripts) { NotificationRow(kind: $0) }
            }

            SettingsGroup("Problems", footer: "Failures are also shown in the popover.") {
                ForEach(Self.problems) { NotificationRow(kind: $0) }
            }
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private var systemDetail: String {
        switch permissions.notifications {
        case .granted: return "Banners and sounds follow System Settings > Notifications."
        case .denied: return "Switched off in System Settings > Notifications, so nothing below is shown."
        case .notAsked: return "macOS hasn't asked yet. Allow Kaiku in System Settings > Notifications."
        case .unknown: return "Checking with macOS…"
        }
    }

    @ViewBuilder private var systemStatus: some View {
        switch permissions.notifications {
        case .granted: StatusDot(kind: .ok, text: "Allowed")
        case .denied, .notAsked: StatusDot(kind: .warning, text: "Not allowed")
        case .unknown: ProgressView().controlSize(.small)
        }
    }
}

/// One notification: what it is, when it appears, its sound and whether it is shown.
struct NotificationRow: View {
    let kind: NotificationKind
    @AppStorage private var shown: Bool
    @AppStorage private var sound: Bool

    init(kind: NotificationKind) {
        self.kind = kind
        _shown = AppStorage(wrappedValue: true, kind.showKey)
        _sound = AppStorage(wrappedValue: kind.defaultSound, kind.soundKey)
    }

    var body: some View {
        SettingsRow(Text(kind.title), subtitle: Text(kind.detail)) {
            HStack(spacing: PUI.Space.m) {
                IconButton(sound ? "speaker.wave.2.fill" : "speaker.slash.fill", active: sound && shown) { sound.toggle() }
                    .help(sound ? "Plays a sound. Click to silence it." : "Silent. Click to play a sound.")
                    .accessibilityLabel("Sound for \(kind.title)")
                    .accessibilityValue(sound ? "On" : "Off")
                    .disabled(!shown)
                    .opacity(shown ? 1 : 0.4)
                Toggle(isOn: $shown) { Text("Show \(kind.title)") }
                    .toggleStyle(PUISwitchStyle(showsLabel: false))
            }
        }
    }
}
