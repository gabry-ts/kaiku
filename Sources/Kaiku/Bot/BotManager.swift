import Foundation
import KaikuCore

/// The meeting bot's trips, running or scheduled.
@MainActor
final class BotManager: ObservableObject {
    static let shared = BotManager()

    @Published private(set) var sessions: [BotSession] = []

    /// Sends the bot to `link` now, or at `start` when that is more than a minute away,
    /// with `message` in the chat instead of the one in Settings when given.
    func send(_ link: MeetingLink, title: String? = nil, start: Date? = nil, message: String? = nil) {
        let name = title
            ?? CalendarService.shared.todayMeetings().first { $0.link.url == link.url }?.title
            ?? "\(link.platform.name) call"
        let session = BotSession(link: link, title: name, start: start, message: message)
        session.onProcessesChanged = { [weak self] in self?.processesChanged() }
        session.onFinished = { [weak self, weak session] in
            guard let self, let session else { return }
            // A failed trip stays listed until dismissed.
            if case .failed = session.phase { return }
            self.sessions.removeAll { $0.id == session.id }
        }
        sessions.append(session)
        session.begin()
    }

    func dismiss(_ session: BotSession) {
        guard !session.isActive else { return }
        sessions.removeAll { $0.id == session.id }
    }

    /// Whether the bot is already going to this meeting.
    func isSent(_ link: MeetingLink) -> Bool {
        sessions.contains { $0.isActive && $0.link.url == link.url }
    }

    func stopAll() {
        sessions.forEach { $0.kill() }
        sessions = []
    }

    private func processesChanged() {
        let all = sessions.flatMap(\.audioProcesses)
        SystemAudioTap.botProcesses.withLock { $0 = all }
        NotificationCenter.default.post(name: SystemAudioTap.botProcessesChanged, object: nil)
    }
}
