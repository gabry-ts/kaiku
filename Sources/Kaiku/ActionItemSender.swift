import AppKit
import EventKit
import Foundation
import KaikuCore

/// Reads the Reminders lists and adds reminders to the one chosen in Settings.
@MainActor
final class RemindersService {
    static let shared = RemindersService()
    private let store = EKEventStore()

    var state: PermissionState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        store.reset()
        return granted
    }

    func lists() -> [EKCalendar] {
        guard state == .granted else { return [] }
        return store.calendars(for: .reminder).sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    func add(_ item: ActionItem, notes: String, listID: String) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = item.text
        reminder.notes = notes
        reminder.calendar = store.calendar(withIdentifier: listID) ?? store.defaultCalendarForNewReminders()
        reminder.dueDateComponents = ActionItems.dueComponents(item.due)
        try store.save(reminder, commit: true)
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Sends action items from a call to Reminders, Things or Linear, and remembers what was sent.
@MainActor
enum ActionItemSender {
    /// Sends the items one by one and marks each as sent in the call folder. Stops at the first failure.
    static func send(_ items: [ActionItem], to destination: ActionDestination, folder: RecordingFolder) async throws {
        let meta = folder.loadMeta()
        let notes = ActionItems.notes(
            callTitle: meta?.title ?? "", date: (meta?.date ?? Date()).formatted(date: .abbreviated, time: .shortened),
            extra: destination == .linear ? "Transcript: \(folder.transcriptURL.path)" : nil)
        switch destination {
        case .reminders:
            guard let listID = AppSettings.defaults.string(forKey: Keys.remindersListID), !listID.isEmpty else {
                throw ProviderError(message: "Choose a Reminders list in Settings > Transcription > Action Items.")
            }
            if RemindersService.shared.state == .notAsked { _ = await RemindersService.shared.requestAccess() }
            guard RemindersService.shared.state == .granted else {
                throw ProviderError(message: "Kaiku has no access to Reminders. Allow it in System Settings > Privacy & Security.")
            }
        case .things:
            let probe = URL(string: "things:///")!
            guard NSWorkspace.shared.urlForApplication(toOpen: probe) != nil else {
                throw ProviderError(message: "Things is not installed.")
            }
        case .linear:
            guard LinearAPI.key != nil, let team = AppSettings.defaults.string(forKey: Keys.linearTeamID), !team.isEmpty else {
                throw ProviderError(message: "Add your Linear key and choose a team in Settings > Transcription > Action Items.")
            }
        }
        for item in items {
            switch destination {
            case .reminders:
                try RemindersService.shared.add(item, notes: notes, listID: AppSettings.defaults.string(forKey: Keys.remindersListID) ?? "")
            case .things:
                guard let url = ActionItems.thingsURL(item, notes: notes) else { throw ProviderError(message: "Couldn't build the Things link.") }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try await NSWorkspace.shared.open(url, configuration: config)
            case .linear:
                try await LinearAPI.createIssue(item, description: notes)
            }
            markSent(item.id, to: destination, folder: folder)
        }
    }

    /// Re-reads the file first, so a change made meanwhile is kept.
    private static func markSent(_ id: String, to destination: ActionDestination, folder: RecordingFolder) {
        var items = folder.loadActionItems()
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].sentTo.contains(destination) else { return }
        items[index].sentTo.append(destination)
        try? folder.saveActionItems(items)
    }
}

/// Linear's GraphQL API with the personal key from Settings.
enum LinearAPI {
    static let keyAccount = "linearAPIKey"

    static var key: String? {
        guard let v = Keychain.get(keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    private static func post(_ body: Data) async throws -> Data {
        guard let key else { throw ProviderError(message: "Add your Linear API key first.") }
        return try await HTTP.postJSON(ActionItems.linearEndpoint, body: body, headers: ["Authorization": key], timeout: 30)
    }

    static func teams() async throws -> [ActionItems.LinearChoice] {
        try ActionItems.parseLinearTeams(try await post(ActionItems.linearTeamsBody))
    }

    static func projects(teamID: String) async throws -> [ActionItems.LinearChoice] {
        try ActionItems.parseLinearProjects(try await post(try ActionItems.linearProjectsBody(teamID: teamID)))
    }

    static func createIssue(_ item: ActionItem, description: String) async throws {
        let defaults = AppSettings.defaults
        let body = try ActionItems.linearIssueBody(
            teamID: defaults.string(forKey: Keys.linearTeamID) ?? "", projectID: defaults.string(forKey: Keys.linearProjectID),
            item: item, description: description)
        try ActionItems.checkLinearCreated(try await post(body))
    }
}
