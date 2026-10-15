import AppKit
import PartitiUI
import SwiftUI
import KaikuCore

/// The meeting bot in the menu bar panel: its trips, and a card to send it to a link or
/// one of today's meetings.
struct BotSection: View {
    @ObservedObject private var bots = BotManager.shared
    @State private var sending = false

    var body: some View {
        ForEach(bots.sessions) { session in
            BotSessionCard(session: session)
        }
        if sending {
            BotSendCard { sending = false }
        } else {
            Button {
                sending = true
            } label: {
                HStack(spacing: PUI.Space.s) {
                    Image(systemName: "person.wave.2.fill")
                    Text("Send Meeting Bot…")
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// A link field and today's meetings with a join link.
private struct BotSendCard: View {
    let close: () -> Void
    @ObservedObject private var bots = BotManager.shared
    @State private var link = ""
    @State private var message = ""
    @AppStorage(Keys.botChatMessage) private var defaultMessage = ""
    @State private var meetings: [CalendarService.Meeting] = []
    @Environment(\.colorScheme) private var scheme

    private var parsed: MeetingLink? { MeetingLink(link.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        let ink = Ink(scheme)
        Card {
            VStack(alignment: .leading, spacing: PUI.Space.s) {
                HStack {
                    Text("Send Meeting Bot").font(PUI.Font.headline).foregroundStyle(ink.primary)
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ink.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close")
                }
                if !ChromeLauncher.isInstalled {
                    HStack {
                        Text("The bot needs Google Chrome.").font(PUI.Font.caption).foregroundStyle(ink.secondary)
                        Spacer(minLength: 0)
                        Button("Download Chrome…") { NSWorkspace.shared.open(ChromeLauncher.downloadURL) }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                    }
                } else {
                    HStack(spacing: PUI.Space.s) {
                        TextField("Meeting link", text: $link, prompt: Text("Paste a Meet, Teams, Webex or FaceTime link"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .onSubmit(sendLink)
                        Button("Join", action: sendLink)
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                            .disabled(parsed == nil)
                    }
                    if !link.isEmpty && parsed == nil {
                        Text("Not a Meet, Teams, Webex or FaceTime link").font(PUI.Font.caption).foregroundStyle(ink.orange)
                    }
                    // Blank keeps the message from Settings.
                    TextField("Chat message", text: $message,
                              prompt: Text(defaultMessage.isEmpty ? "Chat message (none)" : defaultMessage))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .help("Posted in the meeting chat when the bot joins. Leave it empty to use the one in Settings.")
                    if !meetings.isEmpty {
                        Text("Today").font(PUI.Font.caption).foregroundStyle(ink.secondary)
                        ForEach(meetings) { meeting in
                            MeetingRow(meeting: meeting, sent: bots.isSent(meeting.link)) {
                                bots.send(meeting.link, title: meeting.title, start: meeting.start, message: message)
                                close()
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            meetings = CalendarService.shared.todayMeetings()
            if link.isEmpty, let copied = NSPasteboard.general.string(forType: .string), MeetingLink(copied) != nil {
                link = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func sendLink() {
        guard let parsed else { return }
        bots.send(parsed, message: message)
        close()
    }
}

private struct MeetingRow: View {
    let meeting: CalendarService.Meeting
    let sent: Bool
    let send: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        let later = meeting.start.timeIntervalSinceNow > 60
        HStack(spacing: PUI.Space.s) {
            Text(meeting.start.formatted(date: .omitted, time: .shortened))
                .font(PUI.Font.caption.monospacedDigit()).foregroundStyle(ink.secondary)
            Text(meeting.title).font(PUI.Font.callout).foregroundStyle(ink.primary).lineLimit(1)
            Spacer(minLength: PUI.Space.s)
            Button(sent ? "Sent" : later ? "Schedule" : "Join", action: send)
                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                .disabled(sent)
                .help(later ? "The bot joins when the meeting starts" : "The bot joins now")
        }
    }
}

/// One trip of the bot: what it is doing, listen in, and stop.
private struct BotSessionCard: View {
    @ObservedObject var session: BotSession
    @Environment(\.colorScheme) private var scheme

    private var detail: String {
        switch session.phase {
        case .scheduled(let start): return "Joins at \(start.formatted(date: .omitted, time: .shortened))"
        case .joining: return "Joining \(session.link.platform.name)…"
        case .lobby: return "Waiting to be let in"
        case .inCall: return session.listening ? "Recording, playing on your speakers" : "Recording"
        case .leaving: return "Leaving the call…"
        case .finished: return "Done"
        case .failed(let message): return message
        }
    }

    var body: some View {
        let ink = Ink(scheme)
        Card {
            HStack(spacing: PUI.Space.m) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(failed ? ink.red : AppAccent.kaiku.color)
                StatusText(session.title, detail: detail)
                    .help(detail)
                Spacer(minLength: 0)
                if case .inCall = session.phase {
                    Button {
                        session.setListening(!session.listening)
                    } label: {
                        Image(systemName: session.listening ? "headphones.circle.fill" : "headphones")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(session.listening ? AppAccent.kaiku.color : ink.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(session.listening ? "Stop listening" : "Listen in on your speakers")
                    .accessibilityLabel(session.listening ? "Stop listening" : "Listen in")
                }
                if session.isActive {
                    Button(stopLabel) { session.stop() }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        .disabled(session.phase == .leaving)
                } else {
                    Button("Dismiss") { BotManager.shared.dismiss(session) }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                }
            }
        }
    }

    private var failed: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    private var stopLabel: String {
        switch session.phase {
        case .scheduled, .joining, .lobby: return "Cancel"
        default: return "Stop"
        }
    }
}
